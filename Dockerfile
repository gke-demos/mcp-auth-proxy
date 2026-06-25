# Build stage
FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./

# Build statically linked binary with stripped debug information
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o google-mcp-auth-proxy main.go

# Production stage
FROM gcr.io/distroless/static-debian12

WORKDIR /

COPY --from=builder /app/google-mcp-auth-proxy /google-mcp-auth-proxy

EXPOSE 8080

ENTRYPOINT ["/google-mcp-auth-proxy"]
