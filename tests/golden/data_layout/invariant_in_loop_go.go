package main

import "strings"

func count(lines []string, word string) int {
	found := 0
	for _, line := range lines {
		if strings.Contains(line, strings.ToLower(word)) {
			found++
		}
	}
	return found
}

func shrinking(lines []string, word string) int {
	found := 0
	for _, line := range lines {
		if strings.Contains(line, strings.ToLower(word)) {
			found++
		}
		word = word[1:]
	}
	return found
}
