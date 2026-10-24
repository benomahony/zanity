class ConstantTest {
    @Test
    void rejectsConstantChecks() {
        assertTrue(true); // parity: constant
        assertEquals(2, 1 + 1); // parity: constant
        assertEquals("abc", "abc"); // parity: constant
        int actual = calculate();
        assertEquals(2, actual);
        assertEquals(actual, 2);
        assertEquals("JUnit 4 message", 2, actual);
        assertTrue("JUnit 4 message", actual == 2);
        assertEquals(2, actual, "JUnit 5 message");
        assertTrue(calculate() == 2);
        if (unexpected()) { assertFalse(true); }
    }
    void helper() { assertEquals(2, 2); }
}
