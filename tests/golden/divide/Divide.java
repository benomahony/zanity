class Divide {
    static int divide(int value, int divisor) {
        int bad = value / 0;
        int good = value / divisor;
        double nearZero = value / 0.1;
        return bad + good + (int) nearZero;
    }
}
