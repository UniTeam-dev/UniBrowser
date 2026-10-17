import AppKit
import SwiftUI
import WebKit

// Panel «Консоль» (spec «Консоль»): messages from every frame, input with the
// command-line API, live expressions. The page side is the `console` region of devtools.js.

/// A page value as `ub.preview` describes it, or a value WebKit converted.
struct ConsoleValue: Identifiable {
    struct Style {
        var color: Color?
        var background: Color?
        var bold = false
        var italic = false
        var size: Double?
    }

    struct Field: Identifiable {
        let id = UUID()
        let key: String
        let value: ConsoleValue
    }

    let id = UUID()
    var type: String
    var text: String
    /// The page object's id in its frame (`ub.handle`), for expanding and the context menu.
    var handle: Int?
    /// One level down, when the preview went that deep; nil means "ask the page".
    var entries: [Field]?
    var more = false
    /// `%c` styling of a string.
    var style: Style?

    static let maxText = 20_000

    init(type: String, text: String) {
        self.type = type
        self.text = text
    }

    /// From a `ub.preview` dictionary.
    init(preview any: Any?) {
        let dict = any as? [String: Any] ?? [:]
        type = dict["type"] as? String ?? "undefined"
        let text = dict["text"] as? String ?? (type == "undefined" ? "undefined" : "")
        self.text = text.count > Self.maxText ? String(text.prefix(Self.maxText)) + "…" : text
        handle = dict["handle"] as? Int
        more = dict["more"] as? Bool ?? false
        entries = (dict["entries"] as? [[String: Any]])?.map { Field(key: $0["key"] as? String ?? "", value: ConsoleValue(preview: $0["value"])) }
        if let css = dict["style"] as? [String: Any] {
            style = Style(
                color: (css["color"] as? String).flatMap(Color.init(css:)),
                background: (css["background"] as? String).flatMap(Color.init(css:)),
                bold: css["bold"] as? Bool ?? false,
                italic: css["italic"] as? Bool ?? false,
                size: css["size"] as? Double
            )
        }
    }

    /// From what `evaluateJavaScript` returns (statements typed in the console).
    init(native any: Any?) {
        switch any {
        case nil: self.init(type: "undefined", text: "undefined")
        case is NSNull: self.init(type: "null", text: "null")
        case let string as String: self.init(type: "string", text: string)
        case let number as NSNumber:
            let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
            self.init(type: isBool ? "boolean" : "number", text: isBool ? (number.boolValue ? "true" : "false") : number.stringValue)
        case let array as [Any]:
            self.init(type: "array", text: "Array(\(array.count))")
            entries = array.prefix(100).enumerated().map { Field(key: String($0.offset), value: ConsoleValue(native: $0.element)) }
        case let dict as [String: Any]:
            self.init(type: "object", text: "Object")
            entries = dict.keys.sorted().prefix(100).map { Field(key: $0, value: ConsoleValue(native: dict[$0])) }
        default: self.init(type: "object", text: String(describing: any!))
        }
    }

    var isExpandable: Bool {
        guard type == "object" || type == "array" || type == "error" else { return false }
        return entries.map { !$0.isEmpty } ?? (handle != nil)
    }

    /// Chrome-like one-line form: strings bare at the top level, objects with their first keys.
    func summary(nested: Bool = false) -> String {
        switch type {
        case "string": return nested ? "\"\(text)\"" : text
        case "array":
            guard let entries else { return text }
            let count = text.dropFirst("Array(".count).dropLast()
            return "(\(count)) [" + list(entries.map { $0.value.short }) + "]"
        case "object":
            guard let entries, !text.hasPrefix("Map"), !text.hasPrefix("Set") else { return text }
            let body = "{" + list(entries.map { "\($0.key): \($0.value.short)" }) + "}"
            return text == "Object" ? body : text + " " + body
        default: return text
        }
    }

    private func list(_ items: [String]) -> String {
        items.prefix(8).joined(separator: ", ") + (items.count > 8 || more ? ", …" : "")
    }

    private var short: String {
        switch type {
        case "string": return "\"" + (text.count > 40 ? String(text.prefix(40)) + "…" : text) + "\""
        case "object": return text == "Object" ? "{…}" : text
        default: return text
        }
    }

    var color: Color {
        switch type {
        case "string": Color(light: "#C41A16", dark: "#FC6A5D")
        case "number", "bigint", "boolean": Color(light: "#1C00CF", dark: "#9686F5")
        case "null", "undefined": Palette.secondaryText
        case "function": Color(light: "#0B4F79", dark: "#6BDFFF")
        case "node": Color(light: "#881280", dark: "#E99AE0")
        default: Palette.text
        }
    }
}

/// A place in a script: a console message's origin, a stack frame (1-based line/column).
struct SourceLocation: Equatable {
    var function: String
    var url: String
    var line: Int
    var column: Int

    init(function: String = "", url: String, line: Int, column: Int = 0) {
        self.function = function
        self.url = url
        self.line = line
        self.column = column
    }

    init(_ dict: [String: Any]) {
        self.init(function: dict["fn"] as? String ?? "", url: dict["url"] as? String ?? "", line: dict["line"] as? Int ?? 0, column: dict["column"] as? Int ?? 0)
    }

    var label: String {
        let name = URL(string: url)?.lastPathComponent ?? url
        return (name.isEmpty ? url : name) + ":\(line)"
    }
}

struct ConsoleEntry: Identifiable {
    let id = UUID()
    var level: String
    /// The console method, or "exception", "command" (input), "result", "navigation", "info".
    var method: String
    var args: [ConsoleValue]
    var frame: String
    var stack: [SourceLocation] = []
    var table: (columns: [String], rows: [(key: String, cells: [String: ConsoleValue])])?
    var time = Date()
    /// Enclosing console.group headers, outermost first.
    var groups: [UUID] = []
    /// Identical consecutive messages folded into this one.
    var count = 1
    /// For filtering and copying.
    var text: String
    /// The script (or frame) URL, for «Скрыть сообщения из этого источника».
    var source: String

    var location: SourceLocation? { stack.first { !$0.url.isEmpty && $0.line > 0 } }

    /// Level filter bucket: error, warn, info, debug.
    var bucket: String {
        switch level {
        case "error", "warn", "debug": level
        default: "info"
        }
    }
}

@MainActor
@Observable
final class ConsoleModel {
    private(set) var entries: [ConsoleEntry] = []
    var collapsedGroups: Set<UUID> = []
    var filterText = ""
    var levels: Set<String> = ConsoleModel.savedLevels {
        didSet { UserDefaults.standard.set(levels.sorted(), forKey: "devToolsConsoleLevels") }
    }
    var hiddenSources: Set<String> = []
    /// The frame input runs in; nil = the top frame.
    var context: String?
    var input = ""
    var suggestions: [String] = []
    var suggestionIndex = 0
    /// The typed part of the name being completed.
    @ObservationIgnored var suggestionPrefix = ""
    var liveExpressions: [String] = UserDefaults.standard.stringArray(forKey: "devToolsLiveExpressions") ?? [] {
        didSet { UserDefaults.standard.set(liveExpressions, forKey: "devToolsLiveExpressions") }
    }
    var liveResults: [String: String] = [:]

    /// Элементы sets this to reveal a node: `inspect(node)`, a click on a node value.
    /// Default: switch to Элементы.
    @ObservationIgnored var onInspect: ((_ frame: String, _ handle: Int) -> Void)?

    @ObservationIgnored private weak var session: DevToolsSession?
    @ObservationIgnored private var openGroups: [String: [UUID]] = [:]
    @ObservationIgnored private var history = UserDefaults.standard.stringArray(forKey: "devToolsConsoleHistory") ?? []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var draft = ""
    @ObservationIgnored private var completionCache: [String: [String]] = [:]
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    private static var savedLevels: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "devToolsConsoleLevels") ?? ["error", "warn", "info"])
    }

    private var preserveLog: Bool { UserDefaults.standard.bool(forKey: "devToolsPreserveLog") }
    private var groupSimilar: Bool { UserDefaults.standard.object(forKey: "devToolsConsoleGroupSimilar") as? Bool ?? true }

    func bind(_ session: DevToolsSession) {
        self.session = session
        session.on("console") { [weak self] message in self?.receive(message) }
        session.on("hello") { [weak self, weak session] message in
            guard let self, message["isTop"] as? Bool == true else { return }
            openGroups = [:]
            completionCache = [:]
            if let context, session?.frames[context] == nil { self.context = nil }
            if preserveLog {
                append(ConsoleEntry(level: "info", method: "navigation", args: [ConsoleValue(type: "string", text: "Переход на \(message["url"] as? String ?? "")")], frame: message.frame, text: "", source: ""))
            } else {
                clear()
            }
        }
    }

    // MARK: - Messages

    private func receive(_ message: DevToolsMessage) {
        let method = message["method"] as? String ?? "log"
        let frame = message.frame
        switch method {
        case "clear":
            if preserveLog {
                append(info("console.clear() не выполнен: включено «Сохранять при переходе»", frame: frame))
            } else {
                clear()
                append(info("Консоль очищена", frame: frame))
            }
            return
        case "groupEnd":
            _ = openGroups[frame]?.popLast()
            return
        default: break
        }
        let args = (message["args"] as? [Any] ?? []).map(ConsoleValue.init(preview:))
        let stack = (message["stack"] as? [[String: Any]] ?? []).map(SourceLocation.init)
        var entry = ConsoleEntry(
            level: message["level"] as? String ?? "log",
            method: method,
            args: args,
            frame: frame,
            stack: stack,
            time: (message["time"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
            groups: openGroups[frame] ?? [],
            text: args.map { $0.summary() }.joined(separator: " "),
            source: ""
        )
        entry.source = entry.location?.url ?? session?.frames[frame]?.url ?? ""
        if let table = message["table"] as? [String: Any] {
            let rows = (table["rows"] as? [[String: Any]] ?? []).map { row in
                (key: row["key"] as? String ?? "", cells: (row["cells"] as? [String: Any] ?? [:]).mapValues(ConsoleValue.init(preview:)))
            }
            entry.table = (table["columns"] as? [String] ?? [], rows)
        }
        append(entry)
        if method == "group" {
            openGroups[frame, default: []].append(entry.id)
            if message["collapsed"] as? Bool == true { collapsedGroups.insert(entry.id) }
        }
    }

    private func info(_ text: String, frame: String) -> ConsoleEntry {
        ConsoleEntry(level: "info", method: "info", args: [ConsoleValue(type: "string", text: text)], frame: frame, text: text, source: "")
    }

    private func append(_ entry: ConsoleEntry) {
        if groupSimilar, let last = entries.last, last.method == entry.method, last.level == entry.level,
           last.text == entry.text, last.frame == entry.frame, last.location == entry.location, last.groups == entry.groups,
           entry.table == nil, !["group", "command", "result", "navigation"].contains(entry.method) {
            entries[entries.count - 1].count += 1
            return
        }
        entries.append(entry)
        if entries.count > DevToolsSession.maxConsoleEntries {
            entries.removeFirst(entries.count - DevToolsSession.maxConsoleEntries)
        }
    }

    func clear() {
        entries.removeAll()
        collapsedGroups.removeAll()
    }

    var visibleEntries: [ConsoleEntry] {
        let regex = filterText.count > 2 && filterText.hasPrefix("/") && filterText.hasSuffix("/")
            ? try? Regex(String(filterText.dropFirst().dropLast())).ignoresCase() : nil
        return entries.filter { entry in
            if entry.groups.contains(where: collapsedGroups.contains) { return false }
            let isInput = entry.method == "command" || entry.method == "result"
            if !isInput, !levels.contains(entry.bucket) { return false }
            if !isInput, hiddenSources.contains(entry.source) { return false }
            if filterText.isEmpty { return true }
            if let regex { return entry.text.contains(regex) }
            return entry.text.localizedCaseInsensitiveContains(filterText) || entry.source.localizedCaseInsensitiveContains(filterText)
        }
    }

    var errorCount: Int { entries.lazy.filter { $0.level == "error" && $0.method != "result" }.reduce(0) { $0 + $1.count } }
    var warningCount: Int { entries.lazy.filter { $0.level == "warn" }.reduce(0) { $0 + $1.count } }

    /// The frame input runs in.
    var contextFrame: String? {
        if let context, session?.frames[context] != nil { return context }
        return session?.topFrame
    }

    /// Элементы: the selected node becomes `$0` in its frame (older selections `$1`…`$4`).
    func setSelection(frame: String, handle: Int) {
        Task { _ = try? await session?.call(frame: frame, "console.select", args: ["handle": handle]) }
    }

    // MARK: - Running input

    /// Runs what the user typed in the console input.
    func submit() {
        let code = input
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if history.last != code { history.append(code) }
        history = Array(history.suffix(100))
        UserDefaults.standard.set(history, forKey: "devToolsConsoleHistory")
        historyIndex = nil
        input = ""
        suggestions = []
        Task { await run(code) }
    }

    /// Runs code in the selected context and logs it with its result, like typed input.
    /// Snippets (Источники) use this too. Returns the result's one-line form.
    @discardableResult
    func run(_ code: String) async -> String {
        guard let session, let frame = contextFrame else { return "" }
        append(ConsoleEntry(level: "log", method: "command", args: [ConsoleValue(type: "string", text: code)], frame: frame, text: code, source: ""))
        let result = await evaluate(code, frame: frame)
        completionCache = [:]
        if let text = result["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if result["clear"] as? Bool == true { clear() }
        if let handle = result["inspect"] as? Int { inspect(frame: frame, handle: handle) }
        let isError = result["error"] != nil
        let value = isError ? ConsoleValue(preview: result["error"]) : result["converted"] as? ConsoleValue ?? ConsoleValue(preview: result["value"])
        var entry = ConsoleEntry(level: isError ? "error" : "log", method: "result", args: isError ? [ConsoleValue(type: "string", text: "Uncaught"), value] : [value], frame: frame, text: value.summary(), source: "")
        entry.stack = (result["stack"] as? [[String: Any]] ?? []).map(SourceLocation.init)
        append(entry)
        return (isError ? "Uncaught " : "") + value.summary()
    }

    /// Spec: an expression first (`callAsyncJavaScript`, top-level `await`, the command-line
    /// API through `with`), statements via `evaluateJavaScript` when it does not parse.
    /// Returns console.finish's dictionary: value | error (+stack), copy, clear, inspect;
    /// statements give `converted` (a ConsoleValue of what WebKit converted) instead of `value`.
    private func evaluate(_ code: String, frame: String, live: Bool = false) async -> [String: Any] {
        guard let session else { return [:] }
        _ = try? await session.call(frame: frame, "console.running", args: ["on": true])
        defer { Task { _ = try? await session.call(frame: frame, "console.running", args: ["on": false]) } }
        let declaration = code.range(of: #"^\s*(async\s+)?(function|class)\b"#, options: .regularExpression) != nil
        if !declaration {
            let token = UUID().uuidString
            // Non-strict on purpose: `with` is how Chrome scopes the command-line API too.
            let body = """
            const __ubD = window.__ubDevtools;
            const __ubScope = await __ubD.call('console.begin', { token: __ubToken });
            let __ubValue;
            try { with (__ubScope) { __ubValue = await (
            \(code)
            ); } } catch (__ubError) { return await __ubD.call('console.finish', { error: __ubError, thrown: true, live: __ubLive }); }
            return await __ubD.call('console.finish', { value: __ubValue, live: __ubLive });
            """
            do {
                return try await session.evaluate(body, frame: frame, arguments: ["__ubToken": token, "__ubLive": live]) as? [String: Any] ?? [:]
            } catch {
                let began = (try? await session.call(frame: frame, "console.began", args: ["token": token])) as? Bool ?? true
                if began || live { return ["error": ["type": "string", "text": Self.message(of: error)]] }
            }
        }
        return await runStatements(code, frame: frame)
    }

    private func runStatements(_ code: String, frame: String) async -> [String: Any] {
        guard let session, let webView = session.webView, let info = session.frames[frame]?.info else { return [:] }
        _ = try? await session.call(frame: frame, "console.install")
        // WebKit calls back on the main thread; the box only carries the value across the await.
        struct Outcome: @unchecked Sendable { let result: Result<Any, Error> }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            webView.evaluateJavaScript(code, in: info, in: .page) { continuation.resume(returning: Outcome(result: $0)) }
        }.result
        var result = (try? await session.call(frame: frame, "console.uninstall")) as? [String: Any] ?? [:]
        switch outcome {
        case .success(let value):
            // WebKit hands undefined over as an Optional.none boxed in Any.
            let mirror = Mirror(reflecting: value)
            let unboxed: Any? = mirror.displayStyle == .optional ? mirror.children.first?.value : value
            result["converted"] = ConsoleValue(native: unboxed)
        case .failure(let error as WKError) where error.code == .javaScriptResultTypeIsUnsupported:
            result["value"] = ["type": "undefined", "text": "(значение этого типа не передаётся из страницы: введите его отдельным выражением)"]
        case .failure(let error):
            result["error"] = ["type": "string", "text": Self.message(of: error)]
        }
        return result
    }

    private static func message(of error: Error) -> String {
        let info = (error as NSError).userInfo
        return info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    func inspect(frame: String, handle: Int) {
        if let onInspect { onInspect(frame, handle) } else { session?.panel = .elements }
    }

    // MARK: - Values

    /// «Сохранить как глобальную переменную»: logs `tempN` and the value, like Chrome.
    func saveGlobal(_ value: ConsoleValue, frame: String) {
        guard let handle = value.handle else { return }
        Task {
            guard let name = try? await session?.call(frame: frame, "console.saveGlobal", args: ["handle": handle]) as? String else { return }
            append(ConsoleEntry(level: "log", method: "command", args: [ConsoleValue(type: "string", text: name)], frame: frame, text: name, source: ""))
            append(ConsoleEntry(level: "log", method: "result", args: [value], frame: frame, text: value.summary(), source: ""))
        }
    }

    func copy(_ value: ConsoleValue, frame: String, json: Bool) {
        Task {
            var text = value.text
            if let handle = value.handle {
                text = (try? await session?.call(frame: frame, "console.stringify", args: ["handle": handle, "json": json]) as? String) ?? value.summary()
            } else if json, value.type == "string",
                      let data = try? JSONSerialization.data(withJSONObject: value.text, options: .fragmentsAllowed) {
                text = String(decoding: data, as: UTF8.self)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func expand(_ value: ConsoleValue, frame: String) async -> [ConsoleValue.Field] {
        if let entries = value.entries { return entries }
        guard let handle = value.handle,
              let list = try? await session?.call(frame: frame, "core.expand", args: ["handle": handle]) as? [[String: Any]]
        else { return [] }
        return list.map { ConsoleValue.Field(key: $0["key"] as? String ?? "", value: ConsoleValue(preview: $0["value"])) }
    }

    /// Opens a script location in Источники (through its source map when there is one).
    func reveal(_ location: SourceLocation) {
        session?.sources.reveal(url: location.url, line: location.line, column: location.column)
    }

    /// The location to show: the original source's when a source map covers it.
    func displayed(_ location: SourceLocation) -> SourceLocation {
        session?.sources.original(of: location) ?? location
    }

    var frameChoices: [(id: String, title: String)] {
        guard let session else { return [] }
        let top = session.topFrame
        return session.frames.filter { $0.key != top }
            .map { (id: $0.key, title: $0.value.url.replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)) }
            .sorted { $0.title < $1.title }
    }

    // MARK: - History and completion

    /// ↑/↓ in the input: older/newer history entries; the unsent text comes back at the end.
    func historyStep(_ step: Int) {
        guard !history.isEmpty else { return }
        if historyIndex == nil { draft = input }
        let index = (historyIndex ?? history.count) + step
        if index >= history.count {
            historyIndex = nil
            input = draft
        } else {
            historyIndex = max(index, 0)
            input = history[historyIndex!]
        }
        suggestions = []
    }

    /// Completion for the name before the cursor: keys of the expression before the dot
    /// (asked from the page: own and prototype keys), or globals and the command-line API.
    func updateSuggestions(beforeCursor text: String) {
        completionTask?.cancel()
        guard let chain = text.firstMatch(of: #/[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\.?$/#)?.output,
              !text[..<chain.startIndex].hasSuffix("."), let frame = contextFrame
        else {
            suggestions = []
            return
        }
        let parts = chain.split(separator: ".", omittingEmptySubsequences: false)
        let prefix = String(parts.last ?? "")
        let expr = parts.dropLast().joined(separator: ".")
        if expr.isEmpty, prefix.isEmpty {
            suggestions = []
            return
        }
        completionTask = Task {
            let key = frame + "|" + expr
            var names = completionCache[key]
            if names == nil {
                names = (try? await session?.call(frame: frame, "console.complete", args: ["expr": expr])) as? [String] ?? []
                completionCache[key] = names
            }
            guard !Task.isCancelled else { return }
            let matches = Set(names ?? []).filter { $0.hasPrefix(prefix) && $0 != prefix && !$0.hasPrefix("__ub") }
            suggestionPrefix = prefix
            suggestions = Array(matches.sorted { ($0.hasPrefix("_") ? 1 : 0, $0) < ($1.hasPrefix("_") ? 1 : 0, $1) }.prefix(50))
            suggestionIndex = 0
        }
    }

    // MARK: - Live expressions

    func refreshLive() async {
        guard let frame = contextFrame else { return }
        for expression in liveExpressions where !expression.trimmingCharacters(in: .whitespaces).isEmpty {
            let result = await evaluate(expression, frame: frame, live: true)
            let value = ConsoleValue(preview: result["error"] ?? result["value"])
            liveResults[expression] = value.summary(nested: true)
        }
    }
}

/// Whether ↩ should run the input: brackets balanced, no open string or comment.
func consoleInputIsComplete(_ code: String) -> Bool {
    var depth = 0
    var quote: Character?
    var escaped = false
    var lineComment = false, blockComment = false
    var previous: Character = " "
    for character in code {
        defer { previous = character }
        if lineComment { if character == "\n" { lineComment = false }; continue }
        if blockComment { if previous == "*" && character == "/" { blockComment = false }; continue }
        if let open = quote {
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == open { quote = nil }
            continue
        }
        switch character {
        case "\"", "'", "`": quote = character
        case "/" where previous == "/": lineComment = true
        case "*" where previous == "/": blockComment = true
        case "(", "[", "{": depth += 1
        case ")", "]", "}": depth -= 1
        default: break
        }
    }
    return depth <= 0 && quote == nil && !blockComment
}

extension Color {
    /// "#rrggbb", "#rrggbbaa" or "rgba(r, g, b, a)", as a canvas normalises CSS colours.
    init?(css: String) {
        if css.hasPrefix("#") {
            self.init(hex: String(css.prefix(7)))
            return
        }
        let numbers = css.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        self.init(red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, opacity: numbers.count > 3 ? numbers[3] : 1)
    }
}

// MARK: - Views

struct ConsolePanel: View {
    @Bindable var session: DevToolsSession
    @AppStorage("devToolsConsoleTimestamps") private var timestamps = false
    @AppStorage("devToolsPreserveLog") private var preserve = false
    @AppStorage("devToolsConsoleGroupSimilar") private var groupSimilar = true

    private var model: ConsoleModel { session.console }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !model.liveExpressions.isEmpty {
                liveExpressions
                Divider()
            }
            messages
            Divider()
            input
        }
        .font(.system(size: 11, design: .monospaced))
        .task {
            session.sources.refreshIfNeeded()
            // Spec: pinned expressions re-evaluated every 250 ms while the panel is visible.
            while !Task.isCancelled {
                if !model.liveExpressions.isEmpty { await model.refreshLive() }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.clear() } label: { Image(systemName: "nosign") }
                .help("Очистить консоль (⌃L)")
                .accessibilityLabel("Очистить консоль")
            Picker("Контекст", selection: Binding(get: { model.context ?? "" }, set: { model.context = $0.isEmpty ? nil : $0 })) {
                Text("top").tag("")
                ForEach(model.frameChoices, id: \.id) { frame in
                    Text(frame.title).tag(frame.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Где выполняется ввод")
            TextField("Фильтр", text: Bindable(model).filterText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 80, maxWidth: 220)
                .help("Текст или /регулярное выражение/")
            Menu(levelsTitle) {
                ForEach([("error", "Ошибки"), ("warn", "Предупреждения"), ("info", "Информация"), ("debug", "Подробные")], id: \.0) { level, title in
                    Toggle(title, isOn: Binding(
                        get: { model.levels.contains(level) },
                        set: { if $0 { model.levels.insert(level) } else { model.levels.remove(level) } }
                    ))
                }
            }
            .fixedSize()
            Toggle("Сохранять при переходе", isOn: $preserve)
                .lineLimit(1)
                .fixedSize()
                .toggleStyle(.checkbox)
            if !model.hiddenSources.isEmpty {
                Button("Скрыто источников: \(model.hiddenSources.count)") { model.hiddenSources.removeAll() }
                    .help("Показать сообщения из всех источников")
            }
            Spacer(minLength: 4)
            if model.errorCount > 0 {
                Label("\(model.errorCount)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            if model.warningCount > 0 {
                Label("\(model.warningCount)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Button { model.liveExpressions.append("") } label: { Image(systemName: "eye") }
                .help("Добавить живое выражение")
                .accessibilityLabel("Добавить живое выражение")
            Menu {
                Toggle("Метки времени", isOn: $timestamps)
                Toggle("Группировать одинаковые сообщения", isOn: $groupSimilar)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Настройки консоли")
            .accessibilityLabel("Настройки консоли")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var levelsTitle: String {
        let all: Set<String> = ["error", "warn", "info", "debug"]
        if model.levels == all { return "Все уровни" }
        if model.levels == ["error", "warn", "info"] { return "Уровни по умолчанию" }
        return "Выбранные уровни"
    }

    private var liveExpressions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.liveExpressions.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Image(systemName: "eye").foregroundStyle(Palette.secondaryText)
                    TextField("Выражение", text: Binding(
                        get: { model.liveExpressions.indices.contains(index) ? model.liveExpressions[index] : "" },
                        set: { if model.liveExpressions.indices.contains(index) { model.liveExpressions[index] = $0 } }
                    ))
                    .textFieldStyle(.plain)
                    Text(model.liveResults[model.liveExpressions.indices.contains(index) ? model.liveExpressions[index] : ""] ?? "")
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { if model.liveExpressions.indices.contains(index) { model.liveExpressions.remove(at: index) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Убрать выражение")
                        .accessibilityLabel("Убрать живое выражение")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Palette.surfaceAlt)
    }

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.visibleEntries) { entry in
                    ConsoleRow(entry: entry, model: model, timestamps: timestamps)
                    Divider().opacity(0.5)
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.suggestions.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, name in
                                Text(name)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == model.suggestionIndex ? Palette.accent.opacity(0.25) : .clear)
                                    .id(index)
                            }
                        }
                    }
                    .frame(height: min(Double(model.suggestions.count), 6) * 16)
                    .onChange(of: model.suggestionIndex) { _, index in proxy.scrollTo(index) }
                }
                .background(Palette.surfaceAlt)
                Divider()
            }
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 5)
                ConsoleInput(model: model)
                    .frame(height: Double(min(max(model.input.components(separatedBy: "\n").count, 1), 8)) * 15 + 8)
            }
            .padding(.leading, 8)
        }
    }
}

private struct ConsoleRow: View {
    let entry: ConsoleEntry
    let model: ConsoleModel
    let timestamps: Bool
    @State private var showsStack: Bool

    init(entry: ConsoleEntry, model: ConsoleModel, timestamps: Bool) {
        self.entry = entry
        self.model = model
        self.timestamps = timestamps
        _showsStack = State(initialValue: entry.method == "trace")
    }

    private static let timeFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3))

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            icon.frame(width: 12)
            if timestamps {
                Text(entry.time, format: Self.timeFormat).foregroundStyle(Palette.secondaryText)
            }
            VStack(alignment: .leading, spacing: 2) {
                if entry.method == "group" {
                    Button {
                        if model.collapsedGroups.contains(entry.id) { model.collapsedGroups.remove(entry.id) } else { model.collapsedGroups.insert(entry.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.collapsedGroups.contains(entry.id) ? "chevron.right" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                            ConsoleArgs(args: entry.args, frame: entry.frame, model: model).bold()
                        }
                    }
                    .buttonStyle(.plain)
                } else if let table = entry.table {
                    ConsoleTable(columns: table.columns, rows: table.rows)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if !entry.stack.isEmpty && entry.method != "log" {
                            Button { showsStack.toggle() } label: {
                                Image(systemName: showsStack ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .help("Стек вызовов")
                        }
                        ConsoleArgs(args: entry.args, frame: entry.frame, model: model)
                    }
                }
                if showsStack {
                    ForEach(Array(entry.stack.enumerated()), id: \.offset) { _, frame in
                        HStack(spacing: 4) {
                            Text(frame.function.isEmpty ? "(анонимная)" : frame.function)
                            if !frame.url.isEmpty, frame.line > 0 {
                                Text("@")
                                link(frame)
                            }
                        }
                        .padding(.leading, 12)
                        .foregroundStyle(Palette.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.count > 1 {
                Text("\(entry.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Palette.dimmed))
            }
            if let location = entry.location {
                link(location).lineLimit(1)
            }
        }
        .padding(.leading, 8 + Double(entry.groups.count) * 14)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(background)
        .contextMenu {
            Button("Копировать") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            if !entry.source.isEmpty {
                Button("Скрыть сообщения из этого источника") { model.hiddenSources.insert(entry.source) }
            }
            Divider()
            Button("Очистить консоль") { model.clear() }
        }
    }

    private func link(_ location: SourceLocation) -> some View {
        let shown = model.displayed(location)
        return Button(shown.label) { model.reveal(location) }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondaryText)
            .underline()
            .help("Открыть в «Источниках»: \(shown.url):\(shown.line)")
    }

    @ViewBuilder private var icon: some View {
        switch entry.method {
        case "command": Image(systemName: "chevron.right").foregroundStyle(Palette.accent)
        case "result": Image(systemName: "chevron.left").foregroundStyle(Palette.secondaryText)
        case "navigation": Image(systemName: "arrow.right.circle").foregroundStyle(Palette.secondaryText)
        default:
            switch entry.level {
            case "error": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case "warn": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case "info": Image(systemName: "info.circle").foregroundStyle(Palette.secondaryText)
            default: Image(systemName: "circle").hidden()
            }
        }
    }

    private var background: Color {
        switch entry.level {
        case "error" where entry.method != "command": Color(light: "#FFF0F0", dark: "#3A2224")
        case "warn": Color(light: "#FFFBE5", dark: "#3A3420")
        default: .clear
        }
    }
}

/// A message's arguments: runs of inline values as one text, expandable objects each
/// on their own disclosure line.
private struct ConsoleArgs: View {
    let args: [ConsoleValue]
    let frame: String
    let model: ConsoleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(chunks.indices, id: \.self) { index in
                let chunk = chunks[index]
                if chunk.count == 1, chunk[0].isExpandable || chunk[0].type == "node" {
                    ConsoleValueView(value: chunk[0], key: nil, frame: frame, model: model)
                } else {
                    Text(inline(chunk))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .contextMenu { ConsoleValueMenu(value: chunk[0], frame: frame, model: model) }
                }
            }
        }
    }

    private var chunks: [[ConsoleValue]] {
        var result: [[ConsoleValue]] = []
        for value in args {
            if value.isExpandable || value.type == "node" { result.append([value]) }
            else if let last = result.last, !(last[0].isExpandable || last[0].type == "node") { result[result.count - 1].append(value) }
            else { result.append([value]) }
        }
        return result
    }

    private func inline(_ values: [ConsoleValue]) -> AttributedString {
        var text = AttributedString()
        for (index, value) in values.enumerated() {
            // %c pieces join without a space, like Chrome.
            if index > 0, values[index - 1].style == nil || value.style == nil { text += AttributedString(" ") }
            var piece = AttributedString(value.summary())
            if value.type != "string" || value.style != nil { piece.foregroundColor = value.type == "string" ? Palette.text : value.color }
            if let style = value.style {
                if let color = style.color { piece.foregroundColor = color }
                if let background = style.background { piece.backgroundColor = background }
                var font = Font.system(size: style.size ?? 11, design: .monospaced)
                if style.bold { font = font.bold() }
                if style.italic { font = font.italic() }
                piece.font = font
            }
            text += piece
        }
        return text
    }
}

/// An expandable value; its children load from the page when the preview stopped short.
private struct ConsoleValueView: View {
    let value: ConsoleValue
    let key: String?
    let frame: String
    let model: ConsoleModel
    @State private var isExpanded = false
    @State private var children: [ConsoleValue.Field]?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if value.isExpandable {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 10)
                } else if key != nil {
                    Color.clear.frame(width: 10, height: 1)
                }
                label
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if value.type == "node", let handle = value.handle { model.inspect(frame: frame, handle: handle); return }
                guard value.isExpandable else { return }
                isExpanded.toggle()
                if isExpanded, children == nil {
                    Task { children = await model.expand(value, frame: frame) }
                }
            }
            .contextMenu { ConsoleValueMenu(value: value, frame: frame, model: model) }
            if isExpanded {
                ForEach(children ?? []) { field in
                    AnyView(ConsoleValueView(value: field.value, key: field.key, frame: frame, model: model))
                        .padding(.leading, 14)
                }
                if value.more {
                    Text("…").foregroundStyle(Palette.secondaryText).padding(.leading, 24)
                }
            }
        }
    }

    private var label: some View {
        var text = AttributedString()
        if let key {
            var name = AttributedString(key + ": ")
            name.foregroundColor = Color(light: "#881391", dark: "#E36EEC")
            text += name
        }
        var shown = AttributedString(isExpanded && value.isExpandable ? value.text : value.summary(nested: key != nil))
        shown.foregroundColor = key == nil && value.type == "string" ? Palette.text : value.color
        text += shown
        return Text(text).lineLimit(isExpanded ? nil : 1).help(value.type == "node" ? "Показать в «Элементах»" : "")
    }
}

/// Context menu of a value (spec «Консоль»).
private struct ConsoleValueMenu: View {
    let value: ConsoleValue
    let frame: String
    let model: ConsoleModel

    var body: some View {
        if value.handle != nil {
            Button("Сохранить как глобальную переменную") { model.saveGlobal(value, frame: frame) }
        }
        Button("Копировать значение") { model.copy(value, frame: frame, json: false) }
        Button("Копировать как JSON") { model.copy(value, frame: frame, json: true) }
        if value.type == "node", let handle = value.handle {
            Button("Показать в «Элементах»") { model.inspect(frame: frame, handle: handle) }
        }
    }
}

/// console.table.
private struct ConsoleTable: View {
    let columns: [String]
    let rows: [(key: String, cells: [String: ConsoleValue])]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell(Text("(индекс)").bold())
                ForEach(columns, id: \.self) { cell(Text($0).bold()) }
            }
            .background(Palette.surfaceAlt)
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    cell(Text(rows[index].key))
                    ForEach(columns, id: \.self) { column in
                        let value = rows[index].cells[column]
                        cell(Text(value?.summary(nested: true) ?? "").foregroundStyle(value?.color ?? Palette.text))
                    }
                }
            }
        }
        .overlay(Rectangle().stroke(Palette.dimmed))
        .textSelection(.enabled)
    }

    private func cell(_ text: some View) -> some View {
        text
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 60, maxWidth: 260, alignment: .leading)
            .border(Palette.dimmed.opacity(0.6), width: 0.5)
    }
}

// MARK: - Input

/// The multi-line console input: ↩ runs once brackets balance, ⇧↩ a new line, ↑/↓ history
/// (or the completion list when shown), Tab/→ accept a completion, Esc hides it, ⌃L clears.
private struct ConsoleInput: NSViewRepresentable {
    let model: ConsoleModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = KeyTextView()
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onKey = { [weak coordinator = context.coordinator, weak textView] event in
            guard let coordinator, let textView else { return false }
            return coordinator.handle(event, in: textView)
        }
        textView.setAccessibilityLabel("Ввод консоли")
        scroll.documentView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != model.input else { return }
        textView.string = model.input
        textView.setSelectedRange(NSRange(location: (model.input as NSString).length, length: 0))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ConsoleModel

        init(model: ConsoleModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.input = textView.string
            completeAtCursor(textView)
        }

        private func completeAtCursor(_ textView: NSTextView) {
            let cursor = textView.selectedRange().location
            let before = (textView.string as NSString).substring(to: min(cursor, (textView.string as NSString).length))
            model.updateSuggestions(beforeCursor: before)
        }

        func handle(_ event: NSEvent, in textView: NSTextView) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let text = textView.string as NSString
            let cursor = textView.selectedRange().location
            let hasSuggestions = !model.suggestions.isEmpty
            switch event.keyCode {
            case 36, 76: // Return
                guard !flags.contains(.shift), consoleInputIsComplete(textView.string) else { return false }
                model.submit()
                return true
            case 126: // ↑
                if hasSuggestions {
                    model.suggestionIndex = max(model.suggestionIndex - 1, 0)
                    return true
                }
                guard !text.substring(to: cursor).contains("\n") else { return false }
                model.historyStep(-1)
                return true
            case 125: // ↓
                if hasSuggestions {
                    model.suggestionIndex = min(model.suggestionIndex + 1, model.suggestions.count - 1)
                    return true
                }
                guard !text.substring(from: cursor).contains("\n") else { return false }
                model.historyStep(1)
                return true
            case 48: // Tab
                if hasSuggestions { accept(in: textView) }
                return true
            case 124 where hasSuggestions && cursor == text.length: // →
                accept(in: textView)
                return true
            case 53: // Esc
                model.suggestions = []
                return true
            case 37 where flags == .control: // ⌃L
                model.clear()
                return true
            default:
                return false
            }
        }

        private func accept(in textView: NSTextView) {
            guard model.suggestions.indices.contains(model.suggestionIndex) else { return }
            let name = model.suggestions[model.suggestionIndex]
            let cursor = textView.selectedRange().location
            let typed = (model.suggestionPrefix as NSString).length
            textView.insertText(name, replacementRange: NSRange(location: cursor - typed, length: typed))
            model.suggestions = []
        }
    }
}

/// An NSTextView that offers key presses to `onKey` first.
final class KeyTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}
