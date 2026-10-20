using Moq;
using Xunit;

public class BranchingTests
{
    [Fact]
    public void PricesEachProduct()
    {
        var prices = new Mock<IPrices>();
        prices.Setup(p => p.For(It.IsAny<string>())).Returns((string sku) => sku == "apple" ? 1 : 2);
        prices.Setup(p => p.Default()).Returns(() => 3);
        prices.Setup(p => p.For("pear")).Returns(4);
        Assert.Equal(1, new Basket(prices.Object).Total("apple"));
    }
}
