package sample
func TestReachesRealResources(t *testing.T) {
    time.Sleep(1) // parity: sleep-in-test
    for ready() { // parity: polling-loop
        time.Sleep(1) // parity: sleep-in-test
    }
    rand.Int() // parity: nondeterministic-test
    os.ReadFile("config") // parity: filesystem-in-test
    http.Get("https://example.com") // parity: network-in-test
    exec.Command("ls") // parity: process-in-test
    fmt.Scanln() // parity: stdin-in-test
}
func helper() { time.Sleep(1); os.ReadFile("config") }
