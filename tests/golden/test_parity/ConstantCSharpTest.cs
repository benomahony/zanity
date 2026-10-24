class ConstantTest {
    [Fact]
    void RejectsConstantChecks() {
        Assert.True(true); // parity: constant
        Assert.Equal(2, 1 + 1); // parity: constant
        Assert.AreEqual("abc", "abc"); // parity: constant
        int actual = Calculate();
        Assert.Equal(2, actual);
        Assert.Equal(actual, 2);
        Assert.Equal(2, 2, customComparer);
        Assert.True(Calculate() == 2);
        if (Unexpected()) { Assert.False(true); }
        Assert.Equal($"{actual}", "2");
    }
    void Helper() { Assert.Equal(2, 2); }
}
