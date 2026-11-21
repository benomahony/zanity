using System.Collections.Generic;

class InvariantInLoop
{
    static int Count(List<string> lines, string word)
    {
        var found = 0;
        foreach (var line in lines)
        {
            if (line.Contains(word.ToLower()))
            {
                found++;
            }
        }
        return found;
    }

    static int Each(List<string> lines)
    {
        var found = 0;
        foreach (var line in lines)
        {
            found += line.Trim().Length;
        }
        return found;
    }
}
