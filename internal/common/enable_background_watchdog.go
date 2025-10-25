package common

import (
	"log"
	"time"

	"github.com/coreos/go-systemd/daemon"
)

// Wrap the go-systemd for dependency injection so we can unit test this code.
type DaemonNotifier interface {
	SdNotify(unsetEnv bool, state string) (bool, error)
	SdWatchdogEnabled(unsetEnv bool) (time.Duration, error)
}

type SystemdDaemon struct{}

func (s *SystemdDaemon) SdNotify(unsetEnv bool, state string) (bool, error) {
	return daemon.SdNotify(unsetEnv, state)
}

func (s *SystemdDaemon) SdWatchdogEnabled(unsetEnv bool) (time.Duration, error) {
	return daemon.SdWatchdogEnabled(unsetEnv)
}

// When running under systemd, send a keep-alive ping to systemd every 15 seconds.
// At 30 seconds without a ping, systemd will restart the process.
func EnableBackgroundWatchdog(dmn DaemonNotifier) error {
	// Tell systemd we're ready
	sent, err := dmn.SdNotify(false, "READY=1")
	if err != nil {
		return err
	}
	if !sent {
		// Not fatal — just log
		log.Println("Not running under systemd or watchdog not enabled")
	}

	watchdogInterval, err := dmn.SdWatchdogEnabled(false)
	if err != nil {
		return err
	}

	if watchdogInterval > 0 {
		ticker := time.NewTicker(watchdogInterval / 2)

		go func() {
			for range ticker.C {
				dmn.SdNotify(false, "WATCHDOG=1")
			}
		}()
	}

	return nil
}
