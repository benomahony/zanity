package main

func record(message string) {
	log.Print(message)
}

func structured(message string) {
	log.Printf("request message: %s", message)
}

func cleaned(message string) {
	cleanedMessage := strings.ReplaceAll(message, "\n", " ")
	log.Print(cleanedMessage)
}
