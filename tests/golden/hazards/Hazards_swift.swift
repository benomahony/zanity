import Alamofire
import Foundation

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
    }
}

final class TrustChecked: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust, SecTrustEvaluateWithError(trust, nil) else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

let insecure = ServerTrustManager(evaluators: ["example.com": DisabledTrustEvaluator()])
let pinned = ServerTrustManager(evaluators: ["example.com": PinnedCertificatesTrustEvaluator()])

func risky(_ data: Data, _ query: String, _ apiToken: String, _ command: String) throws {
    _ = Insecure.MD5.hash(data: data)
    _ = SHA256.hash(data: data)
    _ = NSKeyedUnarchiver.unarchiveObject(with: data)
    _ = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data)
    _ = drand48()
    _ = Int.random(in: 1...6)
    srand48(42)
    _ = try db.prepare("SELECT * FROM users WHERE name = '\(query)'")
    _ = try db.prepare("SELECT * FROM users WHERE name = ?")
    print("token: \(apiToken)")
    print("signed in")
    _ = system(command)
    _ = system("ls")
    _ = mktemp(&template)
    _ = UIWebView()
    let start = CFAbsoluteTimeGetCurrent()
    work()
    print(CFAbsoluteTimeGetCurrent() - start)
    dump(data)
    exit(1)
}

func shapes(_ x: Double, _ values: Int..., flag: Bool) -> Double {
    if x == 0.1 { print("tenth") }
    if x == 0.0 { print("zero") }
    if true { print("always") }
    if flag { }
    if flag { print("set") } else { }
    for value in values { }
    while flag { }
    if flag {
        // Nothing to do until the cache is warm.
    }
    x == 1.0
    x
    let ratio = x / 0
    let half = x / 2
    return ratio + half
    print("never")
}

func leaves(_ flag: Bool, _ item: Item) -> Int {
    #if os(Windows)
    return 0
    #else
    let value = compute()
    #endif
    if case let .found(count) = item, count > 0 { return count }
    if flag {
        return
            compute(value)
    }
    for entry in entries {
        if entry.done { continue }
        if entry.bad { break }
        guard entry.valid else { throw Invalid.entry }
    }
    return value
}
