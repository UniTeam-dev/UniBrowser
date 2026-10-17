import Foundation

// Panel «Сеть»: the request record and its text formats (cURL, fetch, HAR, content rule
// list). Foundation only, so scripts/network_check.swift can compile it alone.

struct NetworkHeader: Hashable {
    var name: String
    var value: String
}

/// What a request is, for the Тип column and the type filter.
enum NetworkKind: String, CaseIterable {
    case document, stylesheet, script, image, font, media, fetch, xhr, websocket, other

    var title: String {
        switch self {
        case .document: "document"
        case .stylesheet: "stylesheet"
        case .script: "script"
        case .image: "image"
        case .font: "font"
        case .media: "media"
        case .fetch: "fetch"
        case .xhr: "xhr"
        case .websocket: "websocket"
        case .other: "other"
        }
    }

    /// Chrome's `_resourceType` in HAR.
    init(harType: String) {
        switch harType.lowercased() {
        case "document": self = .document
        case "stylesheet": self = .stylesheet
        case "script": self = .script
        case "image": self = .image
        case "font": self = .font
        case "media": self = .media
        case "fetch": self = .fetch
        case "xhr": self = .xhr
        case "websocket": self = .websocket
        default: self = .other
        }
    }
}

/// HAR timings in ms; -1 is unknown (cross-origin without Timing-Allow-Origin).
struct NetworkTimings: Hashable {
    var blocked = -1.0, dns = -1.0, connect = -1.0, ssl = -1.0, send = 0.0, wait = -1.0, receive = -1.0

    static var names: [(WritableKeyPath<NetworkTimings, Double>, String, String)] { [
        (\.blocked, "blocked", "Очередь и ожидание"),
        (\.dns, "dns", "DNS"),
        (\.connect, "connect", "Соединение"),
        (\.ssl, "ssl", "TLS"),
        (\.send, "send", "Отправка запроса"),
        (\.wait, "wait", "Ожидание ответа (TTFB)"),
        (\.receive, "receive", "Загрузка ответа"),
    ] }
}

/// One WebSocket frame.
struct NetworkFrame: Hashable {
    var outgoing: Bool
    var data: String
    var binary = false
    var length: Int
    /// Epoch ms.
    var time: Double
}

/// One request in «Сеть»: from the page's wrappers, resource timing, WKNavigationResponse,
/// or an imported HAR.
struct NetworkEntry: Identifiable {
    /// The sending frame's id + the page script's id, "doc-N" for documents, "har-N" for imports.
    let id: String
    var frame: String?
    var url: String
    var method = "GET"
    var kind = NetworkKind.other
    /// nil until a response; 0 with `error` for a failed load.
    var status: Int?
    var statusText = ""
    var mimeType = ""
    var initiator = ""
    var stack = ""
    var protocolName = ""
    var requestHeaders: [NetworkHeader] = []
    var responseHeaders: [NetworkHeader] = []
    var requestBody: String?
    /// The request body was FormData (sent url-encoded here; files are lost on replay).
    var isForm = false
    var responseBody: String?
    /// `responseBody` is base64 (images).
    var isBase64 = false
    /// `responseBody` came from a second request by URLSession, not from the page.
    var isRefetched = false
    /// Bytes over the network; 0 from cache; nil unknown.
    var transferSize: Int?
    /// Decoded body bytes.
    var resourceSize: Int?
    /// Epoch ms.
    var start: Double
    var end: Double?
    var timings: NetworkTimings?
    var error: String?
    /// Blocked by «Блокировка запросов» or Офлайн.
    var blocked = false
    var frames: [NetworkFrame] = []
    var imported = false

    // Sort keys and derived columns.
    var name: String {
        guard let components = URLComponents(string: url) else { return url }
        if components.scheme == "data" { return String(url.prefix(40)) }
        let last = components.path.split(separator: "/").last.map(String.init) ?? ""
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return last.isEmpty ? (components.host ?? url) + query : last + query
    }
    var host: String { URLComponents(string: url)?.host ?? "" }
    var scheme: String { URLComponents(string: url)?.scheme?.lowercased() ?? "" }
    var statusSort: Int { error != nil ? -1 : status ?? 0 }
    var sizeSort: Int { transferSize ?? resourceSize ?? -1 }
    var duration: Double { end.map { max(0, $0 - start) } ?? -1 }
    var kindTitle: String { kind.title }
    var canReplay: Bool { !imported && (kind == .fetch || kind == .xhr) }

    var statusDescription: String {
        if let error { return blocked ? "(заблокировано: \(error))" : "(ошибка) \(error)" }
        guard let status, status > 0 else { return end == nil ? "(ожидание)" : "—" }
        return String(status)
    }

    /// Query parameters from the URL, for «Полезная нагрузка».
    var queryItems: [NetworkHeader] {
        (URLComponents(string: url)?.queryItems ?? []).map { NetworkHeader(name: $0.name, value: $0.value ?? "") }
    }

    func header(_ name: String, request: Bool = false) -> String? {
        (request ? requestHeaders : responseHeaders).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Everything «Поиск» looks in.
    var searchableTexts: [(String, String)] {
        [("URL", url)]
            + requestHeaders.map { ("Заголовок запроса", "\($0.name): \($0.value)") }
            + responseHeaders.map { ("Заголовок ответа", "\($0.name): \($0.value)") }
            + [("Тело запроса", requestBody ?? ""), ("Ответ", isBase64 ? "" : responseBody ?? "")]
            + frames.map { ("Сообщение", $0.data) }
    }
}

// MARK: - Copy as cURL / fetch

enum NetworkFormat {
    /// Shell single-quoted: 'it'\''s'.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func curl(_ entry: NetworkEntry) -> String {
        var parts = ["curl " + shellQuote(entry.url)]
        if entry.method != "GET" && !(entry.method == "POST" && entry.requestBody != nil) {
            parts.append("-X " + shellQuote(entry.method))
        }
        for header in entry.requestHeaders {
            parts.append("-H " + shellQuote("\(header.name): \(header.value)"))
        }
        if let body = entry.requestBody { parts.append("--data-raw " + shellQuote(body)) }
        return parts.joined(separator: " \\\n  ")
    }

    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    static func fetch(_ entry: NetworkEntry) -> String {
        var options: [String] = []
        if !entry.requestHeaders.isEmpty {
            let headers = entry.requestHeaders.map { "    \(jsString($0.name.lowercased())): \(jsString($0.value))" }
            options.append("  \"headers\": {\n" + headers.joined(separator: ",\n") + "\n  }")
        }
        options.append("  \"body\": " + (entry.requestBody.map(jsString) ?? "null"))
        options.append("  \"method\": " + jsString(entry.method))
        return "fetch(\(jsString(entry.url)), {\n" + options.joined(separator: ",\n") + "\n});"
    }

    // MARK: - Request blocking

    /// A pattern with `*` as a WebKit content-rule `url-filter` (a limited regex, matched
    /// anywhere in the URL), the same match as `globRegex` in devtools.js.
    static func urlFilter(_ pattern: String) -> String {
        let special = Set(".+?^${}()|[]\\/")
        return pattern.split(separator: "*", omittingEmptySubsequences: false).map { part in
            part.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
        }.joined(separator: ".*")
    }

    /// The tab's content rule list: everything for Офлайн, else one rule per pattern;
    /// nil when there is nothing to block.
    static func ruleList(offline: Bool, patterns: [String]) -> String? {
        let filters = offline ? [".*"] : patterns.filter { !$0.isEmpty }.map(urlFilter)
        guard !filters.isEmpty else { return nil }
        let rules = filters.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pretty-printed JSON, or nil if `text` is not JSON.
    static func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// The site a host belongs to, for «Только сторонние».
    // ponytail: last two labels (three under two-letter second levels like co.uk); the
    // Public Suffix List if a site like github.io misleads.
    static func site(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        if labels.count <= 2 || host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host.lowercased() }
        let count = labels[labels.count - 2].count <= 3 && labels.last!.count == 2 ? 3 : 2
        return labels.suffix(count).joined(separator: ".")
    }

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) Б" }
        if count < 1024 * 1024 { return String(format: "%.1f КБ", Double(count) / 1024) }
        return String(format: "%.1f МБ", Double(count) / 1024 / 1024)
    }

    static func milliseconds(_ value: Double) -> String {
        value < 0 ? "—" : value < 1000 ? String(format: "%.0f мс", value) : String(format: "%.2f с", value / 1000)
    }
}

// MARK: - HAR 1.2

enum NetworkHAR {
    enum ImportError: LocalizedError {
        case notHAR
        var errorDescription: String? { "Файл не похож на HAR" }
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func headers(_ list: [NetworkHeader]) -> [[String: String]] {
        list.map { ["name": $0.name, "value": $0.value] }
    }

    static func export(_ entries: [NetworkEntry], pageURL: String?, pageTitle: String) -> Data {
        let started = entries.map(\.start).min() ?? Date().timeIntervalSince1970 * 1000
        let pageStart = dateStyle.format(Date(timeIntervalSince1970: started / 1000))
        let items: [[String: Any]] = entries.map { entry in
            let timings = entry.timings ?? NetworkTimings(receive: max(entry.duration, 0))
            var request: [String: Any] = [
                "method": entry.method, "url": entry.url, "httpVersion": entry.protocolName.isEmpty ? "HTTP/1.1" : entry.protocolName,
                "headers": headers(entry.requestHeaders), "cookies": [], "headersSize": -1,
                "queryString": headers(entry.queryItems), "bodySize": entry.requestBody?.utf8.count ?? 0,
            ]
            if let body = entry.requestBody {
                request["postData"] = ["mimeType": entry.header("content-type", request: true) ?? "", "text": body]
            }
            var content: [String: Any] = ["size": entry.resourceSize ?? entry.responseBody?.utf8.count ?? 0, "mimeType": entry.mimeType]
            if let body = entry.responseBody {
                content["text"] = body
                if entry.isBase64 { content["encoding"] = "base64" }
            }
            var item: [String: Any] = [
                "pageref": "page_1",
                "startedDateTime": dateStyle.format(Date(timeIntervalSince1970: entry.start / 1000)),
                "time": max(entry.duration, 0),
                "request": request,
                "response": [
                    "status": entry.status ?? 0, "statusText": entry.statusText,
                    "httpVersion": entry.protocolName.isEmpty ? "HTTP/1.1" : entry.protocolName,
                    "headers": headers(entry.responseHeaders), "cookies": [], "content": content,
                    "redirectURL": entry.header("location") ?? "", "headersSize": -1, "bodySize": entry.transferSize ?? -1,
                ] as [String: Any],
                "cache": [:] as [String: Any],
                "timings": Dictionary(uniqueKeysWithValues: NetworkTimings.names.map { ($0.1, timings[keyPath: $0.0]) }),
                "_resourceType": entry.kind.rawValue,
                "_initiator": ["type": "other", "url": entry.initiator],
            ]
            if let error = entry.error { item["_error"] = error }
            if !entry.frames.isEmpty {
                item["_webSocketMessages"] = entry.frames.map {
                    ["type": $0.outgoing ? "send" : "receive", "time": $0.time / 1000, "opcode": $0.binary ? 2 : 1, "data": $0.data] as [String: Any]
                }
            }
            return item
        }
        let har: [String: Any] = ["log": [
            "version": "1.2",
            "creator": ["name": "UniBrowser", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
            "pages": [["id": "page_1", "title": pageURL ?? pageTitle, "startedDateTime": pageStart, "pageTimings": [:] as [String: Any]]],
            "entries": items,
        ] as [String: Any]]
        return (try? JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
    }

    static func entries(from data: Data) throws -> [NetworkEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any],
              let items = log["entries"] as? [[String: Any]]
        else { throw ImportError.notHAR }
        func headerList(_ value: Any?) -> [NetworkHeader] {
            (value as? [[String: Any]] ?? []).map { NetworkHeader(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "") }
        }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        return items.enumerated().compactMap { index, item in
            guard let request = item["request"] as? [String: Any], let url = request["url"] as? String else { return nil }
            let response = item["response"] as? [String: Any] ?? [:]
            let content = response["content"] as? [String: Any] ?? [:]
            let start = (item["startedDateTime"] as? String).flatMap { (try? dateStyle.parse($0)) ?? (try? Date.ISO8601FormatStyle().parse($0)) }
                .map { $0.timeIntervalSince1970 * 1000 } ?? 0
            let time = number(item["time"]) ?? 0
            var entry = NetworkEntry(id: "har-\(index)-\(UUID().uuidString.prefix(8))", url: url, start: start)
            entry.method = request["method"] as? String ?? "GET"
            entry.requestHeaders = headerList(request["headers"])
            entry.requestBody = (request["postData"] as? [String: Any])?["text"] as? String
            entry.status = (response["status"] as? NSNumber)?.intValue
            entry.statusText = response["statusText"] as? String ?? ""
            entry.responseHeaders = headerList(response["headers"])
            entry.protocolName = response["httpVersion"] as? String ?? ""
            entry.mimeType = content["mimeType"] as? String ?? ""
            entry.responseBody = content["text"] as? String
            entry.isBase64 = content["encoding"] as? String == "base64"
            entry.resourceSize = (content["size"] as? NSNumber)?.intValue
            entry.transferSize = ((response["bodySize"] as? NSNumber)?.intValue).flatMap { $0 >= 0 ? $0 : nil }
            entry.end = start + time
            entry.kind = NetworkKind(harType: item["_resourceType"] as? String ?? "")
            entry.error = item["_error"] as? String
            entry.initiator = (item["_initiator"] as? [String: Any])?["url"] as? String ?? ""
            if let timings = item["timings"] as? [String: Any] {
                var parsed = NetworkTimings()
                for (keyPath, name, _) in NetworkTimings.names {
                    if let value = number(timings[name]) { parsed[keyPath: keyPath] = value }
                }
                entry.timings = parsed
            }
            entry.frames = (item["_webSocketMessages"] as? [[String: Any]] ?? []).map {
                let data = $0["data"] as? String ?? ""
                return NetworkFrame(outgoing: $0["type"] as? String == "send", data: data, binary: number($0["opcode"]) == 2,
                                    length: data.utf8.count, time: (number($0["time"]) ?? 0) * 1000)
            }
            entry.imported = true
            return entry
        }
    }
}
