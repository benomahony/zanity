package main

type Node struct{ ID int }

type Scene struct {
	Nodes  []*Node
	ByName map[string]*Node
	Fixed  [4]*Node
	Flat   []Node
	Lookup map[string]Node
}
