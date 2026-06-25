#!/bin/bash
# smoketest.sh - End-to-end integration and sanity test for google-mcp-auth-proxy.
#
# This script runs the proxy locally, verifies health checks, and optionally performs
# end-to-end authenticated requests against real Google MCP endpoints (e.g., GKE MCP).

set -euo pipefail

# Configurable environment variables with defaults
UPSTREAM_URL="${UPSTREAM_URL:-https://container.googleapis.com}"
OAUTH_SCOPES="${OAUTH_SCOPES:-https://www.googleapis.com/auth/container}"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:18080}"
GCP_PROJECT="${GCP_PROJECT:-}"

# Colors for elegant logging
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_err() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Resolve active GCP project if unspecified
if [[ -z "${GCP_PROJECT}" ]]; then
  if command -v gcloud &>/dev/null; then
    GCP_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  fi
fi

log_info "Configuration:"
log_info "  UPSTREAM_URL: ${UPSTREAM_URL}"
log_info "  OAUTH_SCOPES: ${OAUTH_SCOPES}"
log_info "  LISTEN_ADDR:  ${LISTEN_ADDR}"
log_info "  GCP_PROJECT:  ${GCP_PROJECT:-<not configured>}"

# 1. Start the proxy in the background using 'go run'
log_info "Starting google-mcp-auth-proxy in the background..."
export UPSTREAM_URL
export OAUTH_SCOPES
export LISTEN_ADDR

go run . > /tmp/smoketest_proxy.log 2>&1 &
PROXY_PID=$!

# Register a trap to kill the proxy when the script exits
cleanup() {
  log_info "Stopping proxy (PID: ${PROXY_PID})..."
  kill "${PROXY_PID}" || true
  wait "${PROXY_PID}" 2>/dev/null || true
  log_info "Proxy stopped."
}
trap cleanup EXIT

# 2. Wait and verify health check
log_info "Waiting for proxy to become healthy..."
HEALTHY=false
for i in {1..15}; do
  if curl -s "http://${LISTEN_ADDR}/healthz" >/dev/null; then
    HEALTHY=true
    break
  fi
  sleep 0.5
done

if [[ "${HEALTHY}" != "true" ]]; then
  log_err "Proxy failed to start or did not become healthy in time. Proxy logs:"
  cat /tmp/smoketest_proxy.log
  exit 1
fi
log_success "Proxy is up and healthy on http://${LISTEN_ADDR}!"

# 3. Test public tools list (sanity check)
log_info "Retrieving public tools list via local proxy..."
TOOLS_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "tools/list", "id": 1}' \
  "http://${LISTEN_ADDR}/mcp")

if echo "${TOOLS_RESPONSE}" | grep -q "list_clusters"; then
  log_success "Public tools/list query succeeded!"
else
  log_err "tools/list query failed or returned unexpected content. Response:"
  echo "${TOOLS_RESPONSE}"
  log_info "Proxy logs:"
  cat /tmp/smoketest_proxy.log
  exit 1
fi

# 4. Try end-to-end authenticated check if GCP project is available
if [[ -n "${GCP_PROJECT}" ]] && [[ "${UPSTREAM_URL}" == *"container.googleapis.com"* ]]; then
  log_info "Found active GCP project: ${GCP_PROJECT}. Testing end-to-end GKE auth/authz..."
  
  CALL_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{
      \"jsonrpc\": \"2.0\",
      \"method\": \"tools/call\",
      \"params\": {
        \"name\": \"list_clusters\",
        \"arguments\": {
          \"parent\": \"projects/${GCP_PROJECT}/locations/-\"
        }
      },
      \"id\": 1
    }" \
    "http://${LISTEN_ADDR}/mcp")

  if echo "${CALL_RESPONSE}" | grep -q "clusters"; then
    log_success "End-to-end authentication and authorization verified successfully!"
    log_success "Successfully listed GKE clusters from project '${GCP_PROJECT}'!"
  else
    log_err "Authenticated tools/call query failed. End-to-end auth might be misconfigured. Response:"
    echo "${CALL_RESPONSE}"
    log_info "Proxy logs:"
    cat /tmp/smoketest_proxy.log
    exit 1
  fi
else
  log_warn "Skipping authenticated end-to-end check because GCP_PROJECT is unset or UPSTREAM_URL is not set to GKE MCP."
  log_info "To run end-to-end GKE verification, specify GCP_PROJECT=<project_id> and run with local gcloud credentials active."
fi

log_success "Smoketest completed successfully!"
