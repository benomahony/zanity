using Moq;
using Xunit;

public class VerificationTests
{
    [Fact]
    public void SavesTheOrder()
    {
        var store = new Mock<IStore>();
        new Checkout(store.Object).Complete(order);
        store.Verify(s => s.Save(order), Times.Once());
        store.VerifyNoOtherCalls();
    }

    [Fact]
    public void AcceptsItsOwnSignature()
    {
        var key = Key.Generate();
        Assert.True(key.Verify(data, key.Sign(data)));
    }
}
