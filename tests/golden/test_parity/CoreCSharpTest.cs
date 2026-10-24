class CoreCSharpTest {
    [Fact]
    void ReachesRealResources() {
        Thread.Sleep(1); // parity: sleep-in-test
        while (Ready()) { // parity: polling-loop
            Thread.Sleep(1); // parity: sleep-in-test
        }
        Guid.NewGuid(); // parity: nondeterministic-test
        File.ReadAllText("config"); // parity: filesystem-in-test
        WebRequest.Create("https://example.com"); // parity: network-in-test
        Process.Start("ls"); // parity: process-in-test
        Console.ReadLine(); // parity: stdin-in-test
    }
    void Helper() { Thread.Sleep(1); File.ReadAllText("config"); }
}
