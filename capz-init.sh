#!/bin/bash

export EXP_MACHINE_POOL=true
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

export AZURE_CAPZ_SP=$(az ad sp create-for-rbac --role Contributor --name capzSP --scopes="/subscriptions/${AZURE_SUBSCRIPTION_ID}" --sdk-auth)
export AZURE_CLIENT_SECRET="$(echo $AZURE_CAPZ_SP | jq -r .clientSecret | tr -d '\n')"
export AZURE_CLIENT_ID="$(echo $AZURE_CAPZ_SP | jq -r .clientId | tr -d '\n')"
export AZURE_TENANT_ID="$(echo $AZURE_CAPZ_SP | jq -r .tenantId | tr -d '\n')"

kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}"

clusterctl init --infrastructure azure

sleep 30
# Create and apply an AzureClusterIdentity
envsubst < manifests/templates/aks-cluster-identity.yaml | kubectl apply -f -
