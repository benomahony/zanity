using System.Diagnostics;

public static class Charges
{
    private static readonly ActivitySource Source = new ActivitySource("Charges");

    public static string Charge()
    {
        using var activity = Source.StartActivity("charge");
        return "charged";
    }
}
