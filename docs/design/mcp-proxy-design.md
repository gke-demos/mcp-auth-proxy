# MCP Auth Proxy for Google Cloud MCP Servers

## Problem

kagent agents need to invoke Google Cloud's hosted MCP servers
(https://docs.cloud.google.com/mcp/authenticate-mcp), which require an
OAuth `Authorization: Bearer <token>` header. kagent's `RemoteMCPServer`
CRD supports static headers via `spec.headersFrom` (Secret-backed), but
not dynamic credential acquisition. Google OAuth access tokens expire
in ~1 hour, and refreshing them by mutating a Secret triggers an agent
reconcile and pod roll each cycle.

We want agents to authenticate to Google MCP endpoints using **Workload
Identity Federation for GKE + Application Default Credentials (ADC)**
with no agent churn and no intermediate Google service account.

## Goals

- Use Workload Identity Federation for GKE so no long-lived credentials
  live in Secrets or env vars, and no GSA impersonation hop is needed.
  IAM roles are granted directly to the KSA principal.
- Tokens refresh transparently; agents stay running across refreshes.
- One `RemoteMCPServer` per Google MCP endpoint, no `headersFrom`.
- Small surface area: one Deployment, one Service, one KSA + direct
  IAM bindings on the target GCP resources.

## Non-Goals

- Replacing kagent's `headersFrom` mechanism for non-Google MCP servers.
- Multi-tenant token issuance (per-user OAuth flows).
- Caching or rewriting MCP payloads.

## Design

```
┌────────────┐   plain HTTP    ┌──────────────────┐   HTTPS + Bearer    ┌──────────────────┐
│ kagent     │ ──────────────▶ │ google-mcp-auth- │ ──────────────────▶ │ Google MCP server│
│ agent pod  │                 │     proxy        │                     │ (cloud.google…)  │
└────────────┘                 │ KSA principal w/ │                     └──────────────────┘
                               │ direct IAM bind  │
                               │ (WIF for GKE)    │
                               └──────────────────┘
```

A small in-cluster reverse proxy terminates plain HTTP from kagent
agents, mints a Google OAuth token via ADC, attaches it as the
`Authorization` header, and forwards the request to the configured
Google MCP endpoint. The `google-auth` library handles token caching
and refresh; the proxy itself is stateless.

### Components

- **Deployment**: `google-mcp-auth-proxy` (single container, ~30 LOC).
  Listens on `:8080`. Reads `UPSTREAM_URL` from env.
- **ServiceAccount** (KSA): `google-mcp-auth-proxy`. **No GSA
  annotation** — under WIF for GKE, the KSA itself is the IAM principal.
- **IAM bindings**: the roles required by the upstream MCP server
  (e.g., `roles/aiplatform.user`) are granted directly to the KSA
  principal URI on the target project / resource. No intermediate GSA
  exists.
- **Service**: `google-mcp-auth-proxy.kagent:8080`.
- **RemoteMCPServer** (kagent CRD): `spec.url` points at the Service;
  no `headersFrom`.

### Authentication flow

1. Agent issues an MCP request to `http://google-mcp-auth-proxy.kagent:8080/mcp`.
2. Proxy looks up cached ADC credentials. On cold start or expiry, the
   `google-auth` library calls the GKE metadata server, which exchanges
   the KSA-projected token for a **federated** OAuth access token via
   the Security Token Service. The token's principal is the KSA
   directly — no GSA impersonation step.
3. Proxy sets `Authorization: Bearer <token>` and forwards the request
   to `UPSTREAM_URL` (the real Google MCP endpoint).
4. Response is streamed back to the agent unchanged.

Token refresh is implicit: `google-auth` refreshes before expiry on the
next request that needs the token. No restart, no Secret mutation, no
kagent reconcile.

### Example manifests

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: google-mcp-auth-proxy
  namespace: kagent
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: google-mcp-auth-proxy
  namespace: kagent
spec:
  replicas: 2
  selector:
    matchLabels: { app: google-mcp-auth-proxy }
  template:
    metadata:
      labels: { app: google-mcp-auth-proxy }
    spec:
      serviceAccountName: google-mcp-auth-proxy
      containers:
      - name: proxy
        image: ghcr.io/<org>/google-mcp-auth-proxy:v0.1.0
        env:
        - name: UPSTREAM_URL
          value: https://<google-mcp-endpoint>
        - name: LISTEN_ADDR
          value: ":8080"
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: { path: /healthz, port: 8080 }
---
apiVersion: v1
kind: Service
metadata:
  name: google-mcp-auth-proxy
  namespace: kagent
spec:
  selector: { app: google-mcp-auth-proxy }
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: google-cloud-mcp
  namespace: kagent
spec:
  url: http://google-mcp-auth-proxy.kagent:8080/mcp
  protocol: STREAMABLE_HTTP
  description: Google Cloud MCP via in-cluster auth proxy
```

GCP-side binding (one-time). Replace `PROJECT_ID` with your GCP project
ID and `PROJECT_NUMBER` with its numeric project number
(`gcloud projects describe PROJECT_ID --format='value(projectNumber)'`).
Grant whatever role(s) the upstream MCP server requires directly to the
KSA principal — no GSA, no impersonation hop:

```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --role=roles/aiplatform.user \
  --member="principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/kagent/sa/google-mcp-auth-proxy" \
  --condition=None
```

The principal URI breaks down as:

- `workloadIdentityPools/PROJECT_ID.svc.id.goog` — the fleet WIF pool
  GKE provisions per project.
- `subject/ns/kagent/sa/google-mcp-auth-proxy` — the KSA, scoped to
  namespace `kagent`.

Repeat with additional `--role=...` flags (or bind on a specific
resource, e.g. `gcloud storage buckets add-iam-policy-binding`) for
each permission the MCP server needs.

Prerequisites: Workload Identity Federation for GKE must be enabled on
the cluster (and node pool, on Standard clusters), and the upstream
Google API must support WIF tokens. APIs that don't accept federated
tokens still require the legacy KSA→GSA impersonation flow.

## Alternatives Considered

- **CronJob refreshes a Secret every ~50 min**: triggers a kagent
  reconcile each cycle and rolls the agent Deployment. Rejected:
  destroys session continuity.
- **Sidecar that writes a token file into a shared `emptyDir`**:
  doesn't help because the kagent agent reads its headers at config
  generation time, not per request.
- **Native ADC support in kagent's `RemoteMCPServer`**: ideal long-term,
  but requires upstream changes. The proxy is a clean shim that ships
  today and is removable later.

## Risks & Open Questions

- Plain HTTP between agent and proxy is fine inside the cluster, but
  if mesh-mandated mTLS is in place the proxy needs a sidecar or
  cert-manager-issued cert (use the same `spec.tls` pattern kagent
  already supports).
- One proxy Deployment per upstream MCP endpoint is the simplest
  model. If many Google MCP endpoints are needed, the proxy can be
  extended to route by path prefix to multiple upstreams.
- WIF for GKE only works on GKE clusters with the feature enabled
  (and on the node pool, for Standard clusters). Off-GKE clusters
  must either configure generic Workload Identity Federation
  (OIDC/SPIFFE → GCP via an external WIF pool) or fall back to
  mounting a GSA key Secret and setting
  `GOOGLE_APPLICATION_CREDENTIALS` — same proxy code, different
  credential source.
- A small number of Google APIs do not yet accept federated tokens.
  If the target MCP server's backing API is one of them, fall back to
  the legacy KSA→GSA impersonation flow (add the
  `iam.gke.io/gcp-service-account` annotation and grant
  `roles/iam.workloadIdentityUser` on the GSA).

## Rollout

1. Build & push proxy image.
2. Confirm WIF for GKE is enabled on the cluster (and node pool, on
   Standard).
3. Apply Deployment / Service / ServiceAccount.
4. Grant the required GCP IAM roles directly to the KSA principal URI
   (see `gcloud` command above).
5. Apply `RemoteMCPServer` pointing at the proxy.
6. Reference the `RemoteMCPServer` from an Agent's `tools` list and
   invoke a Google MCP tool end-to-end as a smoke test.
