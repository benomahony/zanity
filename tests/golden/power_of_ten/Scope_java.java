class Scope {
    int narrow(boolean flag) {
        int onlyInside = 3;
        if (flag) {
            return onlyInside + 1;
        }
        return 0;
    }

    int direct(boolean flag) {
        int value = 3;
        if (flag) {
            return value;
        }
        return value + 1;
    }

    void looped(int[] items) {
        int seen = 0;
        for (int item : items) {
            seen += item;
        }
    }

    java.util.function.IntSupplier closure() {
        int captured = 3;
        return () -> captured;
    }
}
