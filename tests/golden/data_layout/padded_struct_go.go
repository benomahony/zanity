package main

type Padded struct {
	Ready bool
	Count int64
	Small bool
}

type Ordered struct {
	Count int64
	Ready bool
	Small bool
}

type Unknown struct {
	Ready bool
	Inner Ordered
	Count int64
}
