using System.Diagnostics;
using Microsoft.AspNetCore.Mvc;

public class OrdersController : ControllerBase
{
    private static readonly ActivitySource Source = new ActivitySource("Orders");

    [HttpGet("orders/{id}")]
    public string Order(string id)
    {
        return id;
    }

    [HttpPost("orders")]
    public string Create(string body)
    {
        using var activity = Source.StartActivity("create");
        return body;
    }

    public string Total(string id)
    {
        return id;
    }
}
