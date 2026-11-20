using System.Collections.Generic;

class AppendWithoutReserve
{
    static List<int> Doubled(List<int> values)
    {
        var out_ = new List<int>();
        foreach (var value in values)
        {
            out_.Add(value * 2);
        }
        return out_;
    }

    static List<int> SizedDoubled(List<int> values)
    {
        var out_ = new List<int>(values.Count);
        foreach (var value in values)
        {
            out_.Add(value * 2);
        }
        return out_;
    }
}
