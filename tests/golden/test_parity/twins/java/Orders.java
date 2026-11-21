class Orders {
    int orderTotal(int[] items, int rate) {
        int total = 0;
        for (int item : items) {
            if (item > 10) {
                total += item * rate;
            } else {
                total += item;
            }
        }
        return total;
    }
}
