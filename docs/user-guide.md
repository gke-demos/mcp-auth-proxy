# GKE MCP Auth Proxy User Guide

This user guide provides step-by-step instructions on configuring, deploying, and using the `google-mcp-auth-proxy` in your Kubernetes clusters (specifically targeting GKE), leveraging **GKE Workload Identity Federation** to handle authentication to Google Model Context Protocol (MCP) servers.

---

## Table of Contents
1. [Architecture Overview](#architecture-overviews)
2. [Generic Usage & Configuration](#generic-usage--configuration)
3. [GKE Workload Identity Federation Setup](#gke-workload-identity-federation-setup)
4. [Deploying to the `kagent` Namespace](#deploying-to-the-kagent-namespace)
5. [Local Development & Testing](#local-development--testing)
6. [Troubleshooting & Diagnostics](#troubleshooting--diagnostics)

---

## Architecture Overview

The `google-mcp-auth-proxy` is a lightweight, stateless reverse proxy designed to sit between your in-cluster agent framework (`kagent`) and Google Cloud's hosted MCP servers (such as GKE MCP or Vertex AI).

```
┌─────────────────┐   plain HTTP    ┌──────────────────────┐   HTTPS + Bearer    ┌────────────────────┐
│  kagent-agent   │ ──────────────▶ │  google-mcp-auth-    │ ──────────────────▶ │  Google MCP Server │
│   (client pod)  │  (unauthenticated)│       proxy          │   (OAuth Token)     │ (container.google…)│
└─────────────────┘                 │  uses Workload       │                     └────────────────────┘
                                    │  Identity Federation │
                                    └──────────────────────┘
```

By deploying this proxy, your agents can authenticate to Google APIs without needing to manage long-lived GCP service account keys inside Kubernetes Secrets.

---

## Generic Usage & Configuration

The proxy is configured entirely via environment variables:

| Environment Variable | Description | Default Value |
| :--- | :--- | :--- |
| `UPSTREAM_URL` | The destination Google MCP endpoint where requests are forwarded. | `https://container.googleapis.com` (GKE MCP global endpoint) |
| `OAUTH_SCOPES` | Comma-separated list of Google OAuth scopes. If empty, defaults to GKE scope when targeting GKE, and GCP scope otherwise. | `https://www.googleapis.com/auth/container` (when GKE is targeted) |
| `LISTEN_ADDR` | The local port and address that the proxy server binds to inside its container. | `:8080` |

### Scope Auto-Resolution
To simplify configuration, the proxy dynamically resolves scopes based on the `UPSTREAM_URL`:
* If `UPSTREAM_URL` contains `container.googleapis.com`, it automatically requests the GKE container API scope: `https://www.googleapis.com/auth/container`.
* For any other URL, it requests the broader GCP scope: `https://www.googleapis.com/auth/cloud-platform`.

---

## GKE Workload Identity Federation Setup

Instead of downloading a Google Service Account (GSA) JSON key and injecting it as a secret, GKE Workload Identity Federation allows the **Kubernetes ServiceAccount (KSA)** principal to authenticate to Google Cloud directly.

### Step 1: Ensure Workload Identity is Enabled
Make sure your GKE cluster has Workload Identity enabled:
```bash
gcloud container clusters describe <cluster-name> \
  --zone <zone> \
  --format="value(workloadIdentityConfig.workloadPool)"
```
*(If empty, you must enable Workload Identity on your cluster and its node pools).*

### Step 2: Retrieve Project Information
Set your local environment variables for the binding setup:
```bash
export PROJECT_ID="gke-demos-345619"
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')
export NAMESPACE="kagent"
export KSA_NAME="google-mcp-auth-proxy"
```

### Step 3: Grant IAM Roles to the KSA Principal
Because we do not use an intermediate GSA, you grant GCP IAM roles **directly** to the Kubernetes ServiceAccount's workload identity subject.

To allow the proxy to manage GKE clusters and interact with the GKE MCP Server, grant:
1. The **Kubernetes Engine Admin** role (`roles/container.admin`) and the **MCP Tool User** role (`roles/mcp.toolUser`) directly to the KSA principal.
2. The **Service Account User** role (`roles/iam.serviceAccountUser`) on the GKE Node Service Account (e.g. the Compute Engine default service account or a custom node service account) to allow GKE to associate that service account with the VM nodes during cluster creation.

```bash
# 1. Grant GKE Admin role directly to the KSA Workload Identity principal
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --role=roles/container.admin \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${KSA_NAME}" \
  --condition=None

# 2. Grant MCP Tool User role directly to the KSA Workload Identity principal
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --role=roles/mcp.toolUser \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${KSA_NAME}" \
  --condition=None

# 3. Grant Service Account User role on the Node Service Account (e.g., Compute Engine default service account)
# Replace '${PROJECT_NUMBER}-compute@developer.gserviceaccount.com' with your custom node service account if applicable.
gcloud iam service-accounts add-iam-policy-binding \
  ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --role=roles/iam.serviceAccountUser \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${KSA_NAME}"
```

#### Explanation of KSA Principal URI:
- `workloadIdentityPools/${PROJECT_ID}.svc.id.goog` — GKE's managed workload identity federation pool.
- `subject/ns/${NAMESPACE}/sa/${KSA_NAME}` — Scopes the federated token permission exclusively to the KSA `google-mcp-auth-proxy` running in namespace `kagent`.

---

## Deploying to the `kagent` Namespace

We provide pre-built, ready-to-apply manifests under the `dist/` directory generated using Kustomize.

### Option A: Standard Core Installation (Recommended)
This installs only the `google-mcp-auth-proxy` Deployment, ServiceAccount, and Service. This is ideal if you want to define your own `RemoteMCPServer` custom resources manually:

```bash
kubectl apply -f dist/install.yaml
```

### Option B: Extended Installation (Proxy + RemoteMCPServer CRD)
This installs the proxy core **and** registers/deploys the `RemoteMCPServer` custom resource in one command:

```bash
kubectl apply -f dist/install-with-remotemcp.yaml
```

### Customizing Namespace or Image with Kustomize
If you prefer not to use the pre-built `dist/` manifests and want to customize the deployment (e.g. change the namespace from `kagent` to `default` or override the image registry):

1. Edit the configurations in `manifests/base/kustomization.yaml`:
   ```yaml
   namespace: your-custom-namespace
   ```
2. Build and apply your customized manifests:
   ```bash
   kubectl apply -k manifests/base/
   ```

---

## Local Development & Testing

You can easily run and test the proxy locally before deploying it.

### 1. Prerequisites
- Go 1.20+
- `gcloud` SDK installed and authenticated (`gcloud auth application-default login`)

### 2. Running Locally
Run the proxy binary with custom variables:
```bash
export UPSTREAM_URL="https://container.googleapis.com"
export OAUTH_SCOPES="https://www.googleapis.com/auth/container"
export LISTEN_ADDR="127.0.0.1:8080"

go run .
```

### 3. Executing the Local Smoketest
We include an integration script `scripts/smoketest.sh` that validates the proxy locally, verifies health endpoints, and executes a test query (`list_clusters`) end-to-end to confirm successful authentication:

```bash
make smoketest
```

---

## Troubleshooting & Diagnostics

If your agent is failing to retrieve schemas or call tools through the proxy, check these common diagnostic points:

### 1. Check the Proxy Logs
Review the container logs for authentication or proxy errors:
```bash
kubectl logs -n kagent -l app=google-mcp-auth-proxy --tail=100
```
*Look for `[ERROR] Failed to obtain OAuth token` (indicating Workload Identity or GCP-side permission issues).*

### 2. Verify Health Check
Ensure the proxy's server is listening and healthy inside the cluster:
```bash
kubectl exec -n kagent -it deploy/google-mcp-auth-proxy -- curl -i http://localhost:8080/healthz
```

### 3. Check GKE Workload Identity Bindings
Ensure the GSA metadata mapping is correct. Run a pod that executes commands to verify if it can reach the GKE metadata server:
```bash
kubectl run wi-test -n kagent --rm -i --tty --image=google/cloud-sdk:slim \
  --overrides='{"spec": {"serviceAccountName": "google-mcp-auth-proxy"}}' \
  -- gcloud auth print-access-token
```
*If this prints a valid access token, Workload Identity is configured correctly on the cluster. If it fails, check GKE Workload Identity configurations.*
