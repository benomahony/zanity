using System;
using System.Diagnostics;

class Messages
{
    // FIXME: this accepts expired credentials.
    int Compare(int a, int b)
    {
        Debug.Assert(a > b, "expected a > b");
        if (a > 10) throw new ArgumentException("invalid input");
        if (b > 10) throw new InvalidOperationException("ERR_TOO_BIG");
        if (a < 0) throw new ArgumentException($"a must not be negative, since it counts retries, got {a}");
        return a - b;
    }
}
