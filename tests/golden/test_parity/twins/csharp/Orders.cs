class Orders
{
    int OrderTotal(int[] items, int rate)
    {
        int total = 0;
        foreach (int item in items)
        {
            if (item > 10)
            {
                total += item * rate;
            }
            else
            {
                total += item;
            }
        }
        return total;
    }
}
