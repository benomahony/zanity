using System.Text;

class Signer
{
    byte[] Sign(string message)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(message);
        return Sign(bytes);
    }

    byte[] Sign(byte[] data) => data;

    void Log(string text) => Log(new Entry(text));

    void Log(Entry entry) => Store(entry);

    int Parse(string text) => Parse(42);

    int Parse(int value) => value;

    void Pad(string text) => Pad((object)text);

    void Pad(object value) => Store(value);

    void Mark(string label)
    {
        var entry = new Entry(label);
        Mark(entry);
    }

    void Mark(Entry entry) => Store(entry);

    int Fact(int n)
    {
        int next = n - 1;
        return n == 0 ? 1 : n * Fact(next);
    }

    int Fact(string n) => Fact(int.Parse(n));

    int Count(int n) => n == 0 ? 0 : Count(n - 1);

    int Count(string n) => Count(n.Length);

    void Store(object value) { }
}

class Entry
{
    public Entry(string text) { }
}
