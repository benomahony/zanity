package stdin

import (
	"fmt"
	"testing"
)

func TestReadsTheName(t *testing.T) {
	var name string
	fmt.Scanln(&name)
}
