package common

import (
	"testing"
	"time"
)

// MockDaemon implements DaemonNotifier for testing.
type MockDaemon struct {
	NotifyCalls         []string
	NotifyReturnValue   bool
	NotifyReturnError   error
	WatchdogReturnValue time.Duration
	WatchdogReturnError error
}

func (m *MockDaemon) SdNotify(_ bool, state string) (bool, error) {
	m.NotifyCalls = append(m.NotifyCalls, state)
	return m.NotifyReturnValue, m.NotifyReturnError
}

func (m *MockDaemon) SdWatchdogEnabled(_ bool) (time.Duration, error) {
	return m.WatchdogReturnValue, m.WatchdogReturnError
}

func TestEnableBackgroundWatchdog(t *testing.T) {
	mock := &MockDaemon{
		NotifyReturnValue:   true,
		WatchdogReturnValue: 100 * time.Millisecond,
	}

	EnableBackgroundWatchdog(mock)

	// Check that "READY=1" notification was sent
	foundReady := false
	for _, call := range mock.NotifyCalls {
		if call == "READY=1" {
			foundReady = true
			break
		}
	}
	if !foundReady {
		t.Error("Expected READY=1 notification")
	}

	// Wait enough time for multiple watchdog pings (WATCHDOG=1) to be sent
	time.Sleep(350 * time.Millisecond)

	// Count how many WATCHDOG=1 notifications were sent
	countWatchdog := 0
	for _, call := range mock.NotifyCalls {
		if call == "WATCHDOG=1" {
			countWatchdog++
		}
	}

	if countWatchdog < 2 {
		t.Errorf("Expected at least 2 WATCHDOG=1 notifications, got %d", countWatchdog)
	}
}

func TestEnableBackgroundWatchdog_NotRunningUnderSystemd(t *testing.T) {
	mock := &MockDaemon{
		NotifyReturnValue:   false, // simulate NOT running under systemd or notification not sent
		WatchdogReturnValue: 0,     // watchdog disabled
	}

	EnableBackgroundWatchdog(mock)

	// Should send READY=1 but return false, so check that NotifyCalls include it
	foundReady := false
	for _, call := range mock.NotifyCalls {
		if call == "READY=1" {
			foundReady = true
			break
		}
	}
	if !foundReady {
		t.Error("Expected READY=1 notification even if not running under systemd")
	}

	// Since watchdog interval is 0, no WATCHDOG=1 notifications expected
	for _, call := range mock.NotifyCalls {
		if call == "WATCHDOG=1" {
			t.Error("Did not expect WATCHDOG=1 notification when watchdog disabled")
		}
	}
}

type testError struct{}

func (e *testError) Error() string {
	return "test error"
}
func TestEnableBackgroundWatchdog_ErrorOnNotify(t *testing.T) {
	// Optional error variable for test
	var errTest = &testError{}

	mock := &MockDaemon{
		NotifyReturnValue: false,
		NotifyReturnError: errTest,
	}

	err := EnableBackgroundWatchdog(mock)
	if err == nil {
		t.Fatal("expected error but got nil")
	}
	if err.Error() != "test error" {
		t.Fatalf("unexpected error message: %v", err)
	}
}
