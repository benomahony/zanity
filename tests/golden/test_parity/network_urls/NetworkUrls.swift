import Alamofire

func load() {
    AF.request("http://user:password@example.invalid/data")
    AF.request("https://example.invalid/login?api_token=visible")
    AF.request("https://example.invalid/data")
}
