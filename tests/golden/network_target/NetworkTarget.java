class NetworkTarget {
    void fetch(String url) {
        Jsoup.connect(url);
    }

    void fetchHealth(String url) {
        Jsoup.connect("https://health.example.invalid");
    }
}
