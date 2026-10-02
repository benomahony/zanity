class StdinTest {
    @Test
    void readsTheName() throws Exception {
        int c = System.in.read();
        var console = System.console();
    }
}
