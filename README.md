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
