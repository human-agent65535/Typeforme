import Foundation

enum BridgeHTTPClientCoreError: Error {
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case server(String)
    case decodingFailed(String)
}

struct BridgeHTTPClientCore {
    let baseURL: URL
    let token: String
    let applyClientIdentity: (inout URLRequest) -> Void

    func request<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        json body: Body,
        timeout: TimeInterval
    ) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request(path: path, method: method, body: data, contentType: "application/json", timeout: timeout)
    }

    func request<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        contentType: String? = nil,
        timeout: TimeInterval
    ) async throws -> T {
        var request = try makeRequest(
            path: path,
            method: method,
            timeout: timeout,
            accept: "application/json",
            acceptEncoding: "gzip"
        )
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    func request<T: Decodable>(
        path: String,
        method: String,
        bodyFileURL: URL,
        contentLength: Int64,
        contentType: String,
        timeout: TimeInterval
    ) async throws -> T {
        var request = try makeRequest(
            path: path,
            method: method,
            timeout: timeout,
            accept: "application/json",
            acceptEncoding: "gzip"
        )
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = InputStream(url: bodyFileURL)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    func makeRequest(
        path: String,
        method: String,
        timeout: TimeInterval,
        accept: String,
        acceptEncoding: String?
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw BridgeHTTPClientCoreError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let acceptEncoding {
            request.setValue(acceptEncoding, forHTTPHeaderField: "Accept-Encoding")
        }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        applyClientIdentity(&request)
        return request
    }

    func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw BridgeHTTPClientCoreError.invalidResponse
        }
        switch http.statusCode {
        case 401:
            throw BridgeHTTPClientCoreError.unauthorized
        case 403:
            throw BridgeHTTPClientCoreError.forbidden
        case 404:
            throw BridgeHTTPClientCoreError.notFound
        default:
            break
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(BridgeHTTPErrorPayload.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw BridgeHTTPClientCoreError.server(message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BridgeHTTPClientCoreError.decodingFailed(Self.decodingErrorDescription(error))
        }
    }

    private static func decodingErrorDescription(_ error: Error) -> String {
        let path: ([CodingKey]) -> String = { keys in
            keys.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            let base = path(context.codingPath + [key])
            return base.isEmpty ? "Missing key \(key.stringValue)" : "Missing key \(base)"
        case DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            let base = path(context.codingPath)
            return base.isEmpty ? context.debugDescription : "\(base): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}

private struct BridgeHTTPErrorPayload: Decodable {
    let error: String
}
