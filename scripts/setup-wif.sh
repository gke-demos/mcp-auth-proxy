#!/bin/bash
# setup-wif.sh - Setup GKE Workload Identity Federation direct bindings for GKE MCP Auth Proxy.
#
# This script automates granting the necessary GCP IAM roles directly to the Kubernetes
# ServiceAccount principal under GKE Workload Identity Federation, ensuring it has all
# permissions required to manage clusters and talk to GKE MCP servers.
#
# Usage:
#   ./scripts/setup-wif.sh [PROJECT_ID]
#
# Overrides:
#   export NAMESPACE="custom-namespace"
#   export KSA_NAME="custom-ksa"
#   export NODE_SA="custom-node-sa@project.iam.gserviceaccount.com"
#   export DRY_RUN="true" (for dry-run mode)

set -euo pipefail

# Colors for output
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

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# 1. Prerequisite checks
if ! command -v gcloud &> /dev/null; then
  log_error "gcloud CLI is not installed. Please install the Google Cloud SDK and try again."
  exit 1
fi

# 2. Configure variables
PROJECT_ID="${1:-${PROJECT_ID:-}}"
if [[ -z "${PROJECT_ID}" ]]; then
  log_info "No PROJECT_ID specified. Attempting to retrieve active gcloud project..."
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "${PROJECT_ID}" ]]; then
    log_error "Could not detect active gcloud project. Please pass PROJECT_ID as an argument or set the PROJECT_ID environment variable."
    echo "Usage: $0 [PROJECT_ID]"
    exit 1
  fi
fi

NAMESPACE="${NAMESPACE:-kagent}"
KSA_NAME="${KSA_NAME:-google-mcp-auth-proxy}"
DRY_RUN="${DRY_RUN:-false}"

log_info "Configuring IAM bindings for:"
echo "  GCP Project:      ${PROJECT_ID}"
echo "  K8s Namespace:    ${NAMESPACE}"
echo "  K8s SA Name:      ${KSA_NAME}"

# Retrieve project number
log_info "Retrieving project number for project '${PROJECT_ID}'..."
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)
if [[ -z "${PROJECT_NUMBER}" ]]; then
  log_error "Failed to retrieve project number for project '${PROJECT_ID}'. Please verify your project ID and gcloud permissions."
  exit 1
fi
echo "  Project Number:   ${PROJECT_NUMBER}"

# Default node service account
NODE_SA="${NODE_SA:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"
echo "  Node SA:          ${NODE_SA}"
echo

# Construct the Workload Identity principal member string
MEMBER="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/${NAMESPACE}/sa/${KSA_NAME}"

# Helper function to bind roles
add_binding() {
  local role="$1"
  log_info "Binding role '${role}' to KSA principal..."
  
  local cmd="gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --role=${role} \
    --member=${MEMBER} \
    --condition=None"
    
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] Would run: ${cmd}"
  else
    eval "${cmd}" >/dev/null
    log_success "Bound role '${role}' successfully."
  fi
}

# Helper function to bind node service account user
add_sa_binding() {
  local sa="$1"
  local role="roles/iam.serviceAccountUser"
  log_info "Binding role '${role}' on Service Account '${sa}'..."
  
  local cmd="gcloud iam service-accounts add-iam-policy-binding ${sa} \
    --role=${role} \
    --member=${MEMBER}"
    
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] Would run: ${cmd}"
  else
    eval "${cmd}" >/dev/null
    log_success "Bound role '${role}' on service account '${sa}' successfully."
  fi
}

# Run bindings
if [[ "${DRY_RUN}" == "true" ]]; then
  log_warn "=== DRY RUN MODE: No changes will be applied ==="
fi

# 1. Kubernetes Engine Admin
add_binding "roles/container.admin"

# 2. MCP Tool User
add_binding "roles/mcp.toolUser"

# 3. Service Account User on node service account
add_sa_binding "${NODE_SA}"

if [[ "${DRY_RUN}" == "true" ]]; then
  log_warn "=== Dry run complete. No changes were applied. ==="
else
  log_success "=== Setup complete! All GKE Workload Identity Federation bindings are active. ==="
fi
