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

KUBECONFIG=$KUBECONFIG argocd login \
    --username admin \
    --password "$( argocd admin initial-password \
        --namespace "$ARGOCD_NAMESPACE" \
        --kubeconfig "$KUBECONFIG" | head -n 1 )" \
    --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web \
    --insecure \
    --kube-context "$CLUSTER_MAIN_CONTEXT"

kubectl wait pod \
    --for=condition=Ready \
    -l "app.kubernetes.io/name=argocd-server" \
    -n "$ARGOCD_NAMESPACE"

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

kubectl config set-context "$CLUSTER_MAIN_CONTEXT" --kubeconfig "$KUBECONFIG_WI_MI"

KUBECONFIG=$KUBECONFIG_WI_MI \
    argocd cluster add "$CLUSTER_WORKER_CONTEXT" \
        --kubeconfig "$KUBECONFIG_WI_MI" \
        --kube-context "$CLUSTER_MAIN_CONTEXT" \
        --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web \
        --insecure \
        --yes

# create ArgoCD's Applications
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
    --kube-context "$CLUSTER_MAIN_CONTEXT" \
    --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web

# sync primaza
argocd app sync primaza mytenant-dev \
    --kube-context "$CLUSTER_MAIN_CONTEXT" \
    --port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" --grpc-web
