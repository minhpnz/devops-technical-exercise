package greeter

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testServer(t *testing.T, cfg Config) *Server {
	t.Helper()
	if cfg.GreetingName == "" {
		cfg.GreetingName = "Tester"
	}
	if cfg.Version == "" {
		cfg.Version = "test"
	}
	return New(cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func get(t *testing.T, h http.Handler, target string) (int, string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, target, nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

func TestRootGreetsWithConfiguredName(t *testing.T) {
	s := testServer(t, Config{GreetingName: "Mai"})
	code, body := get(t, s.Handler(), "/")
	if code != http.StatusOK {
		t.Fatalf("status = %d, want %d", code, http.StatusOK)
	}
	if !strings.Contains(body, "Mai") {
		t.Errorf("body = %q, want it to contain the configured name", body)
	}
}

func TestUnknownPathIsNotFound(t *testing.T) {
	s := testServer(t, Config{})
	code, _ := get(t, s.Handler(), "/no-such-path")
	if code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", code, http.StatusNotFound)
	}
}

// Liveness must succeed during warm-up. A liveness probe that fails while the
// service is still starting would restart it forever.
func TestHealthzSucceedsDuringWarmup(t *testing.T) {
	s := testServer(t, Config{Warmup: time.Hour})
	code, _ := get(t, s.Handler(), "/healthz")
	if code != http.StatusOK {
		t.Errorf("status = %d, want %d during warm-up", code, http.StatusOK)
	}
}

func TestReadyzFailsDuringWarmupThenSucceeds(t *testing.T) {
	s := testServer(t, Config{Warmup: 50 * time.Millisecond})
	h := s.Handler()

	code, body := get(t, h, "/readyz")
	if code != http.StatusServiceUnavailable {
		t.Fatalf("status during warm-up = %d, want %d", code, http.StatusServiceUnavailable)
	}
	if !strings.Contains(body, "warming up") {
		t.Errorf("body during warm-up = %q, want it to say warming up", body)
	}

	s.StartWarmup(context.Background())
	waitFor(t, s.Ready, time.Second, "service to become ready")

	code, body = get(t, h, "/readyz")
	if code != http.StatusOK {
		t.Fatalf("status after warm-up = %d, want %d", code, http.StatusOK)
	}
	if !strings.Contains(body, "ready") {
		t.Errorf("body after warm-up = %q, want it to say ready", body)
	}
}

func TestBeginDrainFailsReadinessAndReportsDraining(t *testing.T) {
	s := testServer(t, Config{Warmup: time.Millisecond, ShutdownDelay: 7 * time.Second})
	h := s.Handler()
	s.StartWarmup(context.Background())
	waitFor(t, s.Ready, time.Second, "service to become ready")

	if delay := s.BeginDrain(); delay != 7*time.Second {
		t.Errorf("BeginDrain delay = %s, want 7s", delay)
	}
	code, body := get(t, h, "/readyz")
	if code != http.StatusServiceUnavailable {
		t.Errorf("status while draining = %d, want %d", code, http.StatusServiceUnavailable)
	}
	if !strings.Contains(body, "draining") {
		t.Errorf("body while draining = %q, want it to say draining", body)
	}
	// Liveness must still pass while draining, otherwise the kubelet would
	// restart a pod that is deliberately shutting down.
	if code, _ := get(t, h, "/healthz"); code != http.StatusOK {
		t.Errorf("healthz while draining = %d, want %d", code, http.StatusOK)
	}
}

// Warm-up must not resurrect readiness after a drain has started.
func TestWarmupDoesNotOverrideDrain(t *testing.T) {
	s := testServer(t, Config{Warmup: 80 * time.Millisecond})
	s.StartWarmup(context.Background())
	s.BeginDrain()
	time.Sleep(200 * time.Millisecond)
	if s.Ready() {
		t.Error("service became ready after drain started; readiness must stay false")
	}
}

func TestBoomAlwaysFails(t *testing.T) {
	s := testServer(t, Config{})
	code, _ := get(t, s.Handler(), "/boom")
	if code != http.StatusInternalServerError {
		t.Errorf("status = %d, want %d", code, http.StatusInternalServerError)
	}
}

func TestWorkSleepsForRequestedDuration(t *testing.T) {
	s := testServer(t, Config{})
	start := time.Now()
	code, _ := get(t, s.Handler(), "/work?ms=120")
	elapsed := time.Since(start)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want %d", code, http.StatusOK)
	}
	if elapsed < 120*time.Millisecond {
		t.Errorf("elapsed = %s, want at least 120ms", elapsed)
	}
}

func TestWorkRejectsInvalidDuration(t *testing.T) {
	s := testServer(t, Config{})
	code, _ := get(t, s.Handler(), "/work?ms=abc")
	if code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", code, http.StatusBadRequest)
	}
}

func TestVersionIsReported(t *testing.T) {
	s := testServer(t, Config{Version: "1.2.3"})
	code, body := get(t, s.Handler(), "/version")
	if code != http.StatusOK {
		t.Fatalf("status = %d, want %d", code, http.StatusOK)
	}
	if strings.TrimSpace(body) != "1.2.3" {
		t.Errorf("body = %q, want 1.2.3", strings.TrimSpace(body))
	}
}

func waitFor(t *testing.T, cond func() bool, limit time.Duration, what string) {
	t.Helper()
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out after %s waiting for %s", limit, what)
}
