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
	--port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" \
	--insecure \
	--grpc-web \
	--kube-context "$CLUSTER_MAIN_CONTEXT"
	

kind create cluster --name "$CLUSTER_WORKER" --kubeconfig "$KUBECONFIG"

KUBECONFIG_WORKER_INTERNAL=/tmp/kc-mvp-primaza-worker-internal
KUBECONFIG_MAIN_INTERNAL=/tmp/kc-mvp-primaza-main-internal
kind get kubeconfig --name $CLUSTER_MAIN | \
	sed "s/server: https:\/\/127\.0\.0\.1:[0-9]*$/server: https:\/\/$(docker container inspect $CLUSTER_MAIN-control-plane --format {{.NetworkSettings.Networks.kind.IPAddress}}):6443/" > "$KUBECONFIG_MAIN_INTERNAL"
kind get kubeconfig --name $CLUSTER_WORKER | \
	sed "s/server: https:\/\/127\.0\.0\.1:[0-9]*$/server: https:\/\/$(docker container inspect $CLUSTER_WORKER-control-plane --format {{.NetworkSettings.Networks.kind.IPAddress}}:6443)/g" > "$KUBECONFIG_WORKER_INTERNAL"

KUBECONFIG_WI_MI=/tmp/kc-mvp-primaza-wi-mi
KUBECONFIG=$KUBECONFIG_WORKER_INTERNAL:$KUBECONFIG_MAIN_INTERNAL \
	kubectl config view --flatten > "$KUBECONFIG_WI_MI"

argocd cluster add "$( kubectl config current-context )" \
	--kubeconfig "$KUBECONFIG_WI_MI" \
	--kube-context "$CLUSTER_MAIN_CONTEXT" \
	--port-forward --port-forward-namespace "$ARGOCD_NAMESPACE" \
	--insecure \
	--yes

argocd app create cert-manager \
	--repo https://github.com/filariow/primaza-argocd.git \
	--path cert-manager \
	--dest-server https://kubernetes.default.svc \
	--dest-namespace cert-manager \
	--port-forward \
	--port-forward-namespace "$ARGOCD_NAMESPACE" \
	--grpc-web

argocd app create primaza \
	--repo https://github.com/filariow/primaza-argocd.git \
	--path primaza \
	--dest-server https://kubernetes.default.svc \
	--port-forward \
	--port-forward-namespace "$ARGOCD_NAMESPACE" \
	--grpc-web

# kubectl port-forward svc/argocd-server \
# 	-n argocd 8080:443 \
# 	--context CLUSTER_MAIN_CONTEXT=kind-$CLUSTER_MAIN

