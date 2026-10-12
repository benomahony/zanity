class OpaqueChecks {
    @Test
    void totalIncludesTax() {
        assertTrue(total().equals(110));
    }

    @Test
    void totalIsNotZero() {
        assertFalse(total().equals(0));
    }

    @Test
    void totalIsSmall() {
        assertTrue(total() < 1000);
    }

    @Test
    void totalReadsPlainly() {
        assertEquals(110, total());
    }
}
