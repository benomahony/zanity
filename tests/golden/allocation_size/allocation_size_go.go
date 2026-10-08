package main

func reserve(size int) []byte {
	return make([]byte, size)
}

func fixed(size int) []byte {
	return make([]byte, 4096)
}

func bounded(size int) []byte {
	boundedSize := min(size, 4096)
	return make([]byte, boundedSize)
}
