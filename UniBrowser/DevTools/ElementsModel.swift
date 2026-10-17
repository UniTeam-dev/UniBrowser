import AppKit
import WebKit

/// A DOM node in one frame: the frame's `devtools.js` id and the node's handle there.
struct DOMKey: Hashable {
    let frame: String
    let handle: Int
}

/// One node as the page script describes it (`row()` in devtools.js #region elements).
struct DOMNode: Decodable {
    let h: Int
    /// `Node.nodeType`.
    let t: Int
    let n: String
    var a: [[String]]?
    /// Text, comment or document URL.
    var v: String?
    /// Hidden with H.
    var hid: Bool?
    /// An `<iframe>`/`<frame>`: its child is the child frame's document.
    var f: Bool?
    /// A single short text child shown on the element's row, and its handle.
    var it: String?
    var ith: Int?
    var c: Int?

    var attributes: [(name: String, value: String)] { (a ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
    var isElement: Bool { t == 1 }
    var hasChildren: Bool { (c ?? 0) > 0 }
    var isVoid: Bool { isElement && Self.voidElements.contains(n) }
    static let voidElements: Set = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
}

/// One line of the tree: a node, or the closing tag of an expanded element.
struct DOMRow: Identifiable, Hashable {
    let key: DOMKey
    let depth: Int
    let isClosing: Bool
    var id: String { "\(key.frame):\(key.handle)\(isClosing ? "/" : "")" }
}

/// Decodes what WebKit converted from a JS result (dictionaries, arrays, NSNumber).
enum DevToolsJSON {
    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, !(value is NSNull), let data = try? JSONSerialization.data(withJSONObject: [value]) else { return nil }
        return (try? JSONDecoder().decode([T].self, from: data))?.first
    }
}

/// Panel «Элементы» (spec «Элементы»): the lazily loaded DOM tree of every frame, the
/// selection, the picker and the edits. Side panes are in `ElementsSidebar.swift`.
@MainActor
@Observable
final class ElementsModel {
    enum Editing: Equatable {
        /// An attribute's `name="value"` text; nil name adds one.
        case attribute(DOMKey, String?)
        case text(DOMKey)
    }

    struct HTMLEdit: Identifiable {
        let key: DOMKey
        var text: String
        var id: DOMKey { key }
    }

    @ObservationIgnored private(set) weak var session: DevToolsSession?
    private(set) var nodes: [DOMKey: DOMNode] = [:]
    @ObservationIgnored private var children: [DOMKey: [DOMKey]] = [:]
    @ObservationIgnored private var parents: [DOMKey: DOMKey] = [:]
    private(set) var expanded: Set<DOMKey> = []
    private(set) var rows: [DOMRow] = []
    private(set) var root: DOMKey?
    private(set) var selected: DOMKey?
    /// Recent selections, newest first, for the console's `$0`…`$4`.
    private(set) var selectedHandles: [DOMKey] = []
    private(set) var flashing: Set<DOMKey> = []
    private(set) var isPicking = false
    /// Bumped whenever the selected node may look different; the side panes reload on it.
    private(set) var revision = 0
    /// Bumped to scroll the tree to the selection (reveal, keyboard).
    private(set) var scrollRequest = 0
    var editing: Editing?
    var htmlEdit: HTMLEdit?
    var error: String?

    var searchQuery = ""
    private(set) var searchResults: [DOMKey] = []
    private(set) var searchIndex = 0

    @ObservationIgnored private var hovered: DOMKey?
    @ObservationIgnored private var escMonitor: Any?

    // MARK: - Session

    func bind(_ session: DevToolsSession) {
        self.session = session
        session.on("hello") { [weak self] message in
            if message["isTop"] as? Bool == true { self?.reset() }
        }
        session.on("frameLink") { [weak self] message in
            guard let self, let element = message["element"] as? Int else { return }
            let key = DOMKey(frame: message.frame, handle: element)
            if children[key] != nil { Task { await self.loadChildren(key) } }
        }
        session.on("domChanged") { [weak self] message in self?.domChanged(message) }
        session.on("picked") { [weak self, weak session] message in
            guard let self, let handle = message["handle"] as? Int else { return }
            stopPicking()
            session?.open(.elements)
            Task { await self.reveal(DOMKey(frame: message.frame, handle: handle)) }
        }
        session.on("pickCancel") { [weak self] _ in self?.stopPicking() }
    }

    private func reset() {
        nodes = [:]
        children = [:]
        parents = [:]
        expanded = []
        rows = []
        root = nil
        selected = nil
        selectedHandles = []
        searchResults = []
        editing = nil
        htmlEdit = nil
        hovered = nil
    }

    /// Loads the top document and opens `<html>` and `<body>`, like Chrome.
    func load() async {
        guard let session, let top = session.topFrame else { return }
        if root?.frame == top { return }
        reset()
        guard let node = DevToolsJSON.decode(DOMNode.self, from: try? await session.call(frame: top, "elements.document")) else { return }
        let key = register(node, frame: top, parent: nil)
        root = key
        await ensureExpanded(key)
        if let html = children[key]?.first(where: { nodes[$0]?.n == "html" && nodes[$0]?.isElement == true }) {
            await ensureExpanded(html)
            if let body = children[html]?.first(where: { nodes[$0]?.n == "body" }) { select(body) }
        }
    }

    // MARK: - Tree

    @discardableResult
    private func register(_ node: DOMNode, frame: String, parent: DOMKey?) -> DOMKey {
        let key = DOMKey(frame: frame, handle: node.h)
        nodes[key] = node
        if let parent { parents[key] = parent }
        return key
    }

    func parent(of key: DOMKey) -> DOMKey? { parents[key] }

    /// The frame shown inside an `<iframe>` row, when that frame runs devtools.js.
    private func childFrame(of key: DOMKey) -> String? {
        session?.frames.first { $0.value.parent == key.frame && $0.value.element == key.handle }?.key
    }

    func loadChildren(_ key: DOMKey, flashNew: Bool = false) async {
        guard let session, let node = nodes[key] else { return }
        var list: [DOMKey] = []
        if node.f == true, let child = childFrame(of: key) {
            if let doc = DevToolsJSON.decode(DOMNode.self, from: try? await session.call(frame: child, "elements.document")) {
                list = [register(doc, frame: child, parent: key)]
            }
        } else {
            let rows = DevToolsJSON.decode([DOMNode].self, from: try? await session.call(frame: key.frame, "elements.children", args: ["handle": key.handle])) ?? []
            list = rows.prefix(DevToolsSession.maxDOMRows).map { register($0, frame: key.frame, parent: key) }
        }
        let old = Set(children[key] ?? [])
        children[key] = list
        if flashNew { flash(list.filter { !old.contains($0) }) }
        rebuild()
    }

    func ensureExpanded(_ key: DOMKey) async {
        if children[key] == nil { await loadChildren(key) }
        expanded.insert(key)
        rebuild()
    }

    func isExpandable(_ key: DOMKey) -> Bool {
        guard let node = nodes[key] else { return false }
        return node.hasChildren || node.f == true
    }

    func toggle(_ key: DOMKey) {
        if expanded.contains(key) {
            expanded.remove(key)
            rebuild()
        } else {
            Task { await ensureExpanded(key) }
        }
    }

    /// ⌥-click: the node and everything under it.
    func expandAll(_ key: DOMKey, depth: Int = 0) async {
        guard isExpandable(key), depth < 30, rows.count < DevToolsSession.maxDOMRows else { return }
        await ensureExpanded(key)
        for child in children[key] ?? [] { await expandAll(child, depth: depth + 1) }
    }

    func collapseAll(_ key: DOMKey) {
        var stack = [key]
        while let next = stack.popLast() {
            expanded.remove(next)
            stack.append(contentsOf: children[next] ?? [])
        }
        rebuild()
    }

    private func rebuild() {
        var result: [DOMRow] = []
        func visit(_ key: DOMKey, _ depth: Int) {
            guard result.count < DevToolsSession.maxDOMRows * 4 else { return }
            result.append(DOMRow(key: key, depth: depth, isClosing: false))
            guard expanded.contains(key), let list = children[key] else { return }
            for child in list { visit(child, depth + 1) }
            if nodes[key]?.isElement == true { result.append(DOMRow(key: key, depth: depth, isClosing: true)) }
        }
        if let root { visit(root, 0) }
        rows = result
    }

    private func domChanged(_ message: DevToolsMessage) {
        for node in DevToolsJSON.decode([DOMNode].self, from: message["updated"]) ?? [] {
            let key = DOMKey(frame: message.frame, handle: node.h)
            guard nodes[key] != nil else { continue }
            nodes[key] = node
            flash([key])
            if key == selected { revision += 1 }
        }
        for handle in DevToolsJSON.decode([Int].self, from: message["childList"]) ?? [] {
            let key = DOMKey(frame: message.frame, handle: handle)
            if children[key] != nil { Task { await loadChildren(key, flashNew: true) } }
        }
        rebuild()
    }

    private func flash(_ keys: [DOMKey]) {
        guard !keys.isEmpty else { return }
        flashing.formUnion(keys)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            flashing.subtract(keys)
        }
    }

    // MARK: - Selection, hover, picker

    func select(_ key: DOMKey?) {
        guard let key else { return }
        selected = key
        selectedHandles = Array(([key] + selectedHandles.filter { $0 != key }).prefix(5))
        revision += 1
    }

    /// Selects the next or previous visible row (↑/↓).
    func moveSelection(_ offset: Int) {
        let open = rows.filter { !$0.isClosing }
        guard let index = open.firstIndex(where: { $0.key == selected }) else { return select(open.first?.key) }
        let next = open[max(0, min(open.count - 1, index + offset))]
        select(next.key)
        scrollRequest += 1
    }

    /// ←: collapse, or go to the parent; →: expand, or go to the first child.
    func stepOut() {
        guard let key = selected else { return }
        if expanded.contains(key) { toggle(key) } else if let parent = parents[key] { select(parent); scrollRequest += 1 }
    }

    func stepIn() {
        guard let key = selected, isExpandable(key) else { return }
        if !expanded.contains(key) { toggle(key) } else if let first = children[key]?.first { select(first); scrollRequest += 1 }
    }

    func hover(_ key: DOMKey?) {
        guard let session, key != hovered else { return }
        if let old = hovered, old.frame != key?.frame {
            Task { _ = try? await session.call(frame: old.frame, "elements.highlight", args: ["handle": 0]) }
        }
        hovered = key
        guard let key else { return }
        Task { _ = try? await session.call(frame: key.frame, "elements.highlight", args: ["handle": key.handle]) }
    }

    /// ⇧⌘C: toggles picking in every frame; the frame clicked posts `picked`.
    func pick() {
        guard let session else { return }
        if isPicking { return stopPicking() }
        isPicking = true
        Task { _ = await session.callAll("elements.pick", args: ["on": true]) }
        // Esc while the panel, not the page, has focus.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.stopPicking() }
            return nil
        }
    }

    func stopPicking() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        guard isPicking, let session else { return }
        isPicking = false
        Task { _ = await session.callAll("elements.pick", args: ["on": false]) }
    }

    /// Expands the tree down to the node, through its frames, and selects it.
    func reveal(_ key: DOMKey) async {
        guard let session else { return }
        if root == nil { await load() }
        var chain: [[DOMKey]] = []
        var frame = key.frame, handle = key.handle
        while true {
            let path = DevToolsJSON.decode([DOMNode].self, from: try? await session.call(frame: frame, "elements.path", args: ["handle": handle])) ?? []
            guard !path.isEmpty else { return }
            chain.insert(path.map { node in
                let key = DOMKey(frame: frame, handle: node.h)
                if nodes[key] == nil { nodes[key] = node }
                return key
            }, at: 0)
            guard frame != session.topFrame, let info = session.frames[frame], let parent = info.parent, let element = info.element else { break }
            frame = parent
            handle = element
        }
        guard chain.first?.first == root else { return }
        for (index, keys) in chain.enumerated() {
            for ancestor in keys.dropLast() { await ensureExpanded(ancestor) }
            if index < chain.count - 1, let frameElement = keys.last { await ensureExpanded(frameElement) }
        }
        select(key)
        scrollRequest += 1
    }

    // MARK: - Search (text, CSS selector or XPath in every frame)

    func search() async {
        guard let session else { return }
        let query = searchQuery
        guard !query.isEmpty else { searchResults = []; return }
        var results: [DOMKey] = []
        let frames = session.frames.keys.sorted { a, b in (a == session.topFrame ? 0 : 1, a) < (b == session.topFrame ? 0 : 1, b) }
        for frame in frames {
            let handles = DevToolsJSON.decode([Int].self, from: try? await session.call(frame: frame, "elements.search", args: ["query": query])) ?? []
            results += handles.map { DOMKey(frame: frame, handle: $0) }
        }
        guard query == searchQuery else { return }
        searchResults = results
        searchIndex = 0
        if let first = results.first { await reveal(first) }
    }

    func nextResult(_ step: Int) async {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + step + searchResults.count) % searchResults.count
        await reveal(searchResults[searchIndex])
    }

    // MARK: - Calls

    /// Calls `elements.<name>` for a node; errors go to `error`.
    @discardableResult
    func call(_ key: DOMKey, _ name: String, _ args: [String: Any] = [:]) async -> Any? {
        guard let session else { return nil }
        do {
            return try await session.call(frame: key.frame, "elements." + name, args: args.merging(["handle": key.handle]) { a, _ in a })
        } catch {
            self.error = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            return nil
        }
    }

    /// An edit that changes what the side panes show.
    func edit(_ key: DOMKey, _ name: String, _ args: [String: Any] = [:]) {
        Task {
            await call(key, name, args)
            revision += 1
        }
    }

    // MARK: - Node actions

    func editAttribute(_ key: DOMKey, name: String?, text: String) {
        editing = nil
        edit(key, "editAttribute", ["name": name ?? "", "text": text])
    }

    func setText(_ key: DOMKey, _ value: String) {
        editing = nil
        edit(key, "setText", ["value": value])
    }

    func beginHTMLEdit(_ key: DOMKey) {
        Task {
            if let html = await call(key, "outerHTML") as? String { htmlEdit = HTMLEdit(key: key, text: html) }
        }
    }

    func commitHTMLEdit() {
        guard let htmlEdit else { return }
        self.htmlEdit = nil
        edit(htmlEdit.key, "setOuterHTML", ["html": htmlEdit.text])
    }

    func delete(_ key: DOMKey) {
        guard let node = nodes[key], node.t == 1 || node.t == 3 || node.t == 8 else { return }
        if selected == key {
            let open = rows.filter { !$0.isClosing }
            if let index = open.firstIndex(where: { $0.key == key }) {
                let next = open.dropFirst(index + 1).first { parents[$0.key] == parents[key] }?.key
                select(next ?? parents[key])
            }
        }
        edit(key, "remove")
    }

    func toggleHidden(_ key: DOMKey) { edit(key, "toggleHidden") }

    /// Reloads the side panes (after «Изменения» reverted something).
    func refresh() { revision += 1 }

    /// Drag and drop: before `target`, or as the last child when `target` is a closing tag.
    func move(_ dragged: DOMKey, to target: DOMRow) {
        guard dragged.frame == target.key.frame, dragged != target.key else { return }
        if target.isClosing {
            edit(dragged, "move", ["parent": target.key.handle, "before": 0])
        } else if let parent = parents[target.key] {
            edit(dragged, "move", ["parent": parent.handle, "before": target.key.handle])
        }
    }

    func copy(_ key: DOMKey, _ name: String) {
        Task {
            guard let text = await call(key, name) as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func scrollIntoView(_ key: DOMKey) {
        Task {
            await scrollFramesIntoView(key)
            await call(key, "scrollIntoView")
        }
    }

    private func scrollFramesIntoView(_ key: DOMKey) async {
        guard let session else { return }
        var frame = key.frame
        var elements: [DOMKey] = []
        while let info = session.frames[frame], let parent = info.parent, let element = info.element {
            elements.insert(DOMKey(frame: parent, handle: element), at: 0)
            frame = parent
        }
        for element in elements { await call(element, "scrollIntoView") }
    }

    func storeAsGlobal(_ key: DOMKey) {
        Task {
            if await call(key, "storeGlobal") != nil { session?.panel = .console }
        }
    }

    /// «Снимок узла»: the node's rect in the web view, through its frames, saved as PNG.
    func snapshot(_ key: DOMKey) {
        guard let session, let webView = session.webView else { return }
        struct Rect: Decodable { var x, y, width, height: Double }
        struct Point: Decodable { var x, y: Double }
        Task {
            await scrollFramesIntoView(key)
            await call(key, "scrollIntoView")
            guard var rect = DevToolsJSON.decode(Rect.self, from: await call(key, "rect")) else { return }
            var frame = key.frame
            while let info = session.frames[frame], let parent = info.parent, let element = info.element {
                guard let origin = DevToolsJSON.decode(Point.self, from: await call(DOMKey(frame: parent, handle: element), "frameOrigin")) else { return }
                rect.x += origin.x
                rect.y += origin.y
                frame = parent
            }
            let scale = webView.pageZoom * webView.magnification
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
                .intersection(webView.bounds)
            guard !configuration.rect.isEmpty else { error = "Узел не виден на странице"; return }
            do {
                let image = try await webView.takeSnapshot(configuration: configuration)
                save(image, name: nodes[key]?.n ?? "node")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save(_ image: NSImage, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(name.replacingOccurrences(of: "#", with: "")).png"
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        do { try png.write(to: url) } catch { self.error = error.localizedDescription }
    }

    // MARK: - Side pane data

    func styles(_ key: DOMKey) async -> StylesData? {
        DevToolsJSON.decode(StylesData.self, from: await call(key, "styles"))
    }

    func forceState(_ key: DOMKey, _ states: [String]) { edit(key, "forceState", ["states": states]) }

    func setClass(_ key: DOMKey, _ name: String, on: Bool) { edit(key, "setClass", ["name": name, "on": on]) }

    /// A call that names its objects itself (style rules, listeners), then a side-pane reload.
    func frameCall(_ frame: String, _ name: String, _ args: [String: Any]) {
        guard let session else { return }
        Task {
            do { _ = try await session.call(frame: frame, "elements." + name, args: args) } catch {
                self.error = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            }
            revision += 1
        }
    }
}
