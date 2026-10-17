import AppKit
import SwiftUI
import WebKit

// Panel «Источники» (spec «Источники»): the files of every frame, a viewer with line numbers,
// colouring, pretty-print, find and go to line, search in all files, snippets, source maps,
// and the hand-off to Web Inspector. The page side is the `sources` region of devtools.js.

struct SourceFile: Identifiable, Hashable {
    enum Kind: String { case document, script, style, original }

    var frame: String
    var url: String
    var kind: Kind
    /// Index among the document's inline <script>s or <style>s.
    var inline: Int?

    var id: String { "\(frame)|\(kind.rawValue)|\(inline.map(String.init) ?? "")|\(url)" }

    var name: String {
        if let inline { return kind == .style ? "(встроенный стиль \(inline + 1))" : "(встроенный скрипт \(inline + 1))" }
        return place.leaf
    }

    /// Tree position: origin, folders, file name.
    var place: (origin: String, folders: [String], leaf: String) {
        guard let parsed = URL(string: url), let scheme = parsed.scheme, url.contains("://") else { return (url, [], url) }
        let host = parsed.host() ?? ""
        let origin = scheme + "://" + host + (parsed.port.map { ":\($0)" } ?? "")
        var folders = parsed.pathComponents.filter { $0 != "/" && $0 != "." }
        let leaf = parsed.hasDirectoryPath || folders.isEmpty ? "(индекс)" : folders.removeLast()
        return (origin, folders, leaf + (parsed.query.map { "?" + $0 } ?? ""))
    }

    var language: SourceLanguage {
        switch kind {
        case .document: return inline == nil ? .html : .js
        case .script: return .js
        case .style: return .css
        case .original:
            switch (URL(string: url)?.pathExtension ?? "").lowercased() {
            case "css", "scss", "less", "sass": return .css
            case "html", "htm", "vue", "svelte": return .html
            default: return .js
            }
        }
    }
}

struct SourceContent {
    var text: String
    /// Fetched again by URLSession because the page could not read it («загружено повторно»).
    var refetched = false
    var truncated = false
    var error: String?
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var code: String
}

@MainActor
@Observable
final class SourcesModel {
    enum Mode: String { case page, snippets }

    struct Hit: Identifiable {
        let id = UUID()
        let file: SourceFile
        let line: Int
        let text: String
    }

    private(set) var files: [SourceFile] = []
    var mode = Mode.page
    var selected: SourceFile?
    private(set) var content: SourceContent?
    var prettyPrinted = false
    /// A line (1-based) the viewer should scroll to and select; `token` re-triggers the same line.
    private(set) var revealLine: (line: Int, token: Int)?
    var findToken = 0
    var isLoading = false

    var searchQuery = ""
    var isSearchVisible = false
    private(set) var hits: [Hit] = []
    private(set) var isSearching = false

    var snippets: [Snippet] = SourcesModel.loadSnippets() {
        didSet { if let data = try? JSONEncoder().encode(snippets) { UserDefaults.standard.set(data, forKey: "devToolsSnippets") } }
    }
    var selectedSnippet: UUID?
    var snippetResult = ""

    @ObservationIgnored private weak var session: DevToolsSession?
    @ObservationIgnored private var cache: [String: SourceContent] = [:]
    /// Source maps by the generated file's URL (observed: console locations re-map when one loads).
    private var maps: [String: SourceMap] = [:]
    /// Original source URL → its map and index there.
    @ObservationIgnored private var originals: [String: (map: SourceMap, index: Int)] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func bind(_ session: DevToolsSession) {
        self.session = session
        session.on("hello") { [weak self, weak session] message in
            guard let self, let session, message["isTop"] as? Bool == true else { return }
            refreshTask?.cancel()
            files = []
            cache = [:]
            maps = [:]
            originals = [:]
            hits = []
            loaded = false
            if let selected, selected.kind != .original { self.selected = nil; content = nil }
            // Late enough for the page's scripts to be in; only while someone looks.
            if session.isOpen {
                refreshTask = Task {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { refreshIfNeeded() }
                }
            }
        }
    }

    private static func loadSnippets() -> [Snippet] {
        guard let data = UserDefaults.standard.data(forKey: "devToolsSnippets") else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
    }

    // MARK: - Files

    /// Lists the files once per page (and loads their source maps).
    func refreshIfNeeded() {
        guard !loaded else { return }
        refresh()
    }

    func refresh() {
        guard let session else { return }
        loaded = true
        refreshTask?.cancel()
        refreshTask = Task {
            let results = await session.callAll("sources.list")
            guard !Task.isCancelled else { return }
            var found: [SourceFile] = []
            for (frame, result) in results {
                for item in result as? [[String: Any]] ?? [] {
                    guard let url = item["url"] as? String, let kind = SourceFile.Kind(rawValue: item["kind"] as? String ?? "") else { continue }
                    found.append(SourceFile(frame: frame, url: url, kind: kind, inline: item["inline"] as? Int))
                }
            }
            let originalFiles = files.filter { $0.kind == .original }
            files = found + originalFiles.filter { original in !found.contains(original) }
            // Source maps: read every script and stylesheet once.
            for file in found where file.inline == nil && (file.kind == .script || file.kind == .style) {
                guard !Task.isCancelled else { return }
                _ = await load(file)
            }
        }
    }

    /// Frame → origin → path.
    var tree: [SourceNode] {
        guard let session else { return [] }
        // A frame that went away (an iframe navigated, the page reloaded) drops out.
        let byFrame = Dictionary(grouping: files.filter { session.frames[$0.frame] != nil }, by: \.frame)
        let order = byFrame.keys.sorted { a, b in
            if a == session.topFrame { return true }
            if b == session.topFrame { return false }
            return (session.frames[a]?.url ?? a) < (session.frames[b]?.url ?? b)
        }
        return order.map { frame in
            let folder = SourceFolder(name: "")
            for file in byFrame[frame] ?? [] {
                let place = file.place
                folder.insert(file, at: [place.origin] + place.folders)
            }
            let title = frame == session.topFrame ? "top" : (session.frames[frame]?.url ?? frame)
            return SourceNode(id: "frame|" + frame, name: title, symbol: "macwindow", file: nil, children: folder.nodes(prefix: frame))
        }
    }

    func open(_ file: SourceFile, line: Int? = nil) {
        mode = .page
        if selected != file {
            selected = file
            prettyPrinted = false
            content = cache[file.id]
            if content == nil {
                isLoading = true
                Task {
                    let loaded = await load(file)
                    if selected == file {
                        content = loaded
                        isLoading = false
                    }
                }
            }
        }
        if let line { revealLine = (line, (revealLine?.token ?? 0) + 1) }
    }

    func goTo(line: Int) {
        revealLine = (line, (revealLine?.token ?? 0) + 1)
    }

    /// Opens a script location (1-based), in its original source when a source map covers it.
    /// Console and other panels call this; it switches to Источники.
    func reveal(url: String, line: Int, column: Int = 0) {
        session?.panel = .sources
        refreshIfNeeded()
        if let original = original(of: SourceLocation(url: url, line: line, column: column)),
           let file = files.first(where: { $0.kind == .original && $0.url == original.url }) {
            open(file, line: original.line)
            return
        }
        let file = files.first { $0.url == url && $0.inline == nil && $0.kind != .original }
            ?? files.first { $0.url == url }
            ?? SourceFile(frame: session?.topFrame ?? "", url: url, kind: url.hasSuffix(".css") ? .style : .script)
        if !files.contains(file) { files.append(file) }
        open(file, line: line)
    }

    /// The original position of a generated one (1-based), when its file's source map is loaded.
    func original(of location: SourceLocation) -> SourceLocation? {
        guard let map = maps[location.url],
              let position = map.original(line: location.line - 1, column: max(location.column - 1, 0))
        else { return nil }
        return SourceLocation(function: location.function, url: map.sources[position.source], line: position.line + 1, column: position.column + 1)
    }

    // MARK: - Content

    /// The file's text: from the source map, from the page (HTTP cache, same origin or CORS),
    /// else from URLSession with the tab's cookies and user agent. Cached per page.
    func load(_ file: SourceFile) async -> SourceContent {
        if let cached = cache[file.id] { return cached }
        var result: SourceContent
        if file.kind == .original {
            if let entry = originals[file.url], let text = entry.map.contents[entry.index] {
                result = SourceContent(text: text)
            } else if let url = URL(string: file.url), ["http", "https"].contains(url.scheme) {
                result = await fetch(url).content
            } else {
                result = SourceContent(text: "", error: "Исходного текста нет в source map")
            }
        } else {
            var args: [String: Any] = ["url": file.url, "kind": file.kind.rawValue]
            if let inline = file.inline { args["inline"] = inline }
            if let page = try? await session?.call(frame: file.frame, "sources.content", args: args) as? [String: Any],
               let text = page["text"] as? String {
                result = SourceContent(text: text, truncated: page["truncated"] as? Bool ?? false)
                if file.inline == nil { await loadMap(for: file, text: text, header: page["sourceMap"] as? String) }
            } else if let url = URL(string: file.url) {
                let fetched = await fetch(url)
                result = fetched.content
                result.refetched = result.error == nil
                if result.error == nil { await loadMap(for: file, text: result.text, header: fetched.sourceMap) }
            } else {
                result = SourceContent(text: "", error: "Не удалось загрузить")
            }
        }
        cache[file.id] = result
        return result
    }

    /// Native fetch with the tab's cookies and user agent, capped at maxSourceBytes.
    private func fetch(_ url: URL) async -> (content: SourceContent, sourceMap: String?) {
        guard let session, let webView = session.webView, ["http", "https"].contains(url.scheme) else {
            return (SourceContent(text: "", error: "Не удалось загрузить \(url.absoluteString)"), nil)
        }
        let configuration = URLSessionConfiguration.ephemeral
        for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() {
            configuration.httpCookieStorage?.setCookie(cookie)
        }
        if let top = session.topFrame, let agent = try? await session.evaluate("return navigator.userAgent", frame: top) as? String {
            configuration.httpAdditionalHeaders = ["User-Agent": agent]
        }
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await urlSession.data(from: url)
            let header = (response as? HTTPURLResponse).flatMap { $0.value(forHTTPHeaderField: "SourceMap") ?? $0.value(forHTTPHeaderField: "X-SourceMap") }
            let capped = data.prefix(DevToolsSession.maxSourceBytes)
            return (SourceContent(text: String(decoding: capped, as: UTF8.self), truncated: data.count > capped.count), header)
        } catch {
            return (SourceContent(text: "", error: error.localizedDescription), nil)
        }
    }

    /// `//# sourceMappingURL` or the SourceMap header; external or inline data URL.
    private func loadMap(for file: SourceFile, text: String, header: String?) async {
        guard maps[file.url] == nil, let reference = header ?? SourceMap.mappingURL(in: text),
              let mapURL = URL(string: reference, relativeTo: URL(string: file.url))?.absoluteURL
        else { return }
        var data: Data?
        if mapURL.scheme == "data" {
            let string = mapURL.absoluteString
            guard let comma = string.firstIndex(of: ",") else { return }
            let payload = String(string[string.index(after: comma)...])
            data = string[..<comma].hasSuffix(";base64") ? Data(base64Encoded: payload.removingPercentEncoding ?? payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
        } else if let page = try? await session?.call(frame: file.frame, "sources.content", args: ["url": mapURL.absoluteString, "kind": "map"]) as? [String: Any],
                  let text = page["text"] as? String {
            data = Data(text.utf8)
        } else {
            let fetched = await fetch(mapURL).content
            data = fetched.error == nil ? Data(fetched.text.utf8) : nil
        }
        guard let data, let map = try? SourceMap(data: data, url: mapURL) else { return }
        maps[file.url] = map
        for (index, source) in map.sources.enumerated() where originals[source] == nil {
            originals[source] = (map, index)
            let original = SourceFile(frame: file.frame, url: source, kind: .original)
            if !files.contains(original) { files.append(original) }
        }
    }

    // MARK: - Search in all sources

    func search() {
        let query = searchQuery
        guard !query.isEmpty else { hits = []; return }
        isSearching = true
        Task {
            var found: [Hit] = []
            for file in files {
                let content = await load(file)
                guard searchQuery == query else { return }
                var number = 0
                content.text.enumerateLines { line, stop in
                    number += 1
                    if line.range(of: query, options: .caseInsensitive) != nil {
                        found.append(Hit(file: file, line: number, text: String(line.trimmingCharacters(in: .whitespaces).prefix(200))))
                        if found.count >= 1000 { stop = true }
                    }
                }
                if found.count >= 1000 { break }
            }
            hits = found
            isSearching = false
        }
    }

    // MARK: - Snippets

    func newSnippet() {
        var number = snippets.count + 1
        while snippets.contains(where: { $0.name == "Сниппет \(number)" }) { number += 1 }
        let snippet = Snippet(name: "Сниппет \(number)", code: "")
        snippets.append(snippet)
        selectedSnippet = snippet.id
        mode = .snippets
    }

    /// ⌘↩: runs in the console's selected frame; input and result are logged in Консоль.
    func runSnippet() {
        guard let snippet = snippets.first(where: { $0.id == selectedSnippet }), let console = session?.console else { return }
        snippetResult = "Выполняется…"
        Task { snippetResult = await console.run(snippet.code) }
    }

    // MARK: - Web Inspector

    /// «Отладить в Web Inspector»: opens it and asks its front end (private API) to show
    /// that resource at that line; if it cannot, Web Inspector stays on its Sources tab.
    func debugInWebInspector(_ file: SourceFile, line: Int?) {
        guard let webView = session?.webView else { return }
        WebInspector.show(webView)
        let url = file.url
        let line = line ?? 1
        Task {
            let script = """
            try {
              if (!window.WI || !WI.networkManager || !WI.networkManager.mainFrame || !WI.showSourceCode) return 'wait';
              const target = url.replace(/#.*$/, '');
              const frame = WI.networkManager.mainFrame;
              let code = frame.url === target ? frame.mainResource : (frame.resourcesForURL ? frame.resourcesForURL(target, true).firstValue : null);
              if (!code && WI.debuggerManager && WI.debuggerManager.scriptsForURL) {
                const scripts = WI.debuggerManager.scriptsForURL(target, WI.mainTarget);
                code = scripts && scripts[0];
              }
              if (!code) return 'missing';
              WI.showSourceCode(code, { positionToReveal: new WI.SourceCodePosition(Math.max(line - 1, 0), 0), ignoreNetworkTab: true, ignoreSearchTab: true });
              return 'ok';
            } catch (error) { return 'error: ' + error.message; }
            """
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let frontend = Self.inspectorWebView(of: webView),
                      let state = try? await frontend.callAsyncJavaScript(script, arguments: ["url": url, "line": line], contentWorld: .page) as? String
                else { continue }
                if state == "wait" { continue }
                if state != "ok" { Self.send("showResources", to: webView) }
                return
            }
        }
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func inspectorWebView(of webView: WKWebView) -> WKWebView? {
        guard let inspector = inspector(of: webView), inspector.responds(to: NSSelectorFromString("inspectorWebView")) else { return nil }
        return inspector.value(forKey: "inspectorWebView") as? WKWebView
    }

    private static func send(_ name: String, to webView: WKWebView) {
        let selector = NSSelectorFromString(name)
        guard let inspector = inspector(of: webView), inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }
}

struct SourceNode: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let file: SourceFile?
    let children: [SourceNode]?
}

/// Builds the origin/path part of the tree.
private final class SourceFolder {
    let name: String
    var folders: [String: SourceFolder] = [:]
    var files: [SourceFile] = []

    init(name: String) { self.name = name }

    func insert(_ file: SourceFile, at path: [String]) {
        guard let first = path.first else {
            if !files.contains(file) { files.append(file) }
            return
        }
        let folder = folders[first] ?? SourceFolder(name: first)
        folders[first] = folder
        folder.insert(file, at: Array(path.dropFirst()))
    }

    func nodes(prefix: String) -> [SourceNode] {
        let subfolders = folders.values.sorted { $0.name < $1.name }.map { folder in
            let id = prefix + "/" + folder.name
            let isOrigin = folder.name.contains(":")
            return SourceNode(id: id, name: folder.name, symbol: isOrigin ? "cloud" : "folder", file: nil, children: folder.nodes(prefix: id))
        }
        let leaves = files.sorted { $0.name < $1.name }.map { file in
            SourceNode(id: file.id, name: file.name, symbol: file.kind == .style ? "paintbrush" : file.kind == .document ? "doc.richtext" : "doc.text", file: file, children: nil)
        }
        return subfolders + leaves
    }
}

// MARK: - Syntax

enum SourceLanguage { case js, css, html }

/// Simple tokenizer for colouring and pretty-print (spec: "simple syntax colouring").
enum SourceSyntax {
    enum Kind { case space, plain, comment, string, regex, number, word, keyword, punct, tag, attribute, property, selector }

    struct Token {
        var start: Int
        var end: Int
        var kind: Kind
    }

    private static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof",
        "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof",
        "undefined", "var", "void", "while", "with", "yield",
    ]
    /// After these a `/` starts a regex, not a division.
    private static let beforeExpression: Set<String> = ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "instanceof", "yield", "await"]

    private static func isIdent(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
    }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 0xA0 }

    static func tokens(_ u: [UInt16], _ language: SourceLanguage) -> [Token] {
        var tokens: [Token] = []
        switch language {
        case .js: js(u, 0, u.count, &tokens)
        case .css: css(u, 0, u.count, &tokens)
        case .html: html(u, &tokens)
        }
        return tokens
    }

    private static func quoted(_ u: [UInt16], _ start: Int, _ end: Int, multiline: Bool) -> Int {
        let quote = u[start]
        var i = start + 1
        while i < end {
            if u[i] == 92 { i += 2; continue }
            if u[i] == quote { return i + 1 }
            if u[i] == 10, !multiline { return i }
            i += 1
        }
        return end
    }

    private static func blockComment(_ u: [UInt16], _ start: Int, _ end: Int) -> Int {
        var i = start + 2
        while i + 1 < end, !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
        return min(i + 2, end)
    }

    static func js(_ u: [UInt16], _ start: Int, _ end: Int, _ tokens: inout [Token]) {
        var i = start
        var regexAllowed = true
        while i < end {
            let c = u[i], next: UInt16 = i + 1 < end ? u[i + 1] : 0
            let s = i
            var kind = Kind.punct
            if isSpace(c) {
                while i < end, isSpace(u[i]) { i += 1 }
                tokens.append(Token(start: s, end: i, kind: .space))
                continue
            } else if c == 47, next == 47 {
                while i < end, u[i] != 10 { i += 1 }
                tokens.append(Token(start: s, end: i, kind: .comment))
                continue
            } else if c == 47, next == 42 {
                i = blockComment(u, s, end)
                tokens.append(Token(start: s, end: i, kind: .comment))
                continue
            } else if c == 34 || c == 39 || c == 96 {
                i = quoted(u, s, end, multiline: c == 96)
                kind = .string
            } else if c == 47, regexAllowed {
                i += 1
                var inClass = false
                while i < end {
                    let d = u[i]
                    if d == 92 { i += 2; continue }
                    if d == 10 { break }
                    if d == 91 { inClass = true } else if d == 93 { inClass = false } else if d == 47, !inClass { i += 1; break }
                    i += 1
                }
                while i < end, isIdent(u[i]) { i += 1 }
                i = min(i, end)
                kind = .regex
            } else if isDigit(c) || (c == 46 && isDigit(next)) {
                while i < end, isIdent(u[i]) || u[i] == 46 { i += 1 }
                kind = .number
            } else if isIdent(c) {
                while i < end, isIdent(u[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(u[s..<i]), count: i - s)
                kind = keywords.contains(word) ? .keyword : .word
                regexAllowed = beforeExpression.contains(word)
                tokens.append(Token(start: s, end: i, kind: kind))
                continue
            } else {
                i += 1
            }
            tokens.append(Token(start: s, end: i, kind: kind))
            regexAllowed = kind == .punct && c != 41 && c != 93
        }
    }

    static func css(_ u: [UInt16], _ start: Int, _ end: Int, _ tokens: inout [Token]) {
        var i = start
        var depth = 0
        var inValue = false
        while i < end {
            let c = u[i], next: UInt16 = i + 1 < end ? u[i + 1] : 0
            let s = i
            var kind = Kind.punct
            if isSpace(c) {
                while i < end, isSpace(u[i]) { i += 1 }
                kind = .space
            } else if c == 47, next == 42 {
                i = blockComment(u, s, end)
                kind = .comment
            } else if c == 34 || c == 39 {
                i = quoted(u, s, end, multiline: false)
                kind = .string
            } else if c == 64 { // @rule
                i += 1
                while i < end, isIdent(u[i]) || u[i] == 45 { i += 1 }
                kind = .keyword
            } else if inValue, isDigit(c) || c == 35 || ((c == 46 || c == 45) && isDigit(next)) {
                i += 1
                while i < end, isIdent(u[i]) || u[i] == 46 || u[i] == 37 { i += 1 }
                kind = .number
            } else if isIdent(c) || c == 45 {
                while i < end, isIdent(u[i]) || u[i] == 45 { i += 1 }
                kind = inValue ? .word : depth > 0 ? .property : .selector
            } else {
                switch c {
                case 123: depth += 1; inValue = false
                case 125: depth = max(depth - 1, 0); inValue = false
                case 58 where depth > 0: inValue = true
                case 59: inValue = false
                default: if depth == 0 { kind = .selector }
                }
                i += 1
            }
            tokens.append(Token(start: s, end: i, kind: kind))
        }
    }

    static func html(_ u: [UInt16], _ tokens: inout [Token]) {
        let end = u.count
        var i = 0
        func starts(_ text: String, at index: Int) -> Bool {
            let t = Array(text.utf16)
            guard index + t.count <= end else { return false }
            for k in 0..<t.count where u[index + k] | 0x20 != t[k] | 0x20 { return false }
            return true
        }
        while i < end {
            let s = i
            if starts("<!--", at: i) {
                i += 4
                while i < end, !starts("-->", at: i) { i += 1 }
                i = min(i + 3, end)
                tokens.append(Token(start: s, end: i, kind: .comment))
            } else if u[i] == 60, i + 1 < end, isIdent(u[i + 1]) || u[i + 1] == 47 || u[i + 1] == 33 {
                i += 1
                if u[i] == 47 || u[i] == 33 { i += 1 }
                while i < end, isIdent(u[i]) || u[i] == 45 { i += 1 }
                let name = String(utf16CodeUnits: Array(u[s..<i]), count: i - s).lowercased()
                tokens.append(Token(start: s, end: i, kind: .tag))
                while i < end, u[i] != 62 {
                    let a = i
                    if isSpace(u[i]) {
                        while i < end, isSpace(u[i]) { i += 1 }
                        tokens.append(Token(start: a, end: i, kind: .space))
                    } else if u[i] == 34 || u[i] == 39 {
                        i = quoted(u, a, end, multiline: true)
                        tokens.append(Token(start: a, end: i, kind: .string))
                    } else if u[i] == 61 || u[i] == 47 {
                        i += 1
                        tokens.append(Token(start: a, end: i, kind: .punct))
                    } else {
                        while i < end, !isSpace(u[i]), u[i] != 61, u[i] != 62, u[i] != 47 || i == a { i += 1 }
                        let isValue = a > 0 && u[a - 1] == 61
                        tokens.append(Token(start: a, end: i, kind: isValue ? .string : .attribute))
                    }
                }
                if i < end {
                    tokens.append(Token(start: i, end: i + 1, kind: .tag))
                    i += 1
                }
                // <script> and <style> bodies in their own language.
                if name == "<script" || name == "<style" {
                    let close = name == "<script" ? "</script" : "</style"
                    let bodyStart = i
                    while i < end, !starts(close, at: i) { i += 1 }
                    if name == "<script" { js(u, bodyStart, i, &tokens) } else { css(u, bodyStart, i, &tokens) }
                }
            } else {
                while i < end, u[i] != 60 { i += 1 }
                if i == s { i += 1 }
                tokens.append(Token(start: s, end: i, kind: .plain))
            }
        }
    }

    static func color(_ kind: Kind) -> NSColor? {
        switch kind {
        case .keyword: dynamic("#AA0D91", "#FC5FA3")
        case .string, .regex: dynamic("#C41A16", "#FC6A5D")
        case .number: dynamic("#1C00CF", "#D0BF69")
        case .comment: dynamic("#707F8C", "#7F8C98")
        case .tag, .selector: dynamic("#881280", "#E99AE0")
        case .attribute, .property: dynamic("#994500", "#F2A65A")
        default: nil
        }
    }

    private static func dynamic(_ light: String, _ dark: String) -> NSColor {
        let light = NSColor(Color(hex: light)), dark = NSColor(Color(hex: dark))
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    /// «{ }»: one statement or declaration per line, blocks indented. JS and CSS only.
    static func pretty(_ text: String, _ language: SourceLanguage) -> String {
        guard language != .html else { return text }
        let u = Array(text.utf16)
        let tokens = Self.tokens(u, language)
        var out = ""
        var indent = 0, parens = 0
        var atLineStart = true, pendingSpace = false
        func newline() {
            while out.last == " " { out.removeLast() }
            if !out.isEmpty { out += "\n" }
            atLineStart = true
            pendingSpace = false
        }
        func emit(_ piece: String) {
            if atLineStart { out += String(repeating: "  ", count: max(indent, 0)) } else if pendingSpace { out += " " }
            out += piece
            atLineStart = false
            pendingSpace = false
        }
        func nextSignificant(after index: Int) -> String? {
            var k = index + 1
            while k < tokens.count, tokens[k].kind == .space || tokens[k].kind == .comment { k += 1 }
            guard k < tokens.count else { return nil }
            return String(utf16CodeUnits: Array(u[tokens[k].start..<tokens[k].end]), count: tokens[k].end - tokens[k].start)
        }
        for (index, token) in tokens.enumerated() {
            let piece = String(utf16CodeUnits: Array(u[token.start..<token.end]), count: token.end - token.start)
            switch (token.kind, piece) {
            case (.space, _):
                if piece.contains("\n"), !atLineStart { newline() } else if !atLineStart { pendingSpace = true }
            case (.comment, _):
                emit(piece)
                if piece.hasPrefix("//") { newline() }
            case (.punct, "{"):
                pendingSpace = !atLineStart
                emit("{")
                indent += 1
                newline()
            case (.punct, "}"):
                indent -= 1
                if !atLineStart { newline() }
                emit("}")
                let next = nextSignificant(after: index)
                if let next, [";", ",", ")", "]"].contains(next) || ["else", "catch", "finally", "while"].contains(next) && language == .js {
                    pendingSpace = ![";", ",", ")", "]"].contains(next)
                } else {
                    newline()
                }
            case (.punct, ";"):
                emit(";")
                if parens == 0 { newline() } else { pendingSpace = true }
            case (.punct, "("):
                parens += 1
                emit("(")
            case (.punct, ")"):
                parens = max(parens - 1, 0)
                emit(")")
            case (.punct, ","):
                emit(",")
                pendingSpace = true
            default:
                emit(piece)
            }
        }
        return out
    }
}

// MARK: - Views

struct SourcesPanel: View {
    @Bindable var session: DevToolsSession
    @State private var selection: String?
    @State private var isGoToVisible = false
    @State private var goToText = ""

    private var model: SourcesModel { session.sources }

    var body: some View {
        HSplitView {
            navigator
                .frame(minWidth: 160, idealWidth: 240, maxWidth: 420)
            VStack(spacing: 0) {
                editorToolbar
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isSearchVisible {
                    Divider()
                    searchPane
                        .frame(height: 180)
                }
            }
            .frame(minWidth: 240)
        }
        .font(.system(size: 11))
        .onAppear { model.refreshIfNeeded() }
        .background {
            // Panel shortcuts (spec): ⌃G go to line, ⌥⌘F search in all sources, ⌘F find in file.
            Group {
                Button("") { isGoToVisible = true }.keyboardShortcut("g", modifiers: .control)
                Button("") { model.isSearchVisible = true }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("") { model.findToken += 1 }.keyboardShortcut("f", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            Picker("", selection: Bindable(model).mode) {
                Text("Страница").tag(SourcesModel.Mode.page)
                Text("Сниппеты").tag(SourcesModel.Mode.snippets)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(6)
            Divider()
            switch model.mode {
            case .page:
                List(model.tree, children: \.children, selection: $selection) { node in
                    Label(node.name, systemImage: node.symbol)
                        .lineLimit(1)
                        .help(node.file?.url ?? node.name)
                        .contextMenu {
                            if let file = node.file {
                                Button("Отладить в Web Inspector") { model.debugInWebInspector(file, line: nil) }
                                Button("Копировать URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(file.url, forType: .string)
                                }
                            }
                        }
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, id in
                    if let id, let file = model.files.first(where: { $0.id == id }) { model.open(file) }
                }
                .onChange(of: model.selected) { _, file in selection = file?.id }
                HStack {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Обновить список файлов")
                        .accessibilityLabel("Обновить список файлов")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            case .snippets:
                List(selection: Bindable(model).selectedSnippet) {
                    ForEach(Bindable(model).snippets) { $snippet in
                        TextField("Имя", text: $snippet.name)
                            .textFieldStyle(.plain)
                            .tag(snippet.id)
                            .contextMenu {
                                Button("Выполнить") { model.selectedSnippet = snippet.id; model.runSnippet() }
                                Button("Удалить", role: .destructive) { model.snippets.removeAll { $0.id == snippet.id } }
                            }
                    }
                }
                .listStyle(.plain)
                HStack {
                    Button { model.newSnippet() } label: { Label("Новый сниппет", systemImage: "plus") }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
        }
    }

    @ViewBuilder private var editorToolbar: some View {
        HStack(spacing: 8) {
            if model.mode == .snippets {
                Button { model.runSnippet() } label: { Label("Выполнить", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selectedSnippet == nil)
                    .help("Выполнить в выбранном контексте консоли (⌘↩)")
                Text(model.snippetResult)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else if let file = model.selected {
                Text(file.url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url)
                if model.content?.refetched == true {
                    Text("загружено повторно")
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Palette.dimmed))
                        .help("Страница не смогла прочитать файл; он загружен заново с cookies и user agent вкладки")
                }
                if model.content?.truncated == true {
                    Text("обрезано до 10 МБ").foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            if model.mode == .page, let file = model.selected {
                Toggle(isOn: Bindable(model).prettyPrinted) { Text("{ }").font(.system(size: 12, weight: .semibold, design: .monospaced)) }
                    .toggleStyle(.button)
                    .disabled(file.language == .html)
                    .help("Форматировать")
                Button { isGoToVisible = true } label: { Image(systemName: "arrow.down.to.line") }
                    .help("Перейти к строке (⌃G)")
                    .accessibilityLabel("Перейти к строке")
                    .popover(isPresented: $isGoToVisible) { goToLine }
                Button { model.findToken += 1 } label: { Image(systemName: "magnifyingglass") }
                    .help("Найти в файле (⌘F)")
                    .accessibilityLabel("Найти в файле")
                Button { model.debugInWebInspector(file, line: nil) } label: { Image(systemName: "ladybug") }
                    .help("Отладить в Web Inspector: точки останова и пошаговая отладка этого файла")
                    .accessibilityLabel("Отладить в Web Inspector")
            }
            Button { model.isSearchVisible.toggle() } label: { Image(systemName: "doc.text.magnifyingglass") }
                .help("Поиск во всех источниках (⌥⌘F)")
                .accessibilityLabel("Поиск во всех источниках")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var goToLine: some View {
        HStack {
            TextField("Номер строки", text: $goToText)
                .frame(width: 120)
                .onSubmit {
                    if let line = Int(goToText.trimmingCharacters(in: .whitespaces)) { model.goTo(line: line) }
                    isGoToVisible = false
                }
        }
        .padding(10)
    }

    @ViewBuilder private var editor: some View {
        switch model.mode {
        case .snippets:
            if let index = model.snippets.firstIndex(where: { $0.id == model.selectedSnippet }) {
                CodeView(
                    text: model.snippets[index].code,
                    language: .js,
                    editable: true,
                    reveal: nil,
                    findToken: model.findToken,
                    onEdit: { code in
                        if let i = model.snippets.firstIndex(where: { $0.id == model.selectedSnippet }) { model.snippets[i].code = code }
                    },
                    onRun: { model.runSnippet() },
                    onGutter: nil
                )
                .id(model.snippets[index].id)
            } else {
                placeholder("Создайте сниппет: кусок JavaScript, который можно запускать на любой странице (⌘↩)")
            }
        case .page:
            if let file = model.selected {
                if let content = model.content {
                    if let error = content.error {
                        placeholder("Не удалось загрузить: \(error)")
                    } else {
                        CodeView(
                            text: model.prettyPrinted ? SourceSyntax.pretty(content.text, file.language) : content.text,
                            language: file.language,
                            editable: false,
                            reveal: model.revealLine,
                            findToken: model.findToken,
                            onEdit: nil,
                            onRun: nil,
                            onGutter: { line in model.debugInWebInspector(file, line: line) },
                            // Покрытие: red bars on CSS lines no element used during the recording.
                            unusedLines: file.kind == .style && !model.prettyPrinted
                                ? session.coverage.unusedLines(url: file.url, inline: file.inline) : []
                        )
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                placeholder("Выберите файл слева. Ссылки на строки в консоли открываются здесь.")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск во всех источниках", text: Bindable(model).searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                if model.isSearching { ProgressView().controlSize(.small) }
                Text(model.hits.count >= 1000 ? "1000+ совпадений" : "Совпадений: \(model.hits.count)")
                    .foregroundStyle(Palette.secondaryText)
                Button { model.isSearchVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Закрыть поиск")
            }
            .padding(6)
            Divider()
            List(model.hits) { hit in
                Button { model.open(hit.file, line: hit.line) } label: {
                    HStack(spacing: 6) {
                        Text("\(hit.file.name):\(hit.line)").foregroundStyle(Palette.secondaryText)
                        Text(hit.text).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

/// Read-only (or editable, for snippets) code with line numbers, colouring and the find bar.
private struct CodeView: NSViewRepresentable {
    let text: String
    let language: SourceLanguage
    let editable: Bool
    let reveal: (line: Int, token: Int)?
    let findToken: Int
    let onEdit: ((String) -> Void)?
    let onRun: (() -> Void)?
    /// A click in the gutter: offer «Отладить в Web Inspector» for that line.
    let onGutter: ((Int) -> Void)?
    /// 1-based line ranges marked unused by «Покрытие».
    var unusedLines: [ClosedRange<Int>] = []

    /// Colouring cost grows with size; bigger files are shown plain.
    private static let maxColoured = 1_500_000

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = editable
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.delegate = context.coordinator
        textView.onRun = onRun
        scroll.documentView = textView
        let ruler = LineNumberRuler(scrollView: scroll, textView: textView)
        ruler.onClick = onGutter
        ruler.unused = unusedLines
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.onEdit = onEdit
        context.coordinator.language = language
        apply(text, to: textView, coordinator: context.coordinator)
        context.coordinator.findToken = findToken
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CodeTextView else { return }
        let coordinator = context.coordinator
        coordinator.onEdit = onEdit
        coordinator.language = language
        textView.onRun = onRun
        (scroll.verticalRulerView as? LineNumberRuler)?.onClick = onGutter
        if let ruler = scroll.verticalRulerView as? LineNumberRuler, ruler.unused != unusedLines { ruler.unused = unusedLines }
        if coordinator.text != text { apply(text, to: textView, coordinator: coordinator) }
        if let reveal, reveal.token != coordinator.revealToken {
            coordinator.revealToken = reveal.token
            DispatchQueue.main.async { Self.select(line: reveal.line, in: textView) }
        }
        if findToken != coordinator.findToken {
            coordinator.findToken = findToken
            textView.window?.makeFirstResponder(textView)
            textView.showFindBar()
        }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private func apply(_ text: String, to textView: CodeTextView, coordinator: Coordinator) {
        coordinator.text = text
        let selection = textView.selectedRange()
        textView.string = text
        Self.colour(textView, language: language)
        if editable { textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0)) }
        (textView.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.update(text)
    }

    static func colour(_ textView: NSTextView, language: SourceLanguage) {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        if storage.length <= maxColoured {
            let units = Array(storage.string.utf16)
            for token in SourceSyntax.tokens(units, language) {
                guard let color = SourceSyntax.color(token.kind) else { continue }
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: token.start, length: token.end - token.start))
            }
        }
        storage.endEditing()
    }

    static func select(line: Int, in textView: NSTextView) {
        let text = textView.string as NSString
        var start = 0, current = 1
        while current < line, start < text.length {
            let next = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
            guard next.location != NSNotFound else { break }
            start = next.location + 1
            current += 1
        }
        let range = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text = ""
        var revealToken = 0
        var findToken = 0
        var language = SourceLanguage.js
        var onEdit: ((String) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            CodeView.colour(textView, language: language)
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.update(text)
            onEdit?(text)
        }
    }
}

/// The code view: ⌘↩ runs (snippets), ⌘F opens the find bar.
private final class CodeTextView: NSTextView {
    var onRun: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36, let onRun {
            onRun()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "f", window?.firstResponder === self {
            showFindBar()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func showFindBar() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }
}

/// Line numbers beside a TextKit 1 text view; a click offers «Отладить в Web Inspector».
private final class LineNumberRuler: NSRulerView {
    var onClick: ((Int) -> Void)?
    var unused: [ClosedRange<Int>] = [] { didSet { needsDisplay = true } }
    private var lineStarts: [Int] = [0]
    private weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func update(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        lineStarts = starts
        let digits = String(starts.count).count
        ruleThickness = CGFloat(max(digits, 2)) * 7.5 + 14
        needsDisplay = true
    }

    private func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let length = (textView.string as NSString).length
        var index = line(at: characters.location)
        while index < lineStarts.count, lineStarts[index] <= NSMaxRange(characters) {
            let start = lineStarts[index]
            let fragment = start < length
                ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
                : layout.extraLineFragmentRect
            let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
            if unused.contains(where: { $0.contains(index + 1) }) {
                NSColor.systemRed.setFill()
                NSRect(x: bounds.maxX - 4, y: y, width: 3, height: fragment.height).fill()
            }
            let label = NSAttributedString(string: "\(index + 1)", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 6, y: y + (fragment.height - size.height) / 2))
            index += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick, let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        var point = textView.convert(event.locationInWindow, from: nil)
        point.x = 0
        point.y -= textView.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: point, in: container)
        let lineNumber = line(at: layout.characterIndexForGlyph(at: glyph)) + 1
        let menu = NSMenu()
        let item = NSMenuItem(title: "Отладить в Web Inspector (строка \(lineNumber))", action: #selector(debugLine(_:)), keyEquivalent: "")
        item.target = self
        item.tag = lineNumber
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func debugLine(_ sender: NSMenuItem) {
        onClick?(sender.tag)
    }
}
