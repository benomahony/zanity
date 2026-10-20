package suppressions

import "os"

func Read() []byte {
	data, _ := os.ReadFile("x") //nolint:errcheck
	return data
}

//lint:ignore U1000 kept for later
func unused() {}

func Run() {
	// The nolinter package is not a marker.
	_ = os.Remove("x") // #nosec G104
}
