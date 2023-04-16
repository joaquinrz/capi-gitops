# Ephemeral Clusters as a Service with vcluster, ClusterAPI and ArgoCD

![License](https://img.shields.io/badge/license-MIT-green.svg)

## Overview

Welcome to Ephemeral Clusters as a Service with [VCluster](https://www.vcluster.com) and [ArgoCD](https://argo-cd.readthedocs.io/en/stable/). GitOps has rapidly gained popularity in recent years, with its many benefits over traditional CI/CD tools. However, with increased adoption comes the challenge of managing multiple Kubernetes clusters across different cloud providers. At scale, ensuring observability and security across all clusters can be particularly difficult.

This repository demonstrates how open-source tools, such as ClusterAPI, ArgoCD, and Prometheus+Thanos, can be used to effectively manage and monitor large-scale Kubernetes deployments. We will walk you through a sample that automates the deployment of several clusters and applications securely and with observability in mind.

## Prerequisites

For our sample will be using Azure Kubernetes Service (AKS). Before starting, you will need the following:

- An Azure account
- Azure CLI [download](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
- Optional but recommented (and the instructions below assume you have one) A working DNS zone in Azure, to use proper DNS names and automatic certifcates provisioning with Let'sEncrypt

Everything else is installed via ArgoCD, so no need for any extra CLI!

## Step 1: Create an ArgoCD management cluster with AKS

To create a new management cluster in AKS, run the following commands. Otherwise, if you already have an existing AKS cluster, you can skip this step and proceed to connecting to the existing AKS cluster.

```bash

AZURE_SUBSCRIPTION_ID=<yourSubscriptionId>
CLUSTER_RG=clusters
CLUSTER_NAME=management
LOCATION=westeurope

# Connecting to Azure
az login --use-device-code

# Change the active subscription using the subscription name
az account set --subscription $AZURE_SUBSCRIPTION_ID

# Create a resource group for your AKS cluster with the following command, replacing <resource-group> with a name for your resource group and <location> with the Azure region where you want your resources to be located:
az group create --name $CLUSTER_RG --location $LOCATION

# To use automatic DNS name updates via external-dns, we need to create a new managed identity and assign the role of DNS Contributor to the resource group containg the zone resource  

CLUSTER_RG=clusters
IDENTITY_NAME=gitops
AZURE_DNS_ZONE=kubespaces.io
AZURE_DNS_ZONE_RESOURCE_GROUP=dns

IDENTITY=$(az identity create -n $IDENTITY_NAME -g $CLUSTER_RG --query id -o tsv)
IDENTITY_CLIENTID=$(az identity show -g $CLUSTER_RG -n $IDENTITY_NAME -o tsv --query clientId)

DNS_ID=$(az network dns zone show --name $AZURE_DNS_ZONE \
  --resource-group $AZURE_DNS_ZONE_RESOURCE_GROUP --query "id" --output tsv)

az role assignment create --role "DNS Zone Contributor" --assignee $PRINCIPAL_ID --scope $DNS_ID

# Create an AKS cluster with the following command, replacing <cluster-name> with a name for your cluster, and <node-count> with the number of nodes you want in your cluster:
az aks create -k 1.26.0 -y -g clusters -s Standard_B4ms -c 2  \
--assign-identity $IDENTITY --assign-kubelet-identity $IDENTITY --network-plugin kubenet -n $

# Connect to the AKS cluster:
az aks get-credentials --resource-group $CLUSTER_RG --name $CLUSTER_NAME

#Verify that you can connect to the AKS cluster:
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
helm upgrade -i -n argocd \
  --version 5.29.1 \
  --create-namespace \
  --values gitops/management/argocd/argocd-values.yaml \
  --values argocd-initial-objects.yaml \
  argocd argo/argo-cd
```

Verify that ArgoCD is running:
kubectl get pods -n argocd

# Access the ArgoCD web UI by running the following command, and then open the URL in a web browser:


# Log in to the ArgoCD http://localhost:8080 with the following credentials:
# - Username: admin
# - Password: Retrieve the ArgoCD password by running one of the following command:

argocd admin initial-password -n argocd

# Alternatively, you can also retrieve the credentials using kubectl.
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Step 2:  Install Prometheus and Grafana

Prometheus and Grafana are two popular open-source tools used for monitoring and visualizing data. Prometheus collects metrics from various sources, while Grafana provides customizable dashboards for displaying this data. Together, they offer a powerful and flexible monitoring solution that can help developers and system administrators gain insights into the performance of their applications and systems.

The following commands will help you install Prometheus and Grafana in your cluster

```bash
# Add prometheus-community helm chart. This Helm chart by default also includes Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update 

# Create a monitoring namespace for these applications
kubectl create ns monitoring

# Install the Helm Chart
helm install -n monitoring kube-stack-prometheus prometheus-community/kube-prometheus-stack

# Access Grafana UI http://localhost:8081/
# Credentials: admin:prom-operator
kubectl port-forward service/kube-stack-prometheus-grafana  -n monitoring 8081:80

# Access Prometheus UI http://localhost:9090/ 
kubectl port-forward service/kube-stack-prometheus-kube-prometheus -n monitoring 9090:9090
```

## Step 3:  Installing Thanos

## Step 4:  Bootstrap Management Cluster with ClusterAPI

To initialize the AKS cluster with Cluster API and turn it into the management cluster, follow these instructions. Once initialized, the management cluster will allow you to control and maintain a fleet of ephemeral clusters.

```bash

# Enable support for managed topologies and experimental features
export CLUSTER_TOPOLOGY=true
export EXP_AKS=true
export EXP_MACHINE_POOL=true

# Create an Azure Service Principal in the Azure portal. (Note: Make sure this Service Principal has access to the resource group)
# Create an Azure Service Principal
export AZURE_SP_NAME="kubecon23capi"

 az ad sp create-for-rbac \
   --name $AZURE_SP_NAME \
   --role contributor \
   --scopes="/subscriptions/${AZURE_SUBSCRIPTION_ID}"

# TODO - Add command so that SP has role assigment to the resource group of the cluster

export AZURE_TENANT_ID="<Tenant>"
export AZURE_CLIENT_ID="<AppId>"
export AZURE_CLIENT_SECRET="<Password>"

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
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}"

# Initialize the management cluster for azure
clusterctl init --infrastructure azure

# Create and apply an AzureClusterIdentity
envsubst < manifests/templates/aks-cluster-identity.yaml | kubectl apply -f -
``
