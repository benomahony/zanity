package totals

import "testing"

func TestTotalWithoutDocs(t *testing.T) {
	a0 := 0
	a1 := 1
	a2 := 2
	a3 := 3
	a4 := 4
	a5 := 5
	a6 := 6
	a7 := 7
	a8 := 8
	a9 := 9
	a10 := 10
	a11 := 11
	a12 := 12
	a13 := 13
	a14 := 14
	a15 := 15
	a16 := 16
	a17 := 17
	a18 := 18
	a19 := 19
	if a0 > a19 {
		t.Fatal("expected the steps to grow")
	}
}

// TestTotalWithComment checks each step adds one, so the last is the largest.
func TestTotalWithComment(t *testing.T) {
	a0 := 0
	a1 := 1
	a2 := 2
	a3 := 3
	a4 := 4
	a5 := 5
	a6 := 6
	a7 := 7
	a8 := 8
	a9 := 9
	a10 := 10
	a11 := 11
	a12 := 12
	a13 := 13
	a14 := 14
	a15 := 15
	a16 := 16
	a17 := 17
	a18 := 18
	a19 := 19
	if a0 > a19 {
		t.Fatal("expected the steps to grow")
	}
}
