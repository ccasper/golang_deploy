package common

// Uses a circular buffer to track QPS over a window.
//
// If the QPS is larger than QpsLimit, ShouldAccept() randomly selects calls
// to suggest rejecting to keep the QPS very close to QpsLimit.
//
// A simple way to test this is the following:
// In one terminal run: $ while [ 1 == 1 ]; do curl http://localhost:8084/ ; done
// In another terminal run: go run ./cmd/clock
// Check the http://localhost:8085/healthz for busyness, accepted, uptime.

import (
	"log"
	"math/rand"
	"sync"
	"time"
)

type QpsThrottler struct {
	QpsLimit float64
	window   time.Duration

	// Circular buffer: one bucket per millisecond in the window
	buckets    []int
	bucketSize time.Duration // Always 1ms
	startMs    int64         // Timestamp of buckets[0]
	sum        int           // Running sum of all buckets for performance optimization.
	mu         sync.Mutex
}

func NewQpsThrottler(QpsLimit float64, window time.Duration) *QpsThrottler {
	numBuckets := int(window.Milliseconds())
	return &QpsThrottler{
		QpsLimit:   QpsLimit,
		window:     window,
		buckets:    make([]int, numBuckets),
		bucketSize: time.Millisecond,
		startMs:    time.Now().UnixMilli(),
	}
}

func (t *QpsThrottler) ShouldAccept() bool {
	t.mu.Lock()
	defer t.mu.Unlock()

	now := time.Now()
	nowMs := now.UnixMilli()

	// Clear any buckets that have aged out
	t.clearOldBuckets(nowMs)

	// Add this request to current bucket first
	idx := t.getIndex(nowMs)
	t.buckets[idx]++
	t.sum++

	// Now calculate QPS including this request
	currentQPS := float64(t.sum) / t.window.Seconds()

	// Not needed, but improves common case latency.
	if currentQPS < t.QpsLimit {
		return true
	}

	// Proportional throttling when at/over capacity
	acceptProb := t.QpsLimit / currentQPS
	return rand.Float64() < acceptProb
}

func (t *QpsThrottler) clearOldBuckets(nowMs int64) {
	windowMs := t.window.Milliseconds()
	oldestValidMs := nowMs - windowMs + 1

	// If time jumped forward more than our window, clear everything
	if t.startMs < oldestValidMs-int64(len(t.buckets)) {
		for i := range t.buckets {
			t.buckets[i] = 0
		}
		t.sum = 0
		t.startMs = oldestValidMs
		return
	}

	// Clear only buckets that are now outside the window
	for t.startMs < oldestValidMs {
		idx := t.getIndex(t.startMs)
		t.sum -= t.buckets[idx]
		t.buckets[idx] = 0
		t.startMs++
	}
}

// Get the index of the bucket for the given timestamp from the circular buffer.
func (t *QpsThrottler) getIndex(timestampMs int64) int {
	return int(timestampMs % int64(len(t.buckets)))
}

// Optional: get current QPS for monitoring
func (t *QpsThrottler) CurrentQPS() float64 {
	t.mu.Lock()
	defer t.mu.Unlock()

	nowMs := time.Now().UnixMilli()

	log.Printf("SUM: %d bucket length:%d index:%d", t.sum, len(t.buckets), t.getIndex(nowMs))

	t.clearOldBuckets(nowMs)

	return float64(t.sum) / t.window.Seconds()
}
