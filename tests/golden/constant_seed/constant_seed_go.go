package main

import "math/rand"

func configureRandomness() {
	rand.Seed(7)
}

func configureFromRuntime(seed int64) {
	rand.Seed(seed)
}
