# MCP Auth Proxy

An in-cluster reverse proxy that terminates plain HTTP from `kagent` agents, mints a Google OAuth token via Application Default Credentials (ADC), attaches it as the `Authorization` header, and forwards the request to the configured Google MCP endpoint.

This allows agents to authenticate to Google MCP endpoints using Workload Identity Federation for GKE + ADC with no agent churn and no intermediate Google service account.

## Documentation

For detailed design, architecture, configuration, and rollout instructions, please refer to:
* [MCP Auth Proxy Design & Rollout Specification](docs/mcp-proxy-design.md)

## Features

- Use Workload Identity Federation for GKE with no long-lived credentials in Secrets or env vars.
- Transparent token refresh so agents stay running across refreshes.
- Zero-churn proxy architecture.

## Local Development & Testing

You can verify the proxy and its authentication mechanism locally before deploying it to your GKE cluster.

### Prerequisites

- A Go development environment (1.20+)
- Google Cloud SDK (`gcloud` CLI) configured and authenticated to a project with GKE MCP enabled.

### Running the Smoketest

We provide a self-contained smoketest script that starts the proxy locally, verifies its health endpoint, queries public tools, and performs an authenticated end-to-end tool call (`list_clusters`) against GKE MCP to verify auth and authz:

```bash
./scripts/smoketest.sh
```

You can customize the test variables if needed:

```bash
UPSTREAM_URL="https://container.googleapis.com" OAUTH_SCOPES="https://www.googleapis.com/auth/container" ./scripts/smoketest.sh
```
