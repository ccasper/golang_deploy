package common

import (
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

var (
	// These values don't change once in steady state.
	service       string
	version       string
	startTime     time.Time
	loadedQps     float64 // ideal full load QPS the service can handle (recommend setting to <80% of max for scaling purposes).
	qpsThrottler  *QpsThrottler
	windowSeconds float64 = 0.5 // Seconds for the EMA to decay, similiar to the the moving window but for exponential moving averages.
)

var (
	// These values are useful for a QPS log statement that happens ever 100 requests.
	acceptedCounter   int64     = 0
	acceptedStartTime time.Time = time.Now()
)

func StartHealthServer(name string, newVersion string, port string) error {
	service = name
	startTime = time.Now()
	version = newVersion
	log.Printf("Healthz port for %s starting on http:/%s/healthz", name, port)

	if !strings.Contains(port, ":") {
		return fmt.Errorf("invalid port: %s, needs a ':<port>'", port)
	}

	// Create a new ServeMux for this server
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler)

	// Run the server in a goroutine so it doesn't block main
	go func() {
		fmt.Printf("Starting healthz server on %s\n", port)
		if err := http.ListenAndServe(port, mux); err != nil {
			fmt.Printf("Failed to start server: %v\n", err)
		}
	}()

	return nil
}

// Use this to force an upper limit on the service load.
func BusynessThrottleMiddleware(busyQps, throttleQps float64) func(http.Handler) http.Handler {
	qpsThrottler = NewQpsThrottler(throttleQps, time.Duration(windowSeconds*float64(time.Second)))
	loadedQps = busyQps

	return func(next http.Handler) http.Handler {

		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			accept := qpsThrottler.ShouldAccept()

			if !accept {
				// reject with 503 Service Unavailable
				http.Error(w, "Server too busy, try again later", http.StatusServiceUnavailable)
				return
			}

			// Useful log statement on actual accepted QPS every 100 requests.
			acceptedCounter++
			if time.Since(acceptedStartTime).Seconds() > 1 {
				log.Printf("ACCEPTED QPS: %.5f (Full QPS: %.5f)", float64(acceptedCounter)/time.Since(acceptedStartTime).Seconds(), qpsThrottler.CurrentQPS())
				acceptedCounter = 0
				acceptedStartTime = time.Now()
			}

			next.ServeHTTP(w, r)
		})
	}
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	busyness := GetBusyness()

	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprintf(w, "busyness=%.6f\naccepted=%d\nservice=%s\nversion=%s\nuptime=%.1f\n", busyness, acceptedCounter, service, version, time.Since(startTime).Seconds())
}

func GetBusyness() float64 {
	return qpsThrottler.CurrentQPS() / loadedQps
}
