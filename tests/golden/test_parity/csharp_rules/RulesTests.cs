using System;
using Xunit;

public class RulesTests
{
    [Fact]
    public void RejectsNegativeWithdrawals()
    {
        Assert.Throws<Exception>(() => new Account().Withdraw(-1));
    }

    [Fact]
    public void RejectsNegativeWithdrawalsSpecifically()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new Account().Withdraw(-1));
    }

    [Fact]
    public void TotalsTheOrder()
    {
        Assert.True(new Order().Total().Equals(110));
        Assert.Equal(110, new Order().Total());
    }
}
