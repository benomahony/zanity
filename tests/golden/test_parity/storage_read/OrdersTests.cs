using System.Data;
using Xunit;

public class OrdersTests
{
    IDbCommand command;
    Orders orders;

    [Fact]
    public void SavesOrder()
    {
        orders.Save(1);
        command.CommandText = "SELECT id FROM orders";
        Assert.Equal(1, command.ExecuteScalar());
    }

    [Fact]
    public void FindsOrder()
    {
        orders.Save(1);
        Assert.Equal(1, orders.Find(1));
    }
}
