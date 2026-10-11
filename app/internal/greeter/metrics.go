package greeter

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

// buckets are the latency histogram boundaries, in seconds.
var buckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

type counterKey struct {
	path   string
	method string
	status string
}

type histogram struct {
	counts []uint64 // one per bucket, non-cumulative
	inf    uint64
	sum    float64
	count  uint64
}

func (h *histogram) observe(seconds float64) {
	h.sum += seconds
	h.count++
	for i, b := range buckets {
		if seconds <= b {
			h.counts[i]++
			return
		}
	}
	h.inf++
}

// Metrics collects the handful of series this service exposes. It is a
// deliberately small hand-rolled implementation so that the application has no
// external dependencies.
type Metrics struct {
	mu        sync.Mutex
	requests  map[counterKey]uint64
	durations map[string]*histogram
}

func newMetrics() *Metrics {
	return &Metrics{
		requests:  make(map[counterKey]uint64),
		durations: make(map[string]*histogram),
	}
}

func (m *Metrics) observe(path, method, status string, seconds float64) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.requests[counterKey{path: path, method: method, status: status}]++

	h, ok := m.durations[path]
	if !ok {
		h = &histogram{counts: make([]uint64, len(buckets))}
		m.durations[path] = h
	}
	h.observe(seconds)
}

// render writes the metrics in the Prometheus text exposition format. Label
// values are written with %q, whose escaping of backslash, double quote and
// newline is what the text format requires.
func (m *Metrics) render(version string, ready bool) string {
	m.mu.Lock()
	defer m.mu.Unlock()

	var b strings.Builder

	b.WriteString("# HELP greeter_build_info Build information for the running binary.\n")
	b.WriteString("# TYPE greeter_build_info gauge\n")
	fmt.Fprintf(&b, "greeter_build_info{version=%q} 1\n", version)

	b.WriteString("# HELP greeter_ready Whether the service is ready to serve traffic.\n")
	b.WriteString("# TYPE greeter_ready gauge\n")
	readyValue := 0
	if ready {
		readyValue = 1
	}
	fmt.Fprintf(&b, "greeter_ready %d\n", readyValue)

	b.WriteString("# HELP greeter_http_requests_total Total HTTP requests handled.\n")
	b.WriteString("# TYPE greeter_http_requests_total counter\n")
	keys := make([]counterKey, 0, len(m.requests))
	for k := range m.requests {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].path != keys[j].path {
			return keys[i].path < keys[j].path
		}
		if keys[i].method != keys[j].method {
			return keys[i].method < keys[j].method
		}
		return keys[i].status < keys[j].status
	})
	for _, k := range keys {
		fmt.Fprintf(&b, "greeter_http_requests_total{path=%q,method=%q,status=%q} %d\n",
			k.path, k.method, k.status, m.requests[k])
	}

	b.WriteString("# HELP greeter_http_request_duration_seconds HTTP request latency.\n")
	b.WriteString("# TYPE greeter_http_request_duration_seconds histogram\n")
	paths := make([]string, 0, len(m.durations))
	for p := range m.durations {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		h := m.durations[p]
		var cumulative uint64
		for i, bound := range buckets {
			cumulative += h.counts[i]
			fmt.Fprintf(&b, "greeter_http_request_duration_seconds_bucket{path=%q,le=%q} %d\n",
				p, formatBucket(bound), cumulative)
		}
		cumulative += h.inf
		fmt.Fprintf(&b, "greeter_http_request_duration_seconds_bucket{path=%q,le=\"+Inf\"} %d\n", p, cumulative)
		fmt.Fprintf(&b, "greeter_http_request_duration_seconds_sum{path=%q} %g\n", p, h.sum)
		fmt.Fprintf(&b, "greeter_http_request_duration_seconds_count{path=%q} %d\n", p, h.count)
	}

	return b.String()
}

// formatBucket renders a bucket boundary without trailing zeros, so the le
// label reads 0.01 and 10 rather than 0.010 and 10.000.
func formatBucket(f float64) string {
	s := fmt.Sprintf("%.3f", f)
	s = strings.TrimRight(s, "0")
	return strings.TrimSuffix(s, ".")
}
