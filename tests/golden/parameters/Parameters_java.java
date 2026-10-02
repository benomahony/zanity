class Parameters {
    int total(int[] prices, String currency) {
        int sum = 0;
        for (int p : prices) sum += p;
        return sum;
    }

    int safeDivide(int a, int b) {
        try {
            return a / b;
        } catch (ArithmeticException e) {
            return 0;
        }
    }

    public static void main(String[] args) {
        System.out.println("hi");
        System.out.println("bye");
    }

    int twice(int value) {
        int doubled = value * 2;
        return doubled;
    }
}
