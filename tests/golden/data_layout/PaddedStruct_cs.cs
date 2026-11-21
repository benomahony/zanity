struct Padded
{
    bool ready;
    long count;
    bool small;
    static int shared;
}

struct Ordered
{
    long count;
    bool ready;
    bool small;
}

class NotAStruct
{
    bool ready;
    long count;
    bool small;
}
