package common

import (
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

var (
	service   string
	busyness  float64
	version   string
	startTime time.Time
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

func SetBusyness(newBusyness float64) {
	busyness = newBusyness
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	fmt.Fprintf(w, "busyness=%.1f\nservice=%s\nversion=%s\nuptime=%.1f\n", busyness, service, version, time.Since(startTime).Seconds())
}
