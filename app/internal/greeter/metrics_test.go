package greeter

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRenderIncludesBuildInfoAndReadiness(t *testing.T) {
	m := newMetrics()

	out := m.render("1.0.0", true)
	if !strings.Contains(out, `greeter_build_info{version="1.0.0"} 1`) {
		t.Errorf("missing build info in:\n%s", out)
	}
	if !strings.Contains(out, "greeter_ready 1\n") {
		t.Errorf("expected greeter_ready 1 in:\n%s", out)
	}

	if out := m.render("1.0.0", false); !strings.Contains(out, "greeter_ready 0\n") {
		t.Errorf("expected greeter_ready 0 in:\n%s", out)
	}
}

func TestObserveProducesCounterAndHistogram(t *testing.T) {
	m := newMetrics()
	m.observe("/", http.MethodGet, "200", 0.003)
	m.observe("/", http.MethodGet, "200", 0.3)
	m.observe("/boom", http.MethodGet, "500", 0.001)

	out := m.render("test", true)

	for _, want := range []string{
		`greeter_http_requests_total{path="/",method="GET",status="200"} 2`,
		`greeter_http_requests_total{path="/boom",method="GET",status="500"} 1`,
		`greeter_http_request_duration_seconds_count{path="/"} 2`,
		`greeter_http_request_duration_seconds_bucket{path="/",le="+Inf"} 2`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

// Buckets must be cumulative, which is what the Prometheus histogram format
// requires. With observations at 0.003s and 0.3s, le="0.005" must be 1 and
// le="0.5" must be 2.
func TestHistogramBucketsAreCumulative(t *testing.T) {
	m := newMetrics()
	m.observe("/", http.MethodGet, "200", 0.003)
	m.observe("/", http.MethodGet, "200", 0.3)

	out := m.render("test", true)
	for _, want := range []string{
		`greeter_http_request_duration_seconds_bucket{path="/",le="0.005"} 1`,
		`greeter_http_request_duration_seconds_bucket{path="/",le="0.25"} 1`,
		`greeter_http_request_duration_seconds_bucket{path="/",le="0.5"} 2`,
		`greeter_http_request_duration_seconds_bucket{path="/",le="10"} 2`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

func TestObservationAboveLargestBucketLandsInInf(t *testing.T) {
	m := newMetrics()
	m.observe("/work", http.MethodGet, "200", 25)

	out := m.render("test", true)
	if !strings.Contains(out, `greeter_http_request_duration_seconds_bucket{path="/work",le="10"} 0`) {
		t.Errorf("expected the 10s bucket to be empty in:\n%s", out)
	}
	if !strings.Contains(out, `greeter_http_request_duration_seconds_bucket{path="/work",le="+Inf"} 1`) {
		t.Errorf("expected the +Inf bucket to hold the observation in:\n%s", out)
	}
	if !strings.Contains(out, `greeter_http_request_duration_seconds_count{path="/work"} 1`) {
		t.Errorf("expected a count of 1 in:\n%s", out)
	}
}

func TestFormatBucketTrimsTrailingZeros(t *testing.T) {
	cases := map[float64]string{0.005: "0.005", 0.01: "0.01", 0.25: "0.25", 1: "1", 2.5: "2.5", 10: "10"}
	for in, want := range cases {
		if got := formatBucket(in); got != want {
			t.Errorf("formatBucket(%v) = %q, want %q", in, got, want)
		}
	}
}

// The metrics endpoint must not count itself, or a scrape would change the
// series it is reporting.
func TestMetricsEndpointIsNotInstrumented(t *testing.T) {
	s := testServer(t, Config{})
	h := s.Handler()

	for i := 0; i < 3; i++ {
		req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
		h.ServeHTTP(httptest.NewRecorder(), req)
	}

	_, body := get(t, h, "/metrics")
	if strings.Contains(body, `path="/metrics"`) {
		t.Errorf("/metrics counted itself:\n%s", body)
	}
}

func TestHandlerRecordsStatusCodes(t *testing.T) {
	s := testServer(t, Config{})
	h := s.Handler()
	get(t, h, "/boom")
	_, body := get(t, h, "/metrics")
	if !strings.Contains(body, `greeter_http_requests_total{path="/boom",method="GET",status="500"} 1`) {
		t.Errorf("expected /boom recorded as 500 in:\n%s", body)
	}
}
