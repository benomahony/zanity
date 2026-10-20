using System;
using System.Diagnostics;
using System.Net.Http;
using System.Runtime.Serialization.Formatters.Binary;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

class Hazards
{
    bool Precedence(bool a, bool b, int flags, int mask)
    {
        bool first = !a == b;
        bool second = (flags & mask == 0);
        return first && second;
    }

    void Throws(int code)
    {
        if (code < 0) throw new Exception("code must not be negative");
        if (code > 9) throw new ArgumentOutOfRangeException(nameof(code), "code must be a digit");
    }

    string Switches(int code)
    {
        switch (code)
        {
            case 1: return "one";
            case 2: return "two";
        }
        switch (code)
        {
            case 1: return "one";
            default: return "other";
        }
    }

    string Arms(int code) => code switch { 1 => "one", _ => "other" };

    string Partial(int code) => code switch { 1 => "one", 2 => "two" };

    void Certificates(HttpClientHandler handler, HttpClientHandler other)
    {
        handler.ServerCertificateCustomValidationCallback = (message, cert, chain, errors) => true;
        other.ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
    }

    void Crypto(byte[] data)
    {
        var md5 = MD5.Create();
        var formatter = new BinaryFormatter();
        var weak = new Random();
        var seeded = new Random(42);
        Environment.Exit(1);
    }

    void Query(Db db, string name, string password, ILogger logger)
    {
        db.ExecuteSqlRaw("SELECT * FROM users WHERE name = '" + name + "'");
        db.ExecuteSqlRaw($"DELETE FROM users WHERE name = '{name}'");
        Console.WriteLine(password);
    }

    TimeSpan Timing()
    {
        var start = DateTime.Now;
        Work();
        return DateTime.Now - start;
    }

    async Task SaveAsync() => await Task.Yield();

    async Task Unawaited()
    {
        SaveAsync();
        await SaveAsync();
    }

    void Jumps(int code)
    {
        switch (code)
        {
            case 1: goto case 2;
            case 2: goto default;
            default: break;
        }
        goto done;
        done: Work();
    }

    void Locks(object gate)
    {
        lock (gate) { }
        lock (gate) { Work(); }
    }

    void Catches()
    {
        try { Work(); }
        catch (NullReferenceException e) { Log(e); }
        try { Work(); }
        catch (Exception e) when (e is TimeoutException) { Log(e); }
        try { Work(); }
        catch (Exception e) { Log(e); }
        try { Work(); }
        catch { Log(null); }
    }

    void Threads() => new Thread(Work).Start();

    bool Floats(double ratio, decimal price) => ratio == 0.5 || price == 0.5m || ratio == 0.0;

    int Unreachable(int code)
    {
        return code;
        Work();
    }

    int Labelled(int code)
    {
        if (code > 0) goto positive;
        return 0;
        positive: return 1;
    }

    int Sum(params int[] values) => values.Length;

    int Divide(int n) => n / 0;

    void Conditions(bool done)
    {
        if (done = true) Work();
        if (true) Work();
        if (done) { }
        Debugger.Break();
    }
}
