// Command greeter runs the sample service used in the what3words DevOps
// technical exercise.
//
// Configuration is by environment variable:
//
//	GREETING_NAME             required. The service exits non-zero if it is unset.
//	PORT                      default 8080
//	VERSION                   default "dev"
//	WARMUP_SECONDS            default 30
//	SHUTDOWN_DELAY_SECONDS    default 10
//	DRAIN_TIMEOUT_SECONDS     default 20
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"greeter/internal/greeter"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("fatal", "error", err)
		os.Exit(2)
	}
}

func run(log *slog.Logger) error {
	name := os.Getenv("GREETING_NAME")
	if name == "" {
		return errors.New("GREETING_NAME is required and must not be empty")
	}

	port, err := intFromEnv("PORT", 8080)
	if err != nil {
		return err
	}
	warmup, err := intFromEnv("WARMUP_SECONDS", 30)
	if err != nil {
		return err
	}
	shutdownDelay, err := intFromEnv("SHUTDOWN_DELAY_SECONDS", 10)
	if err != nil {
		return err
	}
	drainTimeout, err := intFromEnv("DRAIN_TIMEOUT_SECONDS", 20)
	if err != nil {
		return err
	}

	version := os.Getenv("VERSION")
	if version == "" {
		version = "dev"
	}

	srv := greeter.New(greeter.Config{
		GreetingName:  name,
		Version:       version,
		Warmup:        time.Duration(warmup) * time.Second,
		ShutdownDelay: time.Duration(shutdownDelay) * time.Second,
	}, log)

	warmupCtx, cancelWarmup := context.WithCancel(context.Background())
	defer cancelWarmup()
	srv.StartWarmup(warmupCtx)

	httpServer := &http.Server{
		Addr:              net.JoinHostPort("", strconv.Itoa(port)),
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Listen before announcing, so that a bind failure is reported as a
	// startup error rather than as a mysteriously unreachable service.
	listener, err := net.Listen("tcp", httpServer.Addr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", httpServer.Addr, err)
	}
	log.Info("listening", "addr", httpServer.Addr, "version", version,
		"warmup_seconds", warmup, "shutdown_delay_seconds", shutdownDelay)

	serveErr := make(chan error, 1)
	go func() {
		if err := httpServer.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
			return
		}
		serveErr <- nil
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)

	select {
	case err := <-serveErr:
		return err
	case sig := <-signals:
		log.Info("signal received, shutting down", "signal", sig.String())
	}

	// Fail readiness first and pause, so the cluster stops sending new
	// requests here before the listener closes.
	delay := srv.BeginDrain()
	cancelWarmup()
	time.Sleep(delay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(),
		time.Duration(drainTimeout)*time.Second)
	defer cancel()

	log.Info("closing listener and draining in-flight requests",
		"timeout_seconds", drainTimeout)
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	log.Info("shutdown complete")
	return <-serveErr
}

func intFromEnv(key string, fallback int) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer, got %q", key, raw)
	}
	if value < 0 {
		return 0, fmt.Errorf("%s must not be negative, got %d", key, value)
	}
	return value, nil
}
