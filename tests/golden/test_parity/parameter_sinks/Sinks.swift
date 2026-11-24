import Alamofire
import Foundation
import Vapor

func read(_ path: String) -> Data? {
    return FileManager.default.contents(atPath: path)
}

func readFixed() -> Data? {
    return FileManager.default.contents(atPath: "/etc/orders.conf")
}

func note(_ message: String) {
    print(message)
}

func noteFixed(_ id: Int) {
    print("order \(id) placed")
}

func buffer(_ size: Int) -> UnsafeMutableRawPointer? {
    return malloc(size)
}

func bufferFixed() -> UnsafeMutableRawPointer? {
    return malloc(4096)
}

func back(_ req: Request, _ target: String) -> Response {
    return req.redirect(to: target)
}

func home(_ req: Request) -> Response {
    return req.redirect(to: "/")
}

func fetch(_ url: String) {
    AF.request(url)
}

func fetchFixed() {
    AF.request("https://example.invalid/orders")
}
