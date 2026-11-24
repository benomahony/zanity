using System;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

class Rules
{
    const string ApiKey = "sk-live-7f3a9c2e";

    int Total(Order order)
    {
        int sum = order.Lines.Count();
        if (order.Lines.Count() > 10) sum += order.Lines.Count();
        return sum;
    }

    string Ship(Order order)
    {
        string city = order.Customer.Address.City;
        string name = order.Customer.Name;
        return city + name;
    }

    int Narrow(bool flag)
    {
        int onlyInside = 3;
        if (flag)
        {
            return onlyInside + 1;
        }
        return 0;
    }

    Regex Pattern() => new Regex("([a-z]+)+$");
    Regex SafePattern() => new Regex("[a-z]+$");

    XmlReader Read(Stream stream) => XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Parse });
    XmlReader ReadSafely(Stream stream) => XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });

    WebRequest Fetch() => WebRequest.Create("https://example.invalid/orders");

    byte[] Derive(string password) => Rfc2898DeriveBytes.Pbkdf2(password, Encoding.UTF8.GetBytes("shared-salt"), 100000, HashAlgorithmName.SHA256, 32);
    byte[] DeriveSalted(string password, byte[] salt) => Rfc2898DeriveBytes.Pbkdf2(password, salt, 100000, HashAlgorithmName.SHA256, 32);
}
