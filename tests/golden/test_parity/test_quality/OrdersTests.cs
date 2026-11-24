using System;
using System.Data.SqlClient;
using System.IO;
using Xunit;

public class OrdersTests
{
    [Fact]
    public void SavesToDatabase()
    {
        using var connection = new SqlConnection("Server=localhost;Database=orders");
        Environment.SetEnvironmentVariable("MODE", "test");
        var path = Path.GetTempFileName();
        Assert.True(new Orders(connection, path).Save(1));
    }

    [Fact]
    public void SavesInMemory()
    {
        Assert.True(new Orders().Save(1));
    }
}
