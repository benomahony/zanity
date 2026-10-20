interface IHandler
{
    int Handle(int a, int b);
}

abstract class Base
{
    public abstract int Run(int a, int b);
    public virtual int Walk(int a, int b) { return a; }
}

class Impl : Base, IHandler
{
    public int Handle(int a, int b)
    {
        var x = a + 1;
        return x * 2;
    }

    int IHandler.Explicit(int a, int b)
    {
        var x = a + 1;
        return x * 2;
    }

    public override int Run(int a, int b)
    {
        var x = a + 1;
        return x * 2;
    }

    void OnClick(object sender, ClickEventArgs e)
    {
        var x = 1;
        Console.WriteLine(x);
    }

    int Own(int a, int b)
    {
        var x = a + 1;
        return x * 2;
    }
}
