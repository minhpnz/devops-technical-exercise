// Package greeter implements a small HTTP service with the operational
// characteristics of a real one: it takes time to become ready, it reports
// readiness separately from liveness, it exposes metrics, and it drains
// in-flight requests when asked to stop.
package greeter

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"
)

// Config holds the service configuration. GreetingName is required; the rest
// have defaults.
type Config struct {
	GreetingName  string
	Version       string
	Warmup        time.Duration
	ShutdownDelay time.Duration
}

// Server is the HTTP service.
type Server struct {
	cfg     Config
	log     *slog.Logger
	metrics *Metrics

	ready    atomic.Bool
	draining atomic.Bool
}

// New builds a Server. Call StartWarmup to begin the warm-up period.
func New(cfg Config, log *slog.Logger) *Server {
	return &Server{cfg: cfg, log: log, metrics: newMetrics()}
}

// StartWarmup marks the service ready once the warm-up period has elapsed. It
// returns immediately; the service serves traffic throughout, reporting
// not-ready until warm-up completes.
func (s *Server) StartWarmup(ctx context.Context) {
	go func() {
		s.log.Info("warm-up started", "duration", s.cfg.Warmup.String())
		select {
		case <-time.After(s.cfg.Warmup):
		case <-ctx.Done():
			s.log.Info("warm-up cancelled before completion")
			return
		}
		if s.draining.Load() {
			return
		}
		s.ready.Store(true)
		s.log.Info("warm-up complete, now ready")
	}()
}

// BeginDrain marks the service not ready and returns the delay a caller should
// wait before shutting the listener down. Failing readiness first, then
// waiting, gives the cluster time to stop routing new requests to this
// instance before it stops accepting them.
func (s *Server) BeginDrain() time.Duration {
	s.draining.Store(true)
	s.ready.Store(false)
	s.log.Info("draining: reporting not ready", "delay", s.cfg.ShutdownDelay.String())
	return s.cfg.ShutdownDelay
}

// Ready reports whether the service is currently ready to serve traffic.
func (s *Server) Ready() bool { return s.ready.Load() }

// Handler returns the service's HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.instrument("/", s.handleRoot))
	mux.HandleFunc("/healthz", s.instrument("/healthz", s.handleHealthz))
	mux.HandleFunc("/readyz", s.instrument("/readyz", s.handleReadyz))
	mux.HandleFunc("/version", s.instrument("/version", s.handleVersion))
	mux.HandleFunc("/boom", s.instrument("/boom", s.handleBoom))
	mux.HandleFunc("/work", s.instrument("/work", s.handleWork))
	// /metrics is deliberately not instrumented, so that scraping does not
	// inflate the series it reports.
	mux.HandleFunc("/metrics", s.handleMetrics)
	return mux
}

// statusRecorder captures the status code so it can be used as a metric label.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(b)
}

func (s *Server) instrument(path string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w}
		next(rec, r)
		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		s.metrics.observe(path, r.Method, strconv.Itoa(rec.status), time.Since(start).Seconds())
	}
}

func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	// The mux pattern "/" matches everything unmatched, so anything that is
	// not exactly "/" is a 404.
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "Hello %s, welcome to the what3words platform.\n", s.cfg.GreetingName)
}

// handleHealthz is the liveness endpoint. It succeeds for as long as the
// process is running, including during warm-up: a process that is still
// starting up is not a process that needs restarting.
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintln(w, "ok")
}

// handleReadyz is the readiness endpoint. It fails during warm-up and again as
// soon as shutdown begins.
func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	if !s.ready.Load() {
		w.WriteHeader(http.StatusServiceUnavailable)
		if s.draining.Load() {
			fmt.Fprintln(w, "draining")
			return
		}
		fmt.Fprintln(w, "warming up")
		return
	}
	fmt.Fprintln(w, "ready")
}

func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintln(w, s.cfg.Version)
}

// handleBoom always fails. It exists so that an alerting rule can be
// demonstrated firing on demand.
func (s *Server) handleBoom(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusInternalServerError)
	fmt.Fprintln(w, "boom")
}

// handleWork sleeps for the requested number of milliseconds, up to 30s. It
// exists so that in-flight requests can be observed during a rollout or a node
// drain.
func (s *Server) handleWork(w http.ResponseWriter, r *http.Request) {
	ms := 100
	if raw := r.URL.Query().Get("ms"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 0 {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprintln(w, "ms must be a non-negative integer")
			return
		}
		ms = parsed
	}
	if ms > 30000 {
		ms = 30000
	}

	select {
	case <-time.After(time.Duration(ms) * time.Millisecond):
	case <-r.Context().Done():
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "worked for %dms\n", ms)
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprint(w, s.metrics.render(s.cfg.Version, s.ready.Load()))
}
