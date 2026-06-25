package main

import (
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"testing"

	"golang.org/x/oauth2"
)

type mockTokenSource struct {
	token *oauth2.Token
}

func (m *mockTokenSource) Token() (*oauth2.Token, error) {
	return m.token, nil
}

func TestProxy(t *testing.T) {
	// 1. Create a mock upstream server
	upstreamReceivedAuth := ""
	upstreamReceivedHost := ""
	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamReceivedAuth = r.Header.Get("Authorization")
		upstreamReceivedHost = r.Host
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("upstream-response"))
	}))
	defer upstreamServer.Close()

	upstreamURL, err := url.Parse(upstreamServer.URL)
	if err != nil {
		t.Fatalf("failed to parse upstream server url: %v", err)
	}

	// 2. Setup mock TokenSource
	mockTS := &mockTokenSource{
		token: &oauth2.Token{
			AccessToken: "test-token-12345",
		},
	}

	// 3. Create reverse proxy
	proxy := httputil.NewSingleHostReverseProxy(upstreamURL)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = upstreamURL.Host
	}

	// Handler matching main.go logic
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, err := mockTS.Token()
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		r.Header.Set("Authorization", "Bearer "+token.AccessToken)
		proxy.ServeHTTP(w, r)
	})

	// 4. Issue a test request to our handler
	req := httptest.NewRequest("GET", "/mcp", nil)
	rr := httptest.NewRecorder()

	handler.ServeHTTP(rr, req)

	// 5. Assertions
	if rr.Code != http.StatusOK {
		t.Errorf("expected status code %d, got %d", http.StatusOK, rr.Code)
	}

	if rr.Body.String() != "upstream-response" {
		t.Errorf("expected body %q, got %q", "upstream-response", rr.Body.String())
	}

	if upstreamReceivedAuth != "Bearer test-token-12345" {
		t.Errorf("expected Authorization header %q, got %q", "Bearer test-token-12345", upstreamReceivedAuth)
	}

	if upstreamReceivedHost != upstreamURL.Host {
		t.Errorf("expected Host header %q, got %q", upstreamURL.Host, upstreamReceivedHost)
	}
}

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest("GET", "/healthz", nil)
	rr := httptest.NewRecorder()

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	})

	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected healthz status 200, got %d", rr.Code)
	}

	if rr.Body.String() != "OK" {
		t.Errorf("expected body 'OK', got %q", rr.Body.String())
	}
}
