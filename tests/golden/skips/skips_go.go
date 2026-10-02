package skips

import "testing"

func TestOff(t *testing.T) {
	t.Skip("not ready")
}

func TestShort(t *testing.T) {
	if testing.Short() {
		t.Skip("slow")
	}
}
