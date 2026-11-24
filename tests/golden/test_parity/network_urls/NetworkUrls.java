import org.jsoup.Jsoup;

class NetworkUrls {
    void load() throws Exception {
        Jsoup.connect("http://user:password@example.invalid/data").get();
        Jsoup.connect("https://example.invalid/login?api_token=visible").get();
        Jsoup.connect("https://example.invalid/data").get();
    }
}
