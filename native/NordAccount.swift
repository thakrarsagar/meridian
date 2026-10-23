import AppKit
import AuthenticationServices
import CryptoKit
import Security

// A one-shot credential import. Its only persistent effect is the injected Keychain save.
final class NordAccount {
    typealias OpenBrowser = (URL, @escaping (Result<URL, Error>) -> Void) -> (() -> Void)
    enum SignInError: LocalizedError, Equatable {
        case cancelled, invalidResponse, invalidCallback, browserUnavailable, expired
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in cancelled. Your saved credentials are unchanged."
            case .invalidResponse: return "Nord returned an unexpected sign-in response. Try again or enter IKEv2 credentials manually."
            case .invalidCallback: return "Nord's sign-in return link was invalid. Start a new sign-in."
            case .browserUnavailable: return "macOS could not open the sign-in browser. Try again or use manual IKEv2 credentials."
            case .expired: return "This sign-in attempt expired. Start a new sign-in."
            }
        }
    }
    private struct Login: Decodable { let attempt: String; let redirect_uri: String }
    private struct Token: Decodable { let token: String }
    private struct ServiceCredentials: Decodable { let username: String; let password: String }

    private let http: SmallHTTP
    private let openBrowser: OpenBrowser
    private let save: (String, String) throws -> Void
    private var generation: UUID?
    private var request: URLSessionDataTask?
    private var closeBrowser: (() -> Void)?
    private var timeout: DispatchWorkItem?
    private var completion: ((Result<Void, Error>) -> Void)?
    var progress: ((String) -> Void)?
    var isSigningIn: Bool { generation != nil }

    init(http: SmallHTTP, openBrowser: @escaping OpenBrowser,
         save: @escaping (String, String) throws -> Void = Credentials.save) {
        self.http = http; self.openBrowser = openBrowser; self.save = save
    }

    func signIn(completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        let id = UUID()
        generation = id; self.completion = completion
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(SignInError.expired), id: id) }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: deadline)
        do {
            let verifier = try Self.proofKey()
            let challenge = SHA256.hash(data: Data(verifier.utf8)).map { String(format: "%02x", $0) }.joined()
            progress?("Opening Nord Account…")
            request = http.send(try Self.request("/v1/users/oauth/login", body: [
                "challenge": challenge, "preferred_flow": "login", "redirect_flow": "default"
            ])) { [weak self] response in
                guard let self, self.generation == id else { return }
                self.request = nil
                do {
                    let login = try Self.decode(Login.self, response, step: "open sign-in")
                    let url = try Self.loginURL(login)
                    self.progress?("Complete sign-in in your browser.")
                    self.closeBrowser = self.openBrowser(url) { [weak self] returned in
                        // Also normalizes a synchronous browser-start failure onto the main queue.
                        DispatchQueue.main.async {
                            guard let self, self.generation == id else { return }
                            self.closeBrowser = nil
                            do {
                                let exchange = try Self.exchangeToken(returned.get())
                                self.fetchCredentials(attempt: login.attempt, verifier: verifier, exchange: exchange, id: id)
                            } catch { self.finish(.failure(error), id: id) }
                        }
                    }
                } catch { self.finish(.failure(error), id: id) }
            }
        } catch { finish(.failure(error), id: id) }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        if let id = generation { finish(.failure(SignInError.cancelled), id: id) }
    }

    private func fetchCredentials(attempt: String, verifier: String, exchange: String, id: UUID) {
        do {
            progress?("Retrieving IKEv2 credentials…")
            request = http.send(try Self.request("/v1/users/oauth/token", body: [
                "attempt": attempt, "verifier": verifier, "exchange_token": exchange
            ])) { [weak self] response in
                guard let self, self.generation == id else { return }
                self.request = nil
                do {
                    let token = try Self.decode(Token.self, response, step: "verify sign-in").token
                    guard Self.validSecret(token) else { throw SignInError.invalidResponse }
                    self.request = self.http.send(try Self.request("/v1/users/services/credentials", bearer: token)) { [weak self] response in
                        guard let self, self.generation == id else { return }
                        self.request = nil
                        do {
                            let credentials = try Self.decode(ServiceCredentials.self, response, step: "retrieve IKEv2 credentials")
                            guard !credentials.username.isEmpty, credentials.username.utf8.count <= 256,
                                  !credentials.username.contains(where: { $0.isWhitespace || $0.isNewline }),
                                  !credentials.password.isEmpty, credentials.password.utf8.count <= 1024 else {
                                throw SignInError.invalidResponse
                            }
                            try self.save(credentials.username, credentials.password)
                            self.finish(.success(()), id: id)
                        } catch { self.finish(.failure(error), id: id) }
                    }
                } catch { self.finish(.failure(error), id: id) }
            }
        } catch { finish(.failure(error), id: id) }
    }

    private func finish(_ result: Result<Void, Error>, id: UUID) {
        guard generation == id else { return }
        generation = nil
        timeout?.cancel(); timeout = nil
        request?.cancel(); request = nil
        let dismiss = closeBrowser; closeBrowser = nil
        let done = completion; completion = nil
        dismiss?()
        done?(result)
    }

    private static func proofKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        try Credentials.check(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes))
        // Nord's published client uses hexadecimal verifier and SHA-256 challenge encoding.
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
    private static func loginURL(_ login: Login) throws -> URL {
        guard UUID(uuidString: login.attempt) != nil,
              let components = URLComponents(string: login.redirect_uri), components.scheme == "https",
              components.host == "api.nordvpn.com", components.port == nil, components.user == nil,
              components.password == nil, components.fragment == nil, components.path == "/v1/users/oauth/login-redirect",
              components.queryItems?.count == 1, components.queryItems?.first?.name == "attempt",
              components.queryItems?.first?.value == login.attempt, let url = components.url else {
            throw SignInError.invalidResponse
        }
        return url
    }
    private static func exchangeToken(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "nordvpn", parts.host == "login", ["", "/"].contains(parts.path),
              parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
              let items = parts.queryItems, Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "action" })?.value == "login",
              items.first(where: { $0.name == "status" })?.value == "done",
              let exchange = items.first(where: { $0.name == "exchange_token" })?.value, validSecret(exchange) else {
            throw SignInError.invalidCallback
        }
        return exchange
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ response: Result<FetchResult, Error>, step: String) throws -> T {
        let data: Data
        do { data = try response.get().data }
        catch let error as SmallHTTP.StatusError {
            throw Credentials.error("Nord could not \(step) (HTTP \(error.status)). Start a new sign-in.")
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SignInError.invalidResponse }
    }
    private static func request(_ path: String, body: [String: String]? = nil, bearer: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.nordvpn.com" + path)!)
        request.setValue("Meridian/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Nord's API requires its token: credential prefix inside the Bearer value.
        if let bearer { request.setValue("Bearer token:" + bearer, forHTTPHeaderField: "Authorization") }
        return request
    }
}

final class AccountBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: NSWindow
    private var session: ASWebAuthenticationSession?
    init(anchor: NSWindow) { self.anchor = anchor }
    func open(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let returned: ASWebAuthenticationSession.CompletionHandler = { [weak self] url, error in
            DispatchQueue.main.async {
                self?.session = nil
                if let url { completion(.success(url)) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    completion(.failure(NordAccount.SignInError.cancelled))
                } else { completion(.failure(NordAccount.SignInError.browserUnavailable)) }
            }
        }
        if #available(macOS 14.4, *) {
            session = ASWebAuthenticationSession(url: url, callback: .customScheme("nordvpn"), completionHandler: returned)
        } else {
            // The published deployment target includes macOS 14.0–14.3.
            session = ASWebAuthenticationSession(url: url, callbackURLScheme: "nordvpn", completionHandler: returned)
        }
        session?.presentationContextProvider = self
        // The OS asks before reusing browser sign-in. Meridian never sees account passwords.
        session?.prefersEphemeralWebBrowserSession = false
        if session?.start() != true {
            session = nil
            completion(.failure(NordAccount.SignInError.browserUnavailable))
        }
    }
    func cancel() { session?.cancel(); session = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}
