# Ephemeral Clusters as a Service with vcluster, ClusterAPI and ArgoCD

![License](https://img.shields.io/badge/license-MIT-green.svg)

## Overview

Welcome to Ephemeral Clusters as a Service with [vClusters](https://www.vcluster.com), [ClusterAPI](https://cluster-api.sigs.k8s.io) and [ArgoCD](https://argo-cd.readthedocs.io/en/stable/). GitOps has rapidly gained popularity in recent years, with its many benefits over traditional CI/CD tools. However, with increased adoption comes the challenge of managing multiple Kubernetes clusters across different cloud providers. At scale, ensuring observability and security across all clusters can be particularly difficult.

This repository demonstrates how open-source tools, such as ClusterAPI, ArgoCD, and Prometheus+Thanos, can be used to effectively manage and monitor large-scale Kubernetes deployments. We will walk you through a sample that automates the deployment of several clusters and applications securely and with observability in mind.

## Prerequisites

For our sample will be using Azure Kubernetes Service (AKS). Before starting, you will need the following:

- An Azure account (already logged in with the Azure CLI)
- Azure CLI [download](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
- Optional but recommented (and the instructions below assume you have one) A working DNS zone in Azure, to use proper DNS names and automatic certifcates provisioning with Let'sEncrypt

Everything else is installed via ArgoCD, so no need for any extra CLI!

## Step 1: Create an ArgoCD management cluster with AKS

To create a new management cluster in AKS, run the following commands. Otherwise, if you already have an existing AKS cluster, you can skip this step and proceed to connecting to the existing AKS cluster. Change accoring to your liking, specially the `AZURE_DNS_ZONE`:

```bash
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export CLUSTER_RG=clusters
export CLUSTER_NAME=management
export LOCATION=westeurope
export IDENTITY_NAME=gitops$RANDOM
export NODE_COUNT=2
export AZURE_DNS_ZONE=k8sis.fun
export AZURE_DNS_ZONE_RESOURCE_GROUP=dns
```

Create a resource group for your AKS cluster with the following command, replacing <resource-group> with a name for your resource group and <location> with the Azure region where you want your resources to be located:

```bash
az group create --name $CLUSTER_RG --location $LOCATION
```

To use automatic DNS name updates via external-dns, we need to create a new managed identity and assign the role of DNS Contributor to the resource group containg the zone resource  

```bash
IDENTITY=$(az identity create -n $IDENTITY_NAME -g $CLUSTER_RG --query id -o tsv)
IDENTITY_CLIENTID=$(az identity show -g $CLUSTER_RG -n $IDENTITY_NAME -o tsv --query clientId)

DNS_ID=$(az network dns zone show --name $AZURE_DNS_ZONE \
  --resource-group $AZURE_DNS_ZONE_RESOURCE_GROUP --query "id" --output tsv)

az role assignment create --role "DNS Zone Contributor" --assignee $IDENTITY_CLIENTID --scope $DNS_ID
```

Create an AKS cluster with the following command:

```bash
az aks create -k 1.26.0 -y -g $CLUSTER_RG -s Standard_B4ms -c $NODE_COUNT  \
--assign-identity $IDENTITY --assign-kubelet-identity $IDENTITY --network-plugin kubenet -n $CLUSTER_NAME
```

Connect to the AKS cluster:
```bash
az aks get-credentials --resource-group $CLUSTER_RG --name $CLUSTER_NAME
```

Verify that you can connect to the AKS cluster:
```bash
kubectl get nodes
```

## Step 2:  Install ArgoCD

ArgoCD is an open-source continuous delivery tool designed to simplify the deployment of applications to Kubernetes clusters. It allows developers to manage and deploy applications declaratively, reducing the amount of manual work involved in the process. With ArgoCD, developers can automate application deployment, configuration management, and application rollouts, making it easier to deliver applications reliably to production environments.

You can install ArgoCD on your Kubernetes cluster by running the following commands in your terminal or command prompt. These commands will download and install ArgoCD on your cluster, allowing you to use it for GitOps-based continuous delivery of your applications

Add ArgoCD Helm Repo

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

Edit the `gitops/management/argocd/argocd-values.yaml` with your hostname and domain name for ArgoCD ingress, then install ArgoCD:

```bash
envsubst < gitops/management/argocd/argocd-values.yaml > gitops/management/argocd/argocd-values-local.yaml
helm upgrade -i -n argocd \
  --version 5.29.1 \
  --create-namespace \
  --values gitops/management/argocd/argocd-values-local.yaml \
  argocd argo/argo-cd

helm upgrade -i -n argocd \
  --version 0.0.9\
  --create-namespace \
  --values argocd-initial-objects.yaml \
  argocd-apps argo/argocd-apps
```

Verify that ArgoCD is running:

```bash
kubectl get pods -n argocd
```

Access the ArgoCD web UI by running the following command, and then open the URL in a web browser (ingress, external-dns and cert-manager take care of certificates and DNS hostname resolution):

```bash
open https://argocd.$AZURE_DNS_ZONE
```

ArgoCD is in read-only mode for anonymous users, that should be enough to monitor the installaation progress, but if you want to change things, retrieve the secret with:

```bash
kubectl get secret -n argocd argocd-initial-admin-secret  -o=jsonpath='{.data.password}'| base64 -D
```

## Step 2:  Bootstrap Management Cluster with ClusterAPI

To initialize the AKS cluster with Cluster API and turn it into the management cluster, follow these instructions. Once initialized, the management cluster will allow you to control and maintain a fleet of ephemeral clusters. Unfortunately this part cannot be automated via ArgoCD just yet, although a promising effort is made in the `capi-operator` [repository](https://github.com/kubernetes-sigs/cluster-api-operator/tree/main):

```bash
# Enable support for managed topologies and experimental features
export CLUSTER_TOPOLOGY=true
export EXP_MACHINE_POOL=true

# Create an Azure Service Principal in the Azure portal. (Note: Make sure this Service Principal has access to the resource group)
# Create an Azure Service Principal
export AZURE_SP_NAME="kubecon23capi"

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
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

# Create a secret to include the password of the Service Principal identity created in Azure
# This secret will be referenced by the AzureClusterIdentity used by the AzureCluster
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}" -n ${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}

# Initialize the management cluster for azure
clusterctl init --infrastructure azure

# Create and apply an AzureClusterIdentity
envsubst < manifests/templates/aks-cluster-identity.yaml | kubectl apply -f -
``
