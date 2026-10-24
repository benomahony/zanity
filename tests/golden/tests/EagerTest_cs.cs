class EagerTest {
    [Fact]
    void many() {
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
    }

    [Fact]
    void enough() {
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
        Assert.Equal(1, 1);
    }
}
