class Scope {
    int narrow(boolean flag) {
        int onlyInside = 3;
        if (flag) {
            return onlyInside + 1;
        }
        return 0;
    }

    Object created(boolean flag) {
        Object made = new Object();
        if (flag) {
            return made;
        }
        return null;
    }
}
