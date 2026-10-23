import Foundation

struct Location: Codable, Equatable {
    let country_id: Int
    let city_id: Int?
    let country: String
    let city: String?
    let code: String
    var title: String { city.map { "\($0), \(country)" } ?? country }
    var flag: String { String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) })) }
}

struct ConnectionState: Decodable {
    let generation: UInt64
    let phase: String
    let requested: Location?
    let connected: Location?
    let hostname: String?
    let wanted: Bool
    let established: Bool
    let error: String?
}

final class Core {
    private let handle = nord_core_new()
    deinit { nord_core_free(handle) }
    func call(_ command: [String: Any]) -> [String: Any] {
        precondition(Thread.isMainThread)
        let data = try! JSONSerialization.data(withJSONObject: command)
        let input = String(decoding: data, as: UTF8.self)
        guard let result = input.withCString({ nord_core_call(handle, $0) }) else { preconditionFailure("Core returned no result") }
        defer { nord_string_free(result) }
        return try! JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as! [String: Any]
    }
    func decode<T: Decodable>(_ type: T.Type, from value: Any) -> T {
        try! JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    var state: ConnectionState { decode(ConnectionState.self, from: call(["op": "snapshot"])["state"]!) }
    func search(_ query: String) -> [Location] {
        let response = call(["op": "search", "query": String(query.prefix(128))])
        return decode([Location].self, from: response["locations"] ?? [])
    }
}

struct FetchResult {
    let data: Data
    let status: Int
    let modified: String?
}

// One bounded system HTTP implementation, shared by catalogue and recommendation requests.
final class SmallHTTP: NSObject, URLSessionDataDelegate {
    struct StatusError: LocalizedError {
        let status: Int
        var errorDescription: String? { "Nord returned HTTP \(status). Try again later." }
    }
    private struct Request {
        var data = Data()
        var response: HTTPURLResponse?
        var failure: Error?
        let limit: Int
        let completion: (Result<FetchResult, Error>) -> Void
    }
    private var requests: [Int: Request] = [:]
    private(set) var requestCount = 0
    private(set) var receivedBytes: Int64 = 0
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }
    private lazy var session: URLSession = {
        let config = configuration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    @discardableResult
    func fetch(_ url: URL, modified: String? = nil, limit: Int = 524_288,
               completion: @escaping (Result<FetchResult, Error>) -> Void) -> URLSessionDataTask {
        precondition(url.scheme == "https" && ["api.nordvpn.com", "downloads.nordcdn.com"].contains(url.host))
        var request = URLRequest(url: url)
        request.setValue("Meridian/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        return send(request, limit: limit, completion: completion)
    }

    @discardableResult
    func send(_ request: URLRequest, limit: Int = 65_536,
              completion: @escaping (Result<FetchResult, Error>) -> Void) -> URLSessionDataTask {
        precondition(request.url?.scheme == "https" && ["api.nordvpn.com", "downloads.nordcdn.com"].contains(request.url?.host))
        let task = session.dataTask(with: request)
        requests[task.taskIdentifier] = Request(limit: limit, completion: completion)
        requestCount += 1
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, var request = requests[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        if !(200...299).contains(http.statusCode) && http.statusCode != 304 {
            request.failure = StatusError(status: http.statusCode)
        } else if response.expectedContentLength > request.limit {
            request.failure = Credentials.error("Nord's response exceeded the size limit.")
        }
        request.response = http
        requests[dataTask.taskIdentifier] = request
        completionHandler(request.failure == nil ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var request = requests[dataTask.taskIdentifier] else { return }
        if request.data.count + data.count > request.limit {
            request.failure = Credentials.error("Nord's response exceeded the size limit.")
            requests[dataTask.taskIdentifier] = request
            dataTask.cancel(); return
        }
        request.data.append(data)
        requests[dataTask.taskIdentifier] = request
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Account tokens and proof keys must never be forwarded by a redirect.
        if var pending = requests[task.taskIdentifier] {
            pending.failure = Credentials.error("Nord returned an unexpected redirect. Sign in again.")
            requests[task.taskIdentifier] = pending
        }
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        receivedBytes += metrics.transactionMetrics.reduce(0) { $0 + $1.countOfResponseBodyBytesReceived }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = requests.removeValue(forKey: task.taskIdentifier) else { return }
        if let error = request.failure ?? error { request.completion(.failure(error)) }
        else if let response = request.response {
            request.completion(.success(FetchResult(data: request.data, status: response.statusCode,
                modified: response.value(forHTTPHeaderField: "Last-Modified"))))
        } else { request.completion(.failure(NSError(domain: "Meridian", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Nord returned an unexpected response. Try again."]))) }
    }
}
