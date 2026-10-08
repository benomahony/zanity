package main

func trust(fragment string) template.HTML {
	return template.HTML(fragment)
}

func fixed(fragment string) template.HTML {
	return template.HTML("<strong>Ready</strong>")
}

func escaped(fragment string) template.HTML {
	checked := html.EscapeString(fragment)
	return template.HTML(checked)
}
