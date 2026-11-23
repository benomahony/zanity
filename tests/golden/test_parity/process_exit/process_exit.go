package parity

import (
	"log"
	"os"
)

func stop(code int) {
	os.Exit(code)
}

func fail(err error) {
	log.Fatal(err)
}

func main() {
	os.Exit(0)
}
