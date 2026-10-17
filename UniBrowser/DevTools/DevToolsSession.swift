import AppKit
import Observation
import WebKit

/// One message from `devtools.js`: posted by a frame, or returned by its `attach()`.
struct DevToolsMessage {
    let type: String
    /// The id of the frame that sent it (`DevToolsSession.frames`).
    let frame: String
    /// The whole message as WebKit converted it: String, NSNumber, [Any], [String: Any], NSNull.
    let body: [String: Any]

    subscript(key: String) -> Any? { body[key] }
}

/// A frame that runs `devtools.js`, by the id the script picked.
struct DevToolsFrame {
    /// The latest one WebKit gave us; `call` aims at it.
    var info: WKFrameInfo
    var url: String
    /// The parent frame's id and the handle of the `<iframe>` element in it (spec «Frames»).
    var parent: String?
    var element: Int?
}

enum DevToolsPanel: String, CaseIterable, Identifiable {
    case elements, console, sources, network, performance, application, rendering, issues, security, coverage, changes

    var id: Self { self }

    var title: String {
        switch self {
        case .elements: "Элементы"
        case .console: "Консоль"
        case .sources: "Источники"
        case .network: "Сеть"
        case .performance: "Производительность"
        case .application: "Приложение"
        case .rendering: "Рендеринг"
        case .issues: "Проблемы"
        case .security: "Безопасность"
        case .coverage: "Покрытие"
        case .changes: "Изменения"
        }
    }
}

/// The developer tools of one tab: the frames running `devtools.js`, message routing to
/// the panel models, and calls into a frame. Created when the tab wakes, dropped when it
/// sleeps. Contract for panels: docs/devtools-architecture.md.
@MainActor
@Observable
final class DevToolsSession: NSObject, WKScriptMessageHandler {
    static let handlerName = "ubDevtools"

    /// Native caps (spec «Trust»); the page can post anything, so models trim to these.
    static let maxConsoleEntries = 2000
    static let maxNetworkEntries = 1000
    static let maxBodyBytes = 1_000_000
    static let maxDOMRows = 2000
    static let maxSourceBytes = 10_000_000

    /// `devtools.js` from the bundle, for every frame at document start, in the page world.
    static let script: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "devtools", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }()

    @ObservationIgnored weak var webView: WKWebView?
    private(set) var frames: [String: DevToolsFrame] = [:]
    /// The main frame's id; nil until its `hello`.
    private(set) var topFrame: String?
    /// The panel is shown and every frame streams to it.
    private(set) var isOpen = false
    var panel = DevToolsPanel.console
    /// The separate window when docked as `.window`; owned by `DevToolsDock`.
    @ObservationIgnored var window: NSWindow?

    // Panel models, one per panel file. Each registers its message handlers in `bind`.
    let console = ConsoleModel()
    let elements = ElementsModel()
    let sources = SourcesModel()
    let network = NetworkModel()
    let performance = PerformanceModel()
    let application = ApplicationModel()
    let rendering = RenderingModel()
    let issues = IssuesModel()
    let security = SecurityModel()
    let coverage = CoverageModel()
    let changes = ChangesModel()

    @ObservationIgnored private var handlers: [String: [(DevToolsMessage) -> Void]] = [:]

    override init() {
        super.init()
        console.bind(self)
        elements.bind(self)
        sources.bind(self)
        network.bind(self)
        performance.bind(self)
        application.bind(self)
        rendering.bind(self)
        issues.bind(self)
        security.bind(self)
        coverage.bind(self)
        changes.bind(self)
    }

    // MARK: - Open and close

    func open(_ panel: DevToolsPanel? = nil) {
        if let panel { self.panel = panel }
        guard !isOpen else { return }
        isOpen = true
        for id in frames.keys { attach(id) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        window?.close()
        window = nil
        for id in frames.keys {
            Task { _ = try? await evaluate("window.__ubDevtools.detach()", frame: id) }
        }
    }

    func toggle() { isOpen ? close() : open() }

    private func attach(_ id: String) {
        Task {
            guard let messages = try? await evaluate("return window.__ubDevtools.attach()", frame: id) as? [[String: Any]]
            else { return }
            for body in messages { route(body) }
        }
    }

    // MARK: - Messages

    /// `handler` gets every message of `type`, from every frame, in arrival order.
    func on(_ type: String, _ handler: @escaping (DevToolsMessage) -> Void) {
        handlers[type, default: []].append(handler)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let id = body["frame"] as? String else { return }
            let info = message.frameInfo
            if body["type"] as? String == "hello" {
                // A new main document means every old frame is gone.
                if info.isMainFrame {
                    frames.removeAll()
                    topFrame = id
                }
                frames[id] = DevToolsFrame(info: info, url: body["url"] as? String ?? "")
                if isOpen { attach(id) }
            } else {
                frames[id]?.info = info
            }
            route(body)
        }
    }

    private func route(_ body: [String: Any]) {
        guard let type = body["type"] as? String, let frame = body["frame"] as? String else { return }
        if type == "frameLink", let child = body["child"] as? String {
            let element = body["element"] as? Int
            // An <iframe> holds one document: the one it showed before (often about:blank) is gone.
            for (id, old) in frames where id != child && old.parent == frame && old.element == element {
                frames[id] = nil
            }
            frames[child]?.parent = frame
            frames[child]?.element = element
        }
        let message = DevToolsMessage(type: type, frame: frame, body: body)
        handlers[type]?.forEach { $0(message) }
    }

    // MARK: - Calls into a frame

    enum CallError: Error { case noFrame }

    /// Calls `<module>.<function>` registered with `ub.module` in that frame's `devtools.js`
    /// and returns its result as WebKit converts it ([String: Any], [Any], String, NSNumber, nil).
    func call(frame: String, _ name: String, args: [String: Any] = [:]) async throws -> Any? {
        try await evaluate("return await window.__ubDevtools.call(name, args)", frame: frame, arguments: ["name": name, "args": args])
    }

    /// `call` in every frame; failures (a frame that went away) are dropped.
    func callAll(_ name: String, args: [String: Any] = [:]) async -> [String: Any?] {
        var results: [String: Any?] = [:]
        for id in frames.keys {
            if let result = try? await call(frame: id, name, args: args) { results[id] = result }
        }
        return results
    }

    /// Runs `body` as an async function in that frame, in the page world; `arguments` become
    /// its local variables. Bypasses the page's CSP, unlike `eval`.
    func evaluate(_ body: String, frame: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let webView, let info = frames[frame]?.info else { throw CallError.noFrame }
        return try await webView.callAsyncJavaScript(body, arguments: arguments, in: info, contentWorld: .page)
    }
}
