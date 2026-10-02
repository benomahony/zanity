import static org.mockito.Mockito.mock;

class DoublesTest {
    private final Repository repository = mock(Repository.class);

    @Test
    void savesTheOrder() {
        try (var util = Mockito.mockStatic(Clock.class)) {
            service.save(order);
        }
    }
}
