class CoreJavaTest {
    @Test
    void reachesRealResources() {
        Thread.sleep(1); // parity: sleep-in-test
        while (ready()) { // parity: polling-loop
            Thread.sleep(1); // parity: sleep-in-test
        }
        Math.random(); // parity: nondeterministic-test
        Files.readString(path); // parity: filesystem-in-test
        HttpClient.newHttpClient(); // parity: network-in-test
        Runtime.getRuntime().exec("ls"); // parity: process-in-test
        System.console().readLine(); // parity: stdin-in-test
    }
    void helper() { Thread.sleep(1); Files.readString(path); }
}
