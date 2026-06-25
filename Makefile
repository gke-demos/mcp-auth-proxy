# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Image registry and name
REGISTRY ?= ghcr.io
IMAGE_NAME ?= gke-demos/mcp-auth-proxy
TAG ?= latest
IMG ?= $(REGISTRY)/$(IMAGE_NAME):$(TAG)

.PHONY: all
all: build test

.PHONY: build
build: ## Build the proxy binary.
	go build -v -o bin/mcp-auth-proxy .

.PHONY: test
test: ## Run unit tests.
	go test -v -race -coverprofile=coverage.out ./...

.PHONY: fmt
fmt: ## Run go fmt on all Go source files.
	go fmt ./...

.PHONY: fmt-check
fmt-check: ## Verify all Go source files are formatted.
	@if [ -n "$$(gofmt -l .)" ]; then \
		echo "Go source files are not formatted. Run 'make fmt' to format them:"; \
		gofmt -l .; \
		exit 1; \
	fi

.PHONY: vet
vet: ## Run go vet on Go source files.
	go vet ./...

.PHONY: tidy
tidy: ## Verify go mod tidy is clean.
	go mod tidy
	git diff --exit-code go.mod go.sum

.PHONY: vuln
vuln: ## Run govulncheck.
	go install golang.org/x/vuln/cmd/govulncheck@latest
	govulncheck ./...

.PHONY: smoketest
smoketest: ## Run the local integration/smoketest.
	./scripts/smoketest.sh

.PHONY: build-installer
build-installer: ## Generate consolidated YAMLs with the specified image.
	mkdir -p dist
	# Build core installation (proxy only)
	kubectl kustomize manifests/base/ | \
		sed "s|image: ghcr.io/gke-demos/mcp-auth-proxy:latest|image: $(IMG)|g" > dist/install.yaml
	# Build overlay installation (proxy + RemoteMCPServer)
	kubectl kustomize manifests/with-remotemcp/ | \
		sed "s|image: ghcr.io/gke-demos/mcp-auth-proxy:latest|image: $(IMG)|g" > dist/install-with-remotemcp.yaml
