class IsolationTest {
    @Test
    void reachesOut() throws Exception {
        System.setProperty("mode", "test");
        Files.readString(Path.of("config.json"));
        Files.writeString(tempDir.resolve("out.txt"), "ok");
        Files.createTempFile("x", ".txt");
        HttpClient.newHttpClient();
        DriverManager.getConnection("jdbc:postgresql://db/app");
        DriverManager.getConnection("jdbc:h2:mem:test");
        Runtime.getRuntime().exec("ls");
    }

    void helper() throws Exception {
        System.setProperty("mode", "prod");
        Runtime.getRuntime().exec("ls");
    }
}
