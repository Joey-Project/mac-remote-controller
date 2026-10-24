import Foundation

enum HTTPError: Error { case badRequest }

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let host: String
    let origin: String?
    let authorization: String?
    let contentType: String?
    let body: Data

    static func parse(_ data: Data) -> Self? {
        guard data.count <= 65_536, let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first, let requestLine = parseRequestLine(first),
            let headers = parseHeaders(lines.dropFirst()), let host = headers["host"],
            headers["transfer-encoding"] == nil,
            let length = Int(headers["content-length"] ?? "0"), (0...65_536).contains(length)
        else { return nil }
        let bodyStart = headerEnd.upperBound
        guard data.count == bodyStart + length, let query = parseQuery(requestLine.url) else {
            return nil
        }
        return Self(
            method: requestLine.method, path: requestLine.url.path, query: query, host: host,
            origin: headers["origin"], authorization: headers["authorization"],
            contentType: headers["content-type"],
            body: data.subdata(in: bodyStart..<data.count))
    }

    private static func parseRequestLine(_ line: String) -> (method: String, url: URLComponents)? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1",
            let url = URLComponents(string: "http://127.0.0.1\(parts[1])")
        else { return nil }
        return (String(parts[0]), url)
    }

    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String]? {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return nil }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private static func parseQuery(_ url: URLComponents) -> [String: String]? {
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard let value = item.value, query[item.name] == nil else { return nil }
            query[item.name] = value
        }
        return query
    }

}
