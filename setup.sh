#!/bin/env sh
#
# Setup Primaza MVP

set -e

ARGOCD_NAMESPACE=argocd

CLUSTER_MAIN=primaza-mvp-main
CLUSTER_WORKER=primaza-mvp-worker

KUBECONFIG=/tmp/kc-mvp-primaza

CLUSTER_MAIN_CONTEXT=kind-$CLUSTER_MAIN
CLUSTER_WORKER_CONTEXT=kind-$CLUSTER_WORKER

kind delete clusters "$CLUSTER_MAIN" "$CLUSTER_WORKER"

kind create cluster --name "$CLUSTER_MAIN" --kubeconfig "$KUBECONFIG"

# install ArgoCD
kubectl create namespace "$ARGOCD_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    --context "$CLUSTER_MAIN_CONTEXT"

kubectl apply \
    -n "$ARGOCD_NAMESPACE" \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml" \
    --kubeconfig "$KUBECONFIG" \
    --context "$CLUSTER_MAIN_CONTEXT"

ARGO_SECRET=argocd-initial-admin-secret
until kubectl get secrets \
    "$ARGO_SECRET" \
    --namespace "$ARGOCD_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    --context "$CLUSTER_MAIN_CONTEXT"
do
    echo "waiting for secret $ARGO_SECRET to be created..."
    sleep 5
done

kubectl wait pod \
    --for=condition=Ready \
    -l "app.kubernetes.io/name=argocd-server" \
    -n "$ARGOCD_NAMESPACE" \
    --kubeconfig "$KUBECONFIG"

KUBECONFIG=$KUBECONFIG argocd login \
    --username admin \
    --password "$( argocd admin initial-password \
        --namespace "$ARGOCD_NAMESPACE" \
        --kubeconfig "$KUBECONFIG" | head -n 1 )" \
    --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web \
    --insecure \
    --kube-context "$CLUSTER_MAIN_CONTEXT"

kind create cluster --name "$CLUSTER_WORKER" --kubeconfig "$KUBECONFIG"

KUBECONFIG_WORKER_INTERNAL=/tmp/kc-mvp-primaza-worker-internal
KUBECONFIG_MAIN_INTERNAL=/tmp/kc-mvp-primaza-main-internal
kind get kubeconfig --name $CLUSTER_MAIN | \
    sed "s/server: https:\/\/127\.0\.0\.1:[0-9]*$/server: https:\/\/$(docker container inspect $CLUSTER_MAIN-control-plane --format {{.NetworkSettings.Networks.kind.IPAddress}}):6443/" > "$KUBECONFIG_MAIN_INTERNAL"
kind get kubeconfig --name $CLUSTER_WORKER | \
    sed "s/server: https:\/\/127\.0\.0\.1:[0-9]*$/server: https:\/\/$(docker container inspect $CLUSTER_WORKER-control-plane --format {{.NetworkSettings.Networks.kind.IPAddress}}):6443/g" > "$KUBECONFIG_WORKER_INTERNAL"

KUBECONFIG_WI_MI=/tmp/kc-mvp-primaza-wi-mi
KUBECONFIG=$KUBECONFIG_WORKER_INTERNAL:$KUBECONFIG_MAIN_INTERNAL \
    kubectl config view --flatten > "$KUBECONFIG_WI_MI"

cat << EOF | kubectl apply --kubeconfig "$KUBECONFIG" --context "$CLUSTER_WORKER_CONTEXT" -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: primaza-mytenant-worker
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: primaza-token-worker-mytenant
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: primaza-mytenant-worker
type: kubernetes.io/service-account-token
EOF

until TOKEN=$(kubectl get secrets \
    primaza-token-worker-mytenant \
    -n kube-system \
    --kubeconfig="$KUBECONFIG" \
    --context "$CLUSTER_WORKER_CONTEXT" \
    -o jsonpath='{.data.token}' | base64 -d) && [ -n "$TOKEN" ]
do
    printf "waiting for token (kube-system/primaza-token-worker-mytenant) to be released...\n"
    sleep 10
done

P2W_KUBECONFIG=$(kubectl config view --flatten -o json --kubeconfig  "$KUBECONFIG_WORKER_INTERNAL" | \
    jq 'del(.users[0].user."client-certificate-data", .users[0].user."client-key-data")' | \
    jq -c --arg token "$TOKEN" '.users[0].user = { "token": $token }' | \
    yq -y | base64 -w0 -)

cat << EOF | kubectl apply --kubeconfig "$KUBECONFIG" --context "$CLUSTER_MAIN_CONTEXT" -f -
apiVersion: v1
kind: Namespace
metadata:
  name: primaza-mytenant
---
apiVersion: v1
kind: Secret
metadata:
  name: primaza-worker
  namespace: primaza-mytenant
  labels:
    primaza.io/tenant: mytenant
    primaza.io/cluster-environment: worker
data:
    kubeconfig: $P2W_KUBECONFIG
stringData:
    namespace: primaza-mytenant
EOF

KUBECONFIG=$KUBECONFIG_WI_MI \
    argocd cluster add "$CLUSTER_WORKER_CONTEXT" \
        --kubeconfig "$KUBECONFIG_WI_MI" \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web \
        --insecure \
        --yes

# create ArgoCD's Applications
(
    export KUBECONFIG=$KUBECONFIG

    argocd app create main-cert-manager \
        --repo https://github.com/filariow/primaza-argocd.git \
        --path cert-manager \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace cert-manager \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

    argocd app create primaza \
        --repo https://github.com/filariow/primaza-argocd.git \
        --path mytenant/primaza \
        --dest-server https://kubernetes.default.svc \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

    argocd app create worker-cert-manager \
        --repo https://github.com/filariow/primaza-argocd.git \
        --path cert-manager \
        --dest-namespace cert-manager \
        --dest-name "$CLUSTER_WORKER_CONTEXT" \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

    argocd app create mytenant-dev \
        --repo https://github.com/filariow/primaza-argocd.git \
        --path mytenant/dev/ \
        --dest-name "$CLUSTER_WORKER_CONTEXT" \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

    # sync cert-managers
    argocd app sync main-cert-manager worker-cert-manager \
        --assumeYes \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --retry-limit 6 \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

    argocd app wait --sync main-cert-manager worker-cert-manager \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --timeout 600 \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

    # sync primaza
    argocd app sync primaza mytenant-dev \
        --assumeYes \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --retry-limit 6 \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

    argocd app wait --sync primaza mytenant-dev \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --timeout 600 \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web
)
