package main

import (
	"context"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"

	"golang.org/x/oauth2/google"
)

type loggingResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
	lrw.statusCode = code
	lrw.ResponseWriter.WriteHeader(code)
}

func main() {
	upstreamStr := os.Getenv("UPSTREAM_URL")
	if upstreamStr == "" {
		upstreamStr = "https://container.googleapis.com"
	}

	upstreamURL, err := url.Parse(upstreamStr)
	if err != nil {
		log.Fatalf("Invalid UPSTREAM_URL %q: %v", upstreamStr, err)
	}

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8080"
	}

	ctx := context.Background()
	scopesStr := os.Getenv("OAUTH_SCOPES")
	var scopes []string
	if scopesStr != "" {
		parts := strings.Split(scopesStr, ",")
		for _, part := range parts {
			trimmed := strings.TrimSpace(part)
			if trimmed != "" {
				scopes = append(scopes, trimmed)
			}
		}
	}

	// If no scopes were explicitly configured, choose the default based on the target upstream URL.
	if len(scopes) == 0 {
		if strings.Contains(upstreamStr, "container.googleapis.com") {
			scopes = []string{"https://www.googleapis.com/auth/container"}
		} else {
			scopes = []string{"https://www.googleapis.com/auth/cloud-platform"}
		}
	}

	log.Printf("Initializing Google Default Token Source with scopes: %v", scopes)
	tokenSource, err := google.DefaultTokenSource(ctx, scopes...)
	if err != nil {
		log.Fatalf("Failed to initialize Google Default Token Source: %v", err)
	}

	log.Printf("Starting google-mcp-auth-proxy...")
	log.Printf("Listening on %s", listenAddr)
	log.Printf("Proxying to %s", upstreamURL.String())

	// Health check endpoint
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	})

	// Reverse proxy endpoint
	proxy := httputil.NewSingleHostReverseProxy(upstreamURL)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = upstreamURL.Host
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		token, err := tokenSource.Token()
		if err != nil {
			log.Printf("[ERROR] Failed to obtain OAuth token: %v", err)
			http.Error(w, "Failed to retrieve Google OAuth token", http.StatusBadGateway)
			return
		}

		r.Header.Set("Authorization", "Bearer "+token.AccessToken)

		lrw := &loggingResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		proxy.ServeHTTP(lrw, r)

		log.Printf("[INFO] %s %s -> %d (duration: %s)", r.Method, r.URL.Path, lrw.statusCode, time.Since(start))
	})

	if err := http.ListenAndServe(listenAddr, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
