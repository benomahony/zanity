using System.Net;

class NetworkUrls
{
    void Load()
    {
        WebRequest.Create("http://user:password@example.invalid/data");
        WebRequest.Create("https://example.invalid/login?api_token=visible");
        WebRequest.Create("https://example.invalid/data");
    }
}
