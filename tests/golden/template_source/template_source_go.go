package main

func compile(source string) {
	_, _ = template.New("page").Parse(source)
}

func compileFixed(source string) {
	_, _ = template.New("page").Parse("Hello {{.Name}}")
}

func compileSelected() {
	source := "Hello {{.Name}}"
	_, _ = template.New("page").Parse(source)
}
