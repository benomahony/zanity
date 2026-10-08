package main

func read(reader io.Reader) {
	_, _ = ioutil.ReadAll(reader)
}

func readSupported(reader io.Reader) {
	_, _ = io.ReadAll(reader)
}

func unrelated(ioutil Reader, reader io.Reader) {
	_, _ = ioutil.ReadEverything(reader)
}
