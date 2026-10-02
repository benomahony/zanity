class ExpectedErrorsTest {
    @Test
    void rejectsNegativeAmounts() {
        assertThrows(Exception.class, () -> account.withdraw(-1));
    }

    @Test
    void rejectsOverdraft() {
        assertThrows(InsufficientFundsException.class, () -> account.withdraw(1_000_000));
    }
}
