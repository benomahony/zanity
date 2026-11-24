interface IClock
{
    int Now();
}

class SystemClock : IClock
{
    public int Now() => 0;
}

interface IStore
{
    void Save(int value);
}

class MemoryStore : IStore
{
    public void Save(int value) {}
}

class DiskStore : IStore
{
    public void Save(int value) {}
}

public class Api
{
    public int Run() => Helper();

    private int Helper() => 1;

    private int Forgotten() => 2;
}
