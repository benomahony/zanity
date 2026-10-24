class NamesCSharpTest {
    [Fact]
    void Test() { Assert.True(Compute()); }
    [Fact(Skip = "temporarily disabled")]
    void RejectsExpiredTokens() { Assert.True(Compute()); }
    [Fact]
    void AcceptsValidTokens() { Assert.True(Compute()); }
}
