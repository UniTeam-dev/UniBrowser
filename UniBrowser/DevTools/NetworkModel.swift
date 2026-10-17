import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit

/// «Регулирование» presets (Chrome's numbers): latency in ms, bandwidth in bytes per ms.
enum NetworkThrottle: String, CaseIterable, Identifiable {
    case none, fast3G, slow3G, offline

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "Без регулирования"
        case .fast3G: "Быстрый 3G"
        case .slow3G: "Медленный 3G"
        case .offline: "Офлайн"
        }
    }

    var profile: (latency: Double, down: Double, up: Double) {
        switch self {
        case .none, .offline: (0, 0, 0)
        case .fast3G: (562.5, 1440.0 / 8, 675.0 / 8)   // 1.44 Мбит/с вниз, 675 кбит/с вверх
        case .slow3G: (2000, 400.0 / 8, 400.0 / 8)     // 400 кбит/с
        }
    }
}

enum NetworkTypeFilter: String, CaseIterable, Identifiable {
    case all, fetchXHR, doc, css, js, img, font, media, ws, other

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Все"
        case .fetchXHR: "Fetch/XHR"
        case .doc: "Doc"
        case .css: "CSS"
        case .js: "JS"
        case .img: "Img"
        case .font: "Font"
        case .media: "Media"
        case .ws: "WS"
        case .other: "Другое"
        }
    }

    func matches(_ kind: NetworkKind) -> Bool {
        switch self {
        case .all: true
        case .fetchXHR: kind == .fetch || kind == .xhr
        case .doc: kind == .document
        case .css: kind == .stylesheet
        case .js: kind == .script
        case .img: kind == .image
        case .font: kind == .font
        case .media: kind == .media
        case .ws: kind == .websocket
        case .other: kind == .other
        }
    }
}

enum NetworkStatusFilter: String, CaseIterable, Identifiable {
    case all, informational, success, redirect, clientError, serverError, failed

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Любой статус"
        case .informational: "1xx"
        case .success: "2xx"
        case .redirect: "3xx"
        case .clientError: "4xx"
        case .serverError: "5xx"
        case .failed: "С ошибкой"
        }
    }

    func matches(_ entry: NetworkEntry) -> Bool {
        let status = entry.status ?? 0
        switch self {
        case .all: return true
        case .failed: return entry.error != nil
        case .informational: return (100..<200).contains(status)
        case .success: return (200..<300).contains(status)
        case .redirect: return (300..<400).contains(status)
        case .clientError: return (400..<500).contains(status)
        case .serverError: return (500..<600).contains(status)
        }
    }
}

/// One «Блокировка запросов» pattern; kept for all tabs like Chrome.
struct NetworkBlockPattern: Codable, Hashable, Identifiable {
    var id = UUID()
    var pattern: String
    var isOn = true
}

/// Panel «Сеть» (spec «Сеть»): requests from every frame, the tab's throttling, blocking
/// and cache settings (active while the panel is open), HAR, replay.
@MainActor
@Observable
final class NetworkModel {
    private(set) var entries: [NetworkEntry] = []
    var selection: NetworkEntry.ID?

    // Toolbar. Preserve log, disable cache and the patterns are remembered for all tabs.
    var preserveLog = UserDefaults.standard.bool(forKey: "devToolsPreserveLog") {
        didSet { UserDefaults.standard.set(preserveLog, forKey: "devToolsPreserveLog") }
    }
    var disableCache = UserDefaults.standard.bool(forKey: "devToolsDisableCache") {
        didSet { UserDefaults.standard.set(disableCache, forKey: "devToolsDisableCache"); apply() }
    }
    var throttle = NetworkThrottle.none { didSet { apply() } }
    var isBlockingOn = UserDefaults.standard.object(forKey: "devToolsBlockingOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isBlockingOn, forKey: "devToolsBlockingOn"); apply() }
    }
    var blockPatterns: [NetworkBlockPattern] = NetworkModel.loadPatterns() {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(blockPatterns), forKey: "devToolsBlockPatterns")
            apply()
        }
    }
    private(set) var ruleListError: String?
    var importError: String?

    // Filters and search.
    var filterText = ""
    var typeFilter = NetworkTypeFilter.all
    var statusFilter = NetworkStatusFilter.all
    var domainFilter: String?
    var hideDataURLs = false
    var onlyThirdParty = false
    var isSearchVisible = false
    var searchText = ""

    @ObservationIgnored private weak var session: DevToolsSession?
    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private var documentCount = 0
    @ObservationIgnored private var ruleList: WKContentRuleList?
    @ObservationIgnored private var ruleSource: String?
    @ObservationIgnored private let ruleListID = "devtools-" + UUID().uuidString
    @ObservationIgnored private var bypassNextReload = false

    private static let maxFrames = 1000

    private static func loadPatterns() -> [NetworkBlockPattern] {
        guard let data = UserDefaults.standard.data(forKey: "devToolsBlockPatterns") else { return [] }
        return (try? JSONDecoder().decode([NetworkBlockPattern].self, from: data)) ?? []
    }

    func bind(_ session: DevToolsSession) {
        self.session = session
        session.on("network") { [weak self] message in self?.merge(message) }
        session.on("networkFrame") { [weak self] message in self?.addFrame(message) }
        // Every new document starts with defaults: send it the tab's settings.
        session.on("hello") { [weak self] message in self?.configure(frame: message.frame) }
        observeOpen()
    }

    /// Settings apply only while the panel is open, like Chrome; closing turns them off.
    private func observeOpen() {
        withObservationTracking { _ = session?.isOpen } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observeOpen()
            }
        }
    }

    var selected: NetworkEntry? { selection.flatMap { id in index[id].map { entries[$0] } } }

    func entry(_ id: String) -> NetworkEntry? { index[id].map { entries[$0] } }

    func clear() {
        entries.removeAll()
        index.removeAll()
        selection = nil
    }

    // MARK: - Incoming

    /// A document's response (main frame or iframe), from TabWebController.
    func navigationResponse(_ response: WKNavigationResponse) {
        if response.isForMainFrame && !preserveLog { clear() }
        documentCount += 1
        let now = Date().timeIntervalSince1970 * 1000
        var entry = NetworkEntry(id: "doc-\(documentCount)", url: response.response.url?.absoluteString ?? "", start: now)
        entry.kind = .document
        entry.initiator = response.isForMainFrame ? "Навигация" : "Фрейм"
        entry.mimeType = response.response.mimeType ?? ""
        if let http = response.response as? HTTPURLResponse {
            entry.status = http.statusCode
            entry.responseHeaders = http.allHeaderFields
                .map { NetworkHeader(name: "\($0.key)", value: "\($0.value)") }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
        if response.response.expectedContentLength >= 0 { entry.resourceSize = Int(response.response.expectedContentLength) }
        append(entry)
    }

    private func merge(_ message: DevToolsMessage) {
        guard let localID = message["id"] as? String, let url = message["url"] as? String else { return }
        let key = message.frame + ":" + localID
        if let i = index[key] {
            update(&entries[i], with: message.body)
            return
        }
        // The page's navigation timing belongs to the document entry WebKit already gave us.
        if localID == "nav", let i = entries.lastIndex(where: {
            $0.kind == .document && $0.frame == nil && $0.url.split(separator: "#").first == url.split(separator: "#").first
        }) {
            entries[i].frame = message.frame
            update(&entries[i], with: message.body)
            index[key] = i
            return
        }
        var entry = NetworkEntry(id: key, frame: message.frame, url: String(url.prefix(100_000)),
                                 start: (message["start"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000)
        update(&entry, with: message.body)
        append(entry)
    }

    private func update(_ entry: inout NetworkEntry, with body: [String: Any]) {
        func string(_ key: String) -> String? { (body[key] as? String).map { String($0.prefix(DevToolsSession.maxBodyBytes)) } }
        func number(_ key: String) -> Double? { (body[key] as? NSNumber)?.doubleValue }
        func headers(_ key: String) -> [NetworkHeader]? {
            (body[key] as? [[Any]])?.prefix(500).compactMap { pair in
                guard pair.count == 2, let name = pair[0] as? String, let value = pair[1] as? String else { return nil }
                return NetworkHeader(name: name, value: String(value.prefix(10_000)))
            }
        }
        if let kind = (body["kind"] as? String).flatMap(NetworkKind.init(rawValue:)) { entry.kind = kind }
        if let method = string("method") { entry.method = String(method.prefix(20)) }
        if let initiator = string("initiator") { entry.initiator = initiator }
        if let stack = string("stack") { entry.stack = stack }
        if let start = number("start") { entry.start = start }
        if let end = number("end") { entry.end = end }
        if let status = number("status") { entry.status = Int(status) }
        if let text = string("statusText") { entry.statusText = text }
        if let mime = string("mimeType") { entry.mimeType = mime }
        if let name = string("protocol"), !name.isEmpty { entry.protocolName = name }
        if let list = headers("requestHeaders") { entry.requestHeaders = list }
        if let list = headers("responseHeaders") { entry.responseHeaders = list }
        if let text = string("requestBody") { entry.requestBody = text }
        if body["form"] as? Bool == true { entry.isForm = true }
        if let text = string("body") {
            entry.responseBody = text
            entry.isBase64 = body["base64"] as? Bool == true
        }
        if let size = number("size") { entry.resourceSize = Int(size) }
        if let size = number("decodedSize"), size > 0 { entry.resourceSize = Int(size) }
        if let size = number("transferSize") {
            // Zero is a cache hit, or a cross-origin resource without Timing-Allow-Origin.
            entry.transferSize = size > 0 || (number("decodedSize") ?? 0) > 0 ? Int(size) : nil
        }
        if let timings = body["timings"] as? [String: Any] {
            var parsed = NetworkTimings()
            for (keyPath, name, _) in NetworkTimings.names {
                if let value = (timings[name] as? NSNumber)?.doubleValue { parsed[keyPath: keyPath] = value }
            }
            entry.timings = parsed
        }
        if let error = string("error") { entry.error = error }
        if body["blocked"] as? Bool == true { entry.blocked = true }
        if let code = number("closeCode") { entry.statusText = "Закрыто (\(Int(code)))" + ((body["closeReason"] as? String).map { $0.isEmpty ? "" : ": " + $0 } ?? "") }
    }

    private func addFrame(_ message: DevToolsMessage) {
        guard let id = message["id"] as? String, let i = index[message.frame + ":" + id] else { return }
        let data = String((message["data"] as? String ?? "").prefix(DevToolsSession.maxBodyBytes))
        entries[i].frames.append(NetworkFrame(
            outgoing: message["outgoing"] as? Bool == true, data: data, binary: message["binary"] as? Bool == true,
            length: (message["length"] as? NSNumber)?.intValue ?? data.utf8.count,
            time: (message["time"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000))
        if entries[i].frames.count > Self.maxFrames { entries[i].frames.removeFirst(entries[i].frames.count - Self.maxFrames) }
    }

    private func append(_ entry: NetworkEntry) {
        entries.append(entry)
        index[entry.id] = entries.count - 1
        let overflow = entries.count - DevToolsSession.maxNetworkEntries
        if overflow > 0 {
            entries.removeFirst(overflow)
            index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
        }
    }

    // MARK: - Filters and search

    var pageSite: String {
        NetworkFormat.site(session?.webView?.url?.host() ?? "")
    }

    var domains: [String] {
        Array(Set(entries.map(\.host).filter { !$0.isEmpty })).sorted()
    }

    func visible() -> [NetworkEntry] {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        let site = pageSite
        return entries.filter { entry in
            (text.isEmpty || entry.url.localizedCaseInsensitiveContains(text))
                && typeFilter.matches(entry.kind)
                && statusFilter.matches(entry)
                && (domainFilter == nil || entry.host == domainFilter)
                && !(hideDataURLs && entry.scheme == "data")
                && (!onlyThirdParty || !entry.host.isEmpty && NetworkFormat.site(entry.host) != site)
        }
    }

    struct SearchResult: Identifiable {
        let entry: NetworkEntry
        let matches: [(label: String, line: String)]
        var id: String { entry.id }
    }

    /// «Поиск»: URLs, headers and captured bodies of every request.
    func search() -> [SearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return entries.compactMap { entry in
            var matches: [(String, String)] = []
            for (label, text) in entry.searchableTexts where text.localizedCaseInsensitiveContains(query) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true)
                where line.localizedCaseInsensitiveContains(query) {
                    matches.append((label, Self.snippet(String(line), around: query)))
                    if matches.count >= 20 { break }
                }
            }
            return matches.isEmpty ? nil : SearchResult(entry: entry, matches: matches)
        }
    }

    private static func snippet(_ line: String, around query: String) -> String {
        guard line.count > 160, let range = line.range(of: query, options: .caseInsensitive) else { return String(line.prefix(160)) }
        let start = line.index(range.lowerBound, offsetBy: -60, limitedBy: line.startIndex) ?? line.startIndex
        return "…" + String(line[start...].prefix(160))
    }

    // MARK: - Throttling, blocking, cache

    private var isActive: Bool { session?.isOpen == true }
    var activePatterns: [String] { isBlockingOn ? blockPatterns.filter { $0.isOn && !$0.pattern.isEmpty }.map(\.pattern) : [] }

    private var settings: [String: Any] {
        let profile = throttle.profile
        return [
            "blocked": activePatterns, "offline": throttle == .offline, "noStore": disableCache,
            "latency": profile.latency, "down": profile.down, "up": profile.up,
        ]
    }

    /// Re-sends the settings to every frame and rebuilds the tab's content rule list.
    private func apply() {
        updateRuleList()
        guard let session else { return }
        for id in session.frames.keys { configure(frame: id) }
    }

    private func configure(frame: String) {
        guard let session, isActive else { return } // closing the panel resets the frames (detach)
        let settings = settings
        Task { _ = try? await session.call(frame: frame, "network.configure", args: settings) }
    }

    private static var ruleStore: WKContentRuleListStore? {
        WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appending(path: "UniBrowserDevToolsRules"))
    }

    /// Офлайн or the blocking patterns as a WKContentRuleList on this tab only.
    private func updateRuleList() {
        let source = isActive ? NetworkFormat.ruleList(offline: throttle == .offline, patterns: activePatterns) : nil
        guard source != ruleSource else { return }
        ruleSource = source
        ruleListError = nil
        let controller = session?.webView?.configuration.userContentController
        if let ruleList {
            controller?.remove(ruleList)
            self.ruleList = nil
        }
        guard let source, let store = Self.ruleStore else { return }
        store.compileContentRuleList(forIdentifier: ruleListID, encodedContentRuleList: source) { [weak self] list, error in
            MainActor.assumeIsolated {
                guard let self, self.ruleSource == source else { return }
                if let error { self.ruleListError = error.localizedDescription }
                if let list {
                    controller?.add(list)
                    self.ruleList = list
                }
            }
        }
    }

    /// TabWebController asks before every main-frame reload: with «Отключить кэш» on and the
    /// panel open, a plain reload becomes `reloadFromOrigin()`. True means "cancel this one".
    func redirectsReload(_ webView: WKWebView) -> Bool {
        guard disableCache, isActive else { return false }
        if bypassNextReload {
            bypassNextReload = false
            return false
        }
        bypassNextReload = true
        Task { @MainActor in webView.reloadFromOrigin() }
        return true
    }

    func block(_ pattern: String) {
        guard !blockPatterns.contains(where: { $0.pattern == pattern }) else { return }
        blockPatterns.append(NetworkBlockPattern(pattern: pattern))
        isBlockingOn = true
    }

    // MARK: - Actions

    /// «Повторить запрос» from the frame that made it (or the top frame if it is gone).
    func replay(_ entry: NetworkEntry) {
        guard entry.canReplay, let session,
              let frame = entry.frame.flatMap({ session.frames[$0] != nil ? $0 : nil }) ?? session.topFrame
        else { return }
        var args: [String: Any] = [
            "kind": entry.kind.rawValue, "method": entry.method, "url": entry.url, "form": entry.isForm,
            "headers": entry.requestHeaders.map { [$0.name, $0.value] },
        ]
        if let body = entry.requestBody { args["body"] = body }
        Task { _ = try? await session.call(frame: frame, "network.replay", args: args) }
    }

    /// The response body of an entry the wrappers did not read: by the page from its cache,
    /// else by URLSession with the tab's cookies and user agent (marked «загружено повторно»).
    func loadBody(_ id: String) async {
        guard let session, let entry = entry(id), !entry.imported else { return }
        var result: [String: Any]?
        if let frame = entry.frame.flatMap({ session.frames[$0] != nil ? $0 : nil }) ?? session.topFrame {
            result = try? await session.call(frame: frame, "network.body", args: ["url": entry.url]) as? [String: Any]
        }
        var refetched = false
        if result?["body"] == nil, let url = URL(string: entry.url), ["http", "https"].contains(url.scheme) {
            result = await fetchNatively(url)
            refetched = result != nil
        }
        guard let result, let i = index[id] else { return }
        if let body = result["body"] as? String {
            entries[i].responseBody = String(body.prefix(DevToolsSession.maxBodyBytes))
            entries[i].isBase64 = result["base64"] as? Bool == true
        } else {
            entries[i].responseBody = "(двоичные данные, \(NetworkFormat.bytes((result["size"] as? NSNumber)?.intValue ?? 0)))"
        }
        if entries[i].mimeType.isEmpty, let mime = result["mimeType"] as? String { entries[i].mimeType = mime }
        if entries[i].resourceSize == nil { entries[i].resourceSize = (result["size"] as? NSNumber)?.intValue }
        entries[i].isRefetched = refetched
    }

    private func fetchNatively(_ url: URL) async -> [String: Any]? {
        guard let session, let webView = session.webView else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = url.host()?.lowercased() ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) && url.path().hasPrefix(cookie.path)
                && (!cookie.isSecure || url.scheme == "https")
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: name) }
        if let top = session.topFrame, let agent = try? await session.evaluate("return navigator.userAgent", frame: top) as? String {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let mime = response.mimeType ?? ""
        var result: [String: Any] = ["size": data.count, "mimeType": mime]
        if mime.hasPrefix("image/") && data.count <= DevToolsSession.maxBodyBytes {
            result["body"] = data.base64EncodedString()
            result["base64"] = true
        } else if let text = String(data: data.prefix(DevToolsSession.maxBodyBytes), encoding: .utf8) {
            result["body"] = text
        }
        return result
    }

    // MARK: - HAR

    func exportHAR() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        panel.nameFieldStringValue = (session?.webView?.url?.host() ?? "network") + ".har"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = NetworkHAR.export(entries, pageURL: session?.webView?.url?.absoluteString, pageTitle: session?.webView?.title ?? "")
        do { try data.write(to: url) } catch { importError = error.localizedDescription }
    }

    /// Imported requests are shown read-only next to the live ones.
    func importHAR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            for entry in try NetworkHAR.entries(from: Data(contentsOf: url)) { append(entry) }
        } catch {
            importError = error.localizedDescription
        }
    }
}
