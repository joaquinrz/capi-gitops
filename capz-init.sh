#!/bin/bash
# Enable support for managed topologies and experimental features
export CLUSTER_TOPOLOGY=true
export EXP_MACHINE_POOL=true

# Create an Azure Service Principal in the Azure portal. (Note: Make sure this Service Principal has access to the resource group)
# Create an Azure Service Principal
export AZURE_SP_NAME="kubecon23capi$RANDOM"

export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
export AZURE_CLIENT_SECRET=$(az ad sp create-for-rbac --name $AZURE_SP_NAME --role contributor --scopes="/subscriptions/${AZURE_SUBSCRIPTION_ID}" --query password -o tsv)
export AZURE_CLIENT_ID=$(az ad sp list --display-name $AZURE_SP_NAME --query "[0].appId" -o tsv)

# Base64 encode the variables
export AZURE_SUBSCRIPTION_ID_B64="$(echo -n "$AZURE_SUBSCRIPTION_ID" | base64 | tr -d '\n')"
export AZURE_TENANT_ID_B64="$(echo -n "$AZURE_TENANT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_ID_B64="$(echo -n "$AZURE_CLIENT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_SECRET_B64="$(echo -n "$AZURE_CLIENT_SECRET" | base64 | tr -d '\n')"

# Settings needed for AzureClusterIdentity used by the AzureCluster
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE=$1

# Create a secret to include the password of the Service Principal identity created in Azure
# This secret will be referenced by the AzureClusterIdentity used by the AzureCluster
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}" -n ${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}

# Initialize the management cluster for azure
clusterctl init --infrastructure azure

sleep 10
# Create and apply an AzureClusterIdentity
envsubst < manifests/templates/aks-cluster-identity.yaml | kubectl apply -f -
