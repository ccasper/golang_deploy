package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Get two free ports from the OS to run the test.
//
// Ideally we'd could reuse these ports per test, but the
// http servers are not properly shut down and adding this logic to main.go
// would make this basic skeleton too complex for beginners.
func GetTwoFreePorts() (int64, int64) {
	// Ask the OS for a free TCP port
	ln1, err := net.Listen("tcp", ":0")
	if err != nil {
		log.Fatalf("failed to get free port: %v", err)
	}
	port1 := ln1.Addr().(*net.TCPAddr).Port

	ln2, err := net.Listen("tcp", ":0")
	if err != nil {
		log.Fatalf("failed to get free port: %v", err)
	}
	port2 := ln2.Addr().(*net.TCPAddr).Port

	// free them so the server can bind
	ln1.Close()
	ln2.Close()
	return int64(port1), int64(port2)
}

func TestHomeHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()

	homeHandler(w, req)

	resp := w.Result()
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200 OK, got %d", resp.StatusCode)
	}

	body := w.Body.String()

	// Check that the page contains the main heading
	if !strings.Contains(body, "🕒 Timezone Clock") {
		t.Errorf("expected body to contain '🕒 Timezone Clock'")
	}

	// Optional: check that the dropdown contains some known timezone
	if !strings.Contains(body, "America/New_York") {
		t.Errorf("expected body to contain 'America/New_York'")
	}
}

// mockDaemon implements DaemonNotifier
type mockDaemon struct {
	notified bool
}

func (m *mockDaemon) SdNotify(unsetEnv bool, state string) (bool, error) {
	m.notified = true
	return true, nil
}

func (m *mockDaemon) SdWatchdogEnabled(unsetEnv bool) (time.Duration, error) {
	// Return small non-zero duration to simulate watchdog enabled
	return 10 * time.Millisecond, nil
}

// TestRunMainServesOnPort verifies that runMain starts an HTTP server
// listening on the given port and that the root ("/") endpoint responds with 200 OK.
func TestRunMainServesOnPort(t *testing.T) {
	port, healthPort := GetTwoFreePorts()
	d := &mockDaemon{}

	// Start the server in a goroutine so the test can continue
	go func() {
		defer func() {
			// Recover from log.Fatal in runMain (which panics in tests)
			if r := recover(); r != nil {
				t.Logf("runMain panicked: %v", r)
			}
		}()
		runMain(d, "", port, healthPort)
	}()

	url := fmt.Sprintf("http://localhost:%d/", port)

	// Retry up to 30 seconds for the server to come up
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			defer resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				t.Logf("server responded with 200 OK on %s", url)
				return // success
			}
		}
		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("server on %s did not respond with 200 OK within 30s", url)
}

func TestRunMainWatchdogCalled(t *testing.T) {
	port, healthPort := GetTwoFreePorts()
	daemon := &mockDaemon{}

	// Run runMain in a goroutine to avoid blocking on ListenAndServe
	done := make(chan struct{})
	go func() {
		defer func() { close(done) }()
		defer func() {
			if r := recover(); r != nil {
				// recover from log.Fatal in ListenAndServe
			}
		}()
		runMain(daemon, "", port, healthPort)
	}()

	// Retry for up to 30 seconds until daemon.notified is true
	timeout := time.After(30 * time.Second)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()

	for {
		select {
		case <-timeout:
			t.Fatal("timed out waiting for SdNotify to be called to update watchdog")
		case <-tick.C:
			if daemon.notified {
				// Success — watchdog was called
				return
			}
		}
	}
}

func TestRunMainHealthServer(t *testing.T) {
	port, healthPort := GetTwoFreePorts()
	daemon := &mockDaemon{}

	// Run runMain in a goroutine
	go func() {
		defer func() {
			if r := recover(); r != nil {
				// recover from log.Fatal in ListenAndServe
				log.Printf("runMain panicked: %+v", r)
			}
		}()
		// We use a different port set to avoid test conflicts since we
		// don't shut down the http server properly and doing so makes
		// the skeleton code too complex for beginners.
		runMain(daemon, "", port, healthPort)
	}()

	// 2️⃣ Verify health server responds on the healthzport , retry up to 30 seconds
	var resp *http.Response
	var err error
	success := false
	timeout := time.After(30 * time.Second)
	tick := time.Tick(100 * time.Millisecond)

	for !success {
		select {
		case <-timeout:
			t.Fatal("health server did not respond within 30 seconds")
		case <-tick:
			resp, err = http.Get(fmt.Sprintf("http://localhost:%d/healthz", healthPort))
			if err == nil && resp.StatusCode == http.StatusOK {
				success = true
			}
		}
	}

	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	t.Logf("health server responded successfully: %s", string(body))
}
