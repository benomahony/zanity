package main

import "fmt"

func unsafe(format string, value any) string {
	return fmt.Sprintf(format, value)
}

func safe(format string, value any) string {
	return fmt.Sprintf("%s: %v", format, value)
}
