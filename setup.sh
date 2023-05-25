#!/bin/sh
set -e

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'Setup for the 
"TODO:"
video.'

gum confirm '
Are you ready to start?
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

rm -f .env

################
# Requirements #
################

echo "
## You will need following tools installed:
|Name            |More info                                          |
|----------------|---------------------------------------------------|
|Charm Gum       |'https://github.com/charmbracelet/gum#installation'|
|gitHub CLi      |'https://youtu.be/BII6ZY2Rnlc'                     |
|yq              |'https://github.com/mikefarah/yq#install'          |
|kubectl         |'https://kubernetes.io/docs/tasks/tools/#kubectl'  |

" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

gum confirm "
Do you have a a Kubernetes cluster with an Ingress controller?
" || exit 0

#########
# Setup #
#########

GITHUB_ORG=$(gum input --placeholder "GitHub organization (do NOT use GitHub username)" --value "$GITHUB_ORG")
echo "export GITHUB_ORG=$GITHUB_ORG" >> .env

GITHUB_TOKEN=$(gum input --placeholder "Please enter GitHub organization admin token." --password --value "$GITHUB_TOKEN")

if [ -z "$DO_NOT_FORK" ]; then
    gh repo fork vfarcic/crossplane-github --clone --remote --org ${GITHUB_ORG}
    cd crossplane-github
fi

INGRESS_HOST=$(gum input --placeholder "External IP of the Ingress service" --value "127.0.0.1")
echo "export INGRESS_HOST=$INGRESS_HOST" >> .env

kubectl get ingressclasses --output name

INGRESS_CLASS=$(kubectl get ingressclasses --output jsonpath="{.items[0].metadata.name}")

yq --inplace \
    ".server.ingress.hosts[0] = \"argocd.$INGRESS_HOST.nip.io\"" \
    argocd/helm-values.yaml

yq --inplace \
    ".server.ingress.ingressClassName = \"$INGRESS_CLASS\"" \
    argocd/helm-values.yaml

helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --namespace argocd --create-namespace \
    --values argocd/helm-values.yaml --wait

kubectl apply --filename argocd/project.yaml

yq --inplace \
    ".spec.source.repoURL = \"https://github.com/$GITHUB_ORG/crossplane-github\"" \
    argocd/apps.yaml

yq --inplace \
    ".spec.source.repoURL = \"https://github.com/$GITHUB_ORG/crossplane-github\"" \
    argocd/silly-demo-repo.yaml

kubectl apply --filename argocd/apps.yaml

helm repo add crossplane-stable \
    https://charts.crossplane.io/stable

helm repo update

helm upgrade --install crossplane crossplane-stable/crossplane \
    --namespace crossplane-system --create-namespace --wait

kubectl apply --filename crossplane-config/provider-github.yaml

kubectl wait --for=condition=healthy provider.pkg.crossplane.io \
    --all --timeout=300s

echo "apiVersion: v1
kind: Secret
metadata:
  name: github-creds
type: Opaque
stringData:
  credentials: |
    {
      \"token\": \"$GITHUB_TOKEN\",
      \"owner\": \"$GITHUB_ORG\"
    }
" | kubectl --namespace crossplane-system apply --filename -

kubectl apply \
    --filename crossplane-config/provider-config-github.yaml

kubectl create namespace infra

KUBECONFIG=$(gum input --placeholder "Path to Kube config" --value "$HOME/.kube/config")
echo "export KUBECONFIG=$KUBECONFIG" >> .env

echo "apiVersion: v1
kind: Secret
metadata:
  name: kubeconfig-previews
type: Opaque
data:
  kubeconfig: $(cat -n $KUBECONFIG | base64)
" | kubectl --namespace infra apply --filename -

yq --inplace \
    ".github.organization = \"$GITHUB_ORG\"" \
    chart/values.yaml

###########
# The End #
###########

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'The setup is almost finished.' \
    '
Execute "source .env" to set the environment variables.'
