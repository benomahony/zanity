class BrokenLifecycle implements Cloneable {
    public void finalize() {}

    public Object clone() {
        return new BrokenLifecycle();
    }

    void launch() {
        new Thread().run();
        new Thread().start();
    }
}

class SafeLifecycle implements Cloneable {
    protected void finalize() {
        try {
            close();
        } finally {
            super.finalize();
        }
    }

    final public Object clone() {
        return super.clone();
    }

    void close() {}
}

class NestedSuperCallDoesNotSatisfyOuterClone implements Cloneable {
    public Object clone() {
        Runnable nested = new Runnable() {
            public void run() {
                NestedSuperCallDoesNotSatisfyOuterClone.super.clone();
            }
        };
        return new NestedSuperCallDoesNotSatisfyOuterClone();
    }
}
