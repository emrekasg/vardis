import Foundation
import VardisSampling

/// Asks a local port whether it speaks HTTP: one HEAD with a 300 ms budget, and for HTML one short GET
/// for the page title. Loopback only, no redirects followed, no cookies or cache.
enum HTTPProbe {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 0.3
        c.timeoutIntervalForResource = 1
        c.httpMaximumConnectionsPerHost = 1
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.connectionProxyDictionary = [:]
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// nil when the port does not answer HTTP within the budget.
    static func probe(port: UInt16) async -> HTTPInfo? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return nil }
        var head = URLRequest(url: url, timeoutInterval: 0.3)
        head.httpMethod = "HEAD"
        head.setValue("Vardis", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: head), let http = response as? HTTPURLResponse else { return nil }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        // Some dev servers answer HEAD with 404/405 but serve HTML on GET; try the title whenever it is not clearly something else.
        guard type.isEmpty || type.contains("html") else { return HTTPInfo(title: nil) }
        var get = URLRequest(url: url, timeoutInterval: 0.3)
        get.setValue("Vardis", forHTTPHeaderField: "User-Agent")
        get.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (bytes, _) = try? await session.bytes(for: get) else { return HTTPInfo(title: nil) }
        var data = Data()
        do {
            for try await b in bytes {
                data.append(b)
                if data.count >= 64 * 1024 { break }
                if b == UInt8(ascii: ">"), data.count > 8, data.suffix(8).lowercased() == "</title>" { break }
            }
        } catch {}
        return HTTPInfo(title: HTMLTitle.extract(from: data))
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

private extension Data {
    func lowercased() -> String { String(decoding: self, as: UTF8.self).lowercased() }
}
