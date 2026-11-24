using System;
using System.IO;
using System.Net;
using System.Xml;
using HandlebarsDotNet;
using Microsoft.AspNetCore.Html;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

class Sinks : Controller
{
    ILogger logger;

    string Read(string path) => File.ReadAllText(path);
    string ReadFixed() => File.ReadAllText("/etc/orders.conf");

    void Note(string message) => logger.LogInformation(message);
    void NoteFixed(string id) => logger.LogInformation("order {Id} placed", id);

    byte[] Buffer(int size) => GC.AllocateUninitializedArray<byte>(size);
    byte[] BufferFixed() => GC.AllocateUninitializedArray<byte>(4096);

    HtmlString Raw(string markup) => new HtmlString(markup);
    HtmlString RawFixed() => new HtmlString("<b>orders</b>");

    IActionResult Back(string target) => Redirect(target);
    IActionResult Home() => Redirect("/");

    WebRequest Fetch(string url) => WebRequest.Create(url);
    WebRequest FetchFixed() => WebRequest.Create("https://example.invalid/orders");

    object Render(string source) => Handlebars.Compile(source);
    object RenderFixed() => Handlebars.Compile("Hello {{name}}");

    XmlNodeList Select(XmlDocument document, string query) => document.SelectNodes(query);
    XmlNodeList SelectFixed(XmlDocument document) => document.SelectNodes("/orders/order");

    string Label(string format, int id) => String.Format(format, id);
    string LabelFixed(int id) => String.Format("order {0}", id);
}
