using System.Collections.Generic;

class PerElementCall
{
    static void Ship(List<Order> orders)
    {
        foreach (var order in orders)
        {
            order.Ship();
        }
    }
}

class Order
{
    public void Ship() { }
}
