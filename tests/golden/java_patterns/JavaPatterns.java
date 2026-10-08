class JavaPatterns {
    public static int mutable = 1;
    static public int reorderedMutable = 2;
    public static final int constant = 3;
    public static final int[] mutableArray = {1, 2};

    public native void nativeCall();

    public void finalize() {}

    void run(Object lock) {
        try {
            lock.toString();
        } catch (NullPointerException expected) {
            recover();
        }
        try {
            lock.toString();
        } catch (IllegalStateException expected) {
            recover();
        }

        synchronized (lock) {}
        synchronized (this) {
            recover();
        }

        Thread worker = new Thread();
        Runnable task = new Runnable() {
            public void run() {}
        };
        task.run();
    }

    private static int hidden = 4;
    public int instance = 5;

    void recover() {}
}
