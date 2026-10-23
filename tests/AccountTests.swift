import Foundation
import CryptoKit

// Intercepts the production URLSession transport. These tests never leave this process.
private final class Fixture: URLProtocol {
    static var respond: ((URLRequest, @escaping (Int, Data) -> Void) -> Void)!
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async {
            Self.respond(self.request) { status, data in
                guard !self.stopped else { return }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { DispatchQueue.main.async { self.stopped = true } }
}

private let attempt = "11111111-2222-4333-8444-555555555555"
private let goodReturn = URL(string: "nordvpn://login?action=login&exchange_token=test-exchange&status=done")!
private func data(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func body(_ request: URLRequest) -> [String: String] {
    let bytes: Data
    if let buffered = request.httpBody { bytes = buffered }
    else if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var read = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; read.append(contentsOf: buffer.prefix(count)) }
        bytes = read
    } else { bytes = Data() }
    return try! JSONSerialization.jsonObject(with: bytes) as! [String: String]
}
private func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "Async account test timed out")
}
private func drain() {
    let deadline = Date().addingTimeInterval(0.05)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: deadline) }
}
private func transport() -> SmallHTTP {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Fixture.self]
    return SmallHTTP(configuration: config)
}
private func loginResponse(_ redirect: String? = nil) -> Data {
    data(["attempt": attempt, "redirect_uri": redirect ?? "https://api.nordvpn.com/v1/users/oauth/login-redirect?attempt=\(attempt)"])
}

@main
enum AccountTests {
    static func main() {
        success()
        invalidReturns()
        failedFetch()
        cancelledBrowserAndFetch()
        print("PASS: native account import, proof binding, strict callback validation, HTTP failure, and cancellation. No browser, Keychain, VPN, or live network operations.")
    }

    private static func success() {
        let http = transport()
        var paths: [String] = []; var challenge = ""; var saved = 0; var finished = false
        Fixture.respond = { request, reply in
            paths.append(request.url!.path)
            precondition(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            switch request.url!.path {
            case "/v1/users/oauth/login":
                let payload = body(request)
                challenge = payload["challenge"]!
                precondition(request.httpMethod == "POST" && challenge.count == 64 && payload["preferred_flow"] == "login")
                reply(200, loginResponse())
            case "/v1/users/oauth/token":
                let payload = body(request)
                precondition(payload["attempt"] == attempt && payload["exchange_token"] == "test-exchange")
                let verifier = payload["verifier"]!
                precondition(verifier.count == 48)
                precondition(SHA256.hash(data: Data(verifier.utf8)).map { String(format: "%02x", $0) }.joined() == challenge)
                reply(201, data(["token": "test-account-token", "renew_token": "unused-test-refresh-token"]))
            case "/v1/users/services/credentials":
                precondition(request.httpMethod == "GET")
                // Nord rejects a standard Bearer value; its protocol requires the token: prefix.
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer token:test-account-token" else {
                    reply(400, data(["errors": ["code": 100106]])); return
                }
                reply(200, data(["username": "test-service-user", "password": "test-service-password", "nordlynx_private_key": "ignored-test-field"]))
            default: preconditionFailure("Unexpected account request")
            }
        }
        let account = NordAccount(http: http, openBrowser: { url, returned in
            precondition(url.host == "api.nordvpn.com")
            returned(.success(goodReturn)); return {}
        }, save: { username, password in
            precondition(username == "test-service-user" && password == "test-service-password"); saved += 1
        })
        account.signIn { result in precondition((try? result.get()) != nil); finished = true }
        wait { finished }
        precondition(saved == 1 && paths.count == 3 && !account.isSigningIn)
    }

    private static func invalidReturns() {
        let badReturns = [
            "nordvpn://other?action=login&exchange_token=test-exchange&status=done",
            "nordvpn://login?action=login&exchange_token=first&exchange_token=second&status=done"
        ]
        for callback in badReturns {
            var finished = false; var requests = 0
            Fixture.respond = { _, reply in requests += 1; reply(200, loginResponse()) }
            let account = NordAccount(http: transport(), openBrowser: { _, returned in
                returned(.success(URL(string: callback)!)); return {}
            }, save: { _, _ in preconditionFailure("Invalid callback reached Keychain") })
            account.signIn { result in
                if case .failure(let error) = result { precondition((error as? NordAccount.SignInError) == .invalidCallback) }
                else { preconditionFailure("Invalid callback accepted") }
                finished = true
            }
            wait { finished }; precondition(requests == 1)
        }
        var finished = false
        Fixture.respond = { _, reply in reply(200, loginResponse("https://unexpected.example/signin")) }
        let account = NordAccount(http: transport(), openBrowser: { _, _ in preconditionFailure("Untrusted login URL opened") },
            save: { _, _ in preconditionFailure("Untrusted login reached Keychain") })
        account.signIn { result in if case .success = result { preconditionFailure("Untrusted login accepted") }; finished = true }
        wait { finished }
    }

    private static func failedFetch() {
        for payload in [Data(), data(["username": "", "password": "test-service-password"])] {
            var finished = false
            Fixture.respond = { request, reply in
                switch request.url!.path {
                case "/v1/users/oauth/login": reply(200, loginResponse())
                case "/v1/users/oauth/token": reply(200, data(["token": "test-account-token"]))
                default: reply(payload.isEmpty ? 401 : 200, payload)
                }
            }
            let account = NordAccount(http: transport(), openBrowser: { _, returned in returned(.success(goodReturn)); return {} },
                save: { _, _ in preconditionFailure("Failed import overwrote credentials") })
            account.signIn { result in if case .success = result { preconditionFailure("Failed fetch accepted") }; finished = true }
            wait { finished }
        }
    }

    private static func cancelledBrowserAndFetch() {
        var callback: ((Result<URL, Error>) -> Void)?; var count = 0; var finished = false; var closed = false
        Fixture.respond = { _, reply in count += 1; reply(200, loginResponse()) }
        let account = NordAccount(http: transport(), openBrowser: { _, returned in callback = returned; return { closed = true } },
            save: { _, _ in preconditionFailure("Cancelled browser overwrote credentials") })
        account.signIn { result in
            if case .failure(let error) = result { precondition((error as? NordAccount.SignInError) == .cancelled) }
            else { preconditionFailure("Cancellation succeeded") }
            finished = true
        }
        wait { callback != nil }; account.cancel(); callback?(.success(goodReturn)); drain()
        precondition(finished && closed && count == 1 && !account.isSigningIn)

        var release: (() -> Void)?; var cancelled = false
        Fixture.respond = { request, reply in
            switch request.url!.path {
            case "/v1/users/oauth/login": reply(200, loginResponse())
            case "/v1/users/oauth/token": reply(200, data(["token": "test-account-token"]))
            default: release = { reply(200, data(["username": "test-service-user", "password": "test-service-password"])) }
            }
        }
        let fetching = NordAccount(http: transport(), openBrowser: { _, returned in returned(.success(goodReturn)); return {} },
            save: { _, _ in preconditionFailure("Cancelled fetch overwrote credentials") })
        fetching.signIn { _ in cancelled = true }
        wait { release != nil }; fetching.cancel(); release?(); drain()
        precondition(cancelled && !fetching.isSigningIn)
    }
}
