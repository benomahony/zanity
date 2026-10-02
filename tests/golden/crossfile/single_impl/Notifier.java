interface Notifier {
    void send(String message);
}

class EmailNotifier implements Notifier {
    public void send(String message) {}
}
