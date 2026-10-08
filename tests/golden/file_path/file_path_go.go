package main

import "os"

func read(path string) {
	_, _ = os.ReadFile(path)
}

func readFixed(path string) {
	_, _ = os.ReadFile("data/config.json")
}
