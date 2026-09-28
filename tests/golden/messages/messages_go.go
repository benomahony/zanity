package messages

import (
	"errors"
	"fmt"
)

func check(path string, size int) error {
	if size < 0 {
		return errors.New("invalid input")
	}
	if size > 10 {
		return errors.New("E_TOO_BIG")
	}
	if path == "" {
		return fmt.Errorf("path is empty; pass the file to read as the first argument")
	}
	return fmt.Errorf("cannot read %s: %d bytes is over the limit", path, size)
}
