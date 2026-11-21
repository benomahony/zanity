using System.Collections.Generic;
using System.Linq;

class AllocationInLoop
{
    static int Total(List<List<int>> rows)
    {
        var sum = 0;
        foreach (var row in rows.ToList())
        {
            var copy = row.ToArray();
            sum += copy.Length;
        }
        return sum;
    }
}
