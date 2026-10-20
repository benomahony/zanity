import static org.junit.jupiter.api.Assertions.assertTrue;

class UndocumentedTest {
    @Test
    void totalWithoutDocs() {
        int a0 = 0;
        int a1 = 1;
        int a2 = 2;
        int a3 = 3;
        int a4 = 4;
        int a5 = 5;
        int a6 = 6;
        int a7 = 7;
        int a8 = 8;
        int a9 = 9;
        int a10 = 10;
        int a11 = 11;
        int a12 = 12;
        int a13 = 13;
        int a14 = 14;
        int a15 = 15;
        int a16 = 16;
        int a17 = 17;
        int a18 = 18;
        int a19 = 19;
        assertTrue(a0 < a19, "expected the steps to grow");
    }

    /** Each step adds one, so the last is the largest. */
    @Test
    void totalWithComment() {
        int a0 = 0;
        int a1 = 1;
        int a2 = 2;
        int a3 = 3;
        int a4 = 4;
        int a5 = 5;
        int a6 = 6;
        int a7 = 7;
        int a8 = 8;
        int a9 = 9;
        int a10 = 10;
        int a11 = 11;
        int a12 = 12;
        int a13 = 13;
        int a14 = 14;
        int a15 = 15;
        int a16 = 16;
        int a17 = 17;
        int a18 = 18;
        int a19 = 19;
        assertTrue(a0 < a19, "expected the steps to grow");
    }
}
