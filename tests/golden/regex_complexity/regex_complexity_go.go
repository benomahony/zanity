package main

import "regexp"

var dangerous = regexp.MustCompile("([a-z]+)+$")
var safe = regexp.MustCompile("(?:ab+)+$")
