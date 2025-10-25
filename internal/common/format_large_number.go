package common

import "fmt"

// Pretty print large numbers with <num>K|M|B|T
func FormatLargeNumber(n float64) string {
	switch {
	case abs(n) >= 1_000_000_000_000:
		return fmt.Sprintf("%.2fT", n/1_000_000_000_000)
	case abs(n) >= 1_000_000_000:
		return fmt.Sprintf("%.2fB", n/1_000_000_000)
	case abs(n) >= 1_000_000:
		return fmt.Sprintf("%.2fM", n/1_000_000)
	case abs(n) >= 1_000:
		return fmt.Sprintf("%.2fK", n/1_000)
	default:
		return fmt.Sprintf("%.2f", n)
	}
}

func abs(n float64) float64 {
	if n > 0 {
		return n
	}
	return n * -1
}
