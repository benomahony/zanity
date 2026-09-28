package catalogue

import "runtime"

const apiToken = "tok-123"
const tokenEnv = "API_TOKEN"

func flagged(x float64) float64 {
	if x > 0 {
	}
	if true {
		x = 1
	}
	if x == 1.5 {
		x = 2
	}
	if x > 3 {
		x = 4
	} else {
	}
	password := "hunter2"
	_ = password
	runtime.Breakpoint()
	return x
	x = 5
}

func quiet(x float64) float64 {
	if x > 0 {
		// nothing to do until the cache is warm
	}
	if x == 0.0 {
		x = 1
	}
	if x > 1 {
		goto done
	}
	return x
done:
	return 0
}
