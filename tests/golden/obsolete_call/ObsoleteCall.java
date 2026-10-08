class ObsoleteCall {
    void finalizeNow() {
        System.runFinalization();
    }

    void supported() {
        System.gc();
    }

    void unrelated(SystemFacade system) {
        system.runFinalization();
    }
}
