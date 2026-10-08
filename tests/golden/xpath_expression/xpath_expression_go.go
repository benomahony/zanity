package main

func selectNode(node *xmlquery.Node, expression string) {
	_ = xmlquery.Find(node, expression)
}

func selectFixed(node *xmlquery.Node, expression string) {
	_ = xmlquery.Find(node, "/users/user")
}
