using System.Diagnostics.CodeAnalysis;

#pragma warning disable CS8602
#pragma warning restore CS8602
#nullable disable
#nullable enable

[assembly: SuppressMessage("Style", "IDE0001")]

class SuppressionsCs
{
    [SuppressMessage("Design", "CA1031")]
    void Swallow() { }

    [System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage]
    void Uncovered() { }

    // ReSharper disable once UnusedMember.Local
    void Unused() { }

    [Obsolete]
    void Honest() { }
}
