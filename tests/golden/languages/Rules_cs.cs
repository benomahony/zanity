using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using Moq;
using Xunit;

class Rules
{
    int Countdown(int n)
    {
        Debug.Assert(n >= 0, "n must not be negative");
        Debug.Assert(n < 100, "n must be small");
        return Countdown(n - 1);
    }

    void Emit(string message) => Emit(message, DateTimeKind.Utc);

    void Emit(string message, DateTimeKind kind) => Console.WriteLine(message, kind);

    void Spin()
    {
        while (true) { }
        for (;;) { }
    }

    void Bounded(List<int> items)
    {
        foreach (var item in items)
        {
            Console.WriteLine(item);
        }
        for (int i = 0; i < items.Count; i++) { }
    }

    int Many(int a, int b, int c, int d, int e)
    {
        return a + b + c + d + e;
    }

    int Forward(int x) => Target(x);

    void Ignore()
    {
        try
        {
            Work();
        }
        catch (InvalidOperationException e) { }
    }

    void Checks(List<int> items)
    {
        int ready = 5;
        Debug.Assert(ready == 5);
        Debug.Assert(items.Remove(0), "removes while checking");
    }

    void Guarded(string name, int count)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (count < 0) throw new ArgumentOutOfRangeException(nameof(count), "count must not be negative");
    }

    [Fact]
    public void Waits()
    {
        Thread.Sleep(1000);
        var id = Guid.NewGuid();
        var fake = new Mock<IDisposable>();
    }
}
