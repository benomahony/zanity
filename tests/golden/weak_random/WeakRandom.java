class WeakRandom {
    double token() {
        return Math.random();
    }

    int safeToken(java.security.SecureRandom random) {
        return random.nextInt();
    }
}
