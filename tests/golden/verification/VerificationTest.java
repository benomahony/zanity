class VerificationTest {
    @Test
    void savesTheOrder() {
        service.save(order);
        verify(repository).save(order);
        Mockito.verifyNoMoreInteractions(repository);
        assertEquals(1, service.count());
    }
}
