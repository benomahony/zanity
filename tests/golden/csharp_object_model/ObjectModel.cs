using System;
using System.Runtime.InteropServices;

class Native
{
    [DllImport("libc")]
    static extern int getpid();

    public static int Count;
    static public string Name;
    public static readonly int Limit = 3;
    public const int Max = 9;
    private static int hidden;

    public static readonly int[] Codes = { 1, 2 };
    static readonly public string[] Names = { "a" };
    private static readonly int[] Kept = { 3 };
    public static readonly IReadOnlyList<int> Safe = new[] { 4 };

    bool SameType(object other) => GetType().Name == other.GetType().Name;
    bool SameFullType(object other) => GetType().FullName != other.GetType().FullName;
    bool ExactType(object other) => GetType() == other.GetType();
}

class OnlyEquals
{
    public override bool Equals(object other) => other is OnlyEquals;
}

class OnlyHash
{
    public override int GetHashCode() => 1;
}

class Both
{
    public override bool Equals(object other) => other is Both;
    public override int GetHashCode() => 1;
}

struct EqualsStruct
{
    public bool Equals(EqualsStruct other) => true;
}

record Value(int Amount);
