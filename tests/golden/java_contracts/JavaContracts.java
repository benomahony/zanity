class ClassContracts {
    boolean sameName(Object left, Object right) {
        return left.getClass().getName() == right.getClass().getName();
    }

    boolean sameClass(Object left, Object right) {
        return left.getClass() == right.getClass();
    }
}

class EqualsOnly {
    public boolean equals(Object other) { return other instanceof EqualsOnly; }
}

class HashOnly {
    public int hashCode() { return 1; }
}

class BothSides {
    public boolean equals(Object other) { return other instanceof BothSides; }
    public int hashCode() { return 1; }
}

class OuterEquals {
    public boolean equals(Object other) { return other instanceof OuterEquals; }

    class NestedHash {
        public int hashCode() { return 2; }
    }
}

class LoginForm extends ActionForm {
    public String exposed;
    private String hidden;
}
