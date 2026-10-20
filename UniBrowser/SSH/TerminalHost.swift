import AppKit
import SwiftTerm
import SwiftUI

/// An SSH tab's terminal. Owned by the tab with its session, so switching tabs keeps the screen.
final class SSHTerminalView: TerminalView {
    private weak var session: SSHSession?
    private let hostID: UUID
    private let suggestions: SuggestionEngine
    private var line = CommandLineModel()
    /// The server's command list is asked for once per connection, at its first output.
    private var commandsRequested = false
    private var update: Task<Void, Never>?
    private var popup: NSHostingView<SuggestionPopup>?
    private var shown: [Suggestion] = []
    private var selected = 0
    /// Installed only while the popup shows, so hidden it never takes a key.
    private var keyMonitor: Any?

    init(session: SSHSession, hostID: UUID, suggestions: SuggestionEngine) {
        self.session = session
        self.hostID = hostID
        self.suggestions = suggestions
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400),
                   font: .monospacedSystemFont(ofSize: Self.fontSize(for: hostID), weight: .regular))
        configureNativeColors()
        terminalDelegate = self
        session.onOutput = { [weak self] bytes in self?.received(bytes) }
    }

    required init?(coder: NSCoder) { nil }

    /// Logs in (again) at the terminal's current size; does nothing while connecting or connected.
    func connect() {
        guard let session else { return }
        switch session.state {
        case .failed, .closed: feed(text: "\r\n") // the new shell starts below the old screen
        default: break
        }
        let terminal = getTerminal()
        line = CommandLineModel()
        commandsRequested = false
        hideSuggestions()
        Task { await session.connect(cols: terminal.cols, rows: terminal.rows) }
    }

    /// The system text colors follow light/dark; SwiftTerm copies them once, so copy again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureNativeColors()
    }

    // MARK: - Font size (⌘+ / ⌘− / ⌘0, per host)

    static let defaultFontSize: CGFloat = 13

    private static func key(_ hostID: UUID) -> String { "ssh.fontSize.\(hostID.uuidString.lowercased())" }

    static func fontSize(for hostID: UUID) -> CGFloat {
        let saved = UserDefaults.standard.double(forKey: key(hostID))
        return saved > 0 ? saved : defaultFontSize
    }

    /// `up` nil resets to 13 pt.
    static func zoom(_ hostID: UUID, up: Bool?) {
        let size = up.map { min(max(fontSize(for: hostID) + ($0 ? 1 : -1), 8), 36) } ?? defaultFontSize
        UserDefaults.standard.set(size, forKey: key(hostID))
    }

    func applyFontSize() {
        font = .monospacedSystemFont(ofSize: Self.fontSize(for: hostID), weight: .regular)
        hideSuggestions()
    }

    // MARK: - Suggestions

    private func received(_ bytes: [UInt8]) {
        feed(byteArray: bytes[...])
        if !commandsRequested {
            commandsRequested = true
            Task { await suggestions.loadCommands() }
        }
        let showed = line.showsSuggestions
        line.isAlternateScreen = getTerminal().isCurrentBufferAlternate
        line.echoed(bytes)
        if line.showsSuggestions != showed { refreshSuggestions() }
    }

    private func typed(_ bytes: [UInt8]) {
        for entered in line.typed(bytes) { suggestions.history.add(entered) }
        refreshSuggestions()
    }

    /// Hides the list at once, and shows the new one 80 ms after typing stops (and the echo came back).
    private func refreshSuggestions() {
        update?.cancel()
        hideSuggestions()
        guard line.showsSuggestions, UserDefaults.standard.object(forKey: SettingsKeys.terminalSuggestions) as? Bool ?? true else { return }
        let model = line, cwd = session?.cwd
        update = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let list = await self?.suggestions.suggestions(for: model, cwd: cwd),
                  !Task.isCancelled, let self, line.showsSuggestions, line.line == model.line else { return }
            showSuggestions(list)
        }
    }

    private func showSuggestions(_ list: [Suggestion]) {
        guard !list.isEmpty else { return hideSuggestions() }
        shown = list
        selected = 0
        let view = popup ?? NSHostingView(rootView: popupContent)
        view.rootView = popupContent
        if popup == nil {
            popup = view
            addSubview(view)
        }
        // SwiftTerm's cell: its `cellDimension` is internal, so measured the way it does.
        let cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let cellWidth = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cursor = getTerminal().getCursorLocation()
        let fitting = view.fittingSize
        let size = CGSize(width: min(fitting.width, 480), height: fitting.height)
        // Not flipped: row 0 is at the top. Below the cursor's row, or above it when there's no room.
        var y = bounds.height - cellHeight * CGFloat(cursor.y + 1) - size.height
        if y < 0 { y = bounds.height - cellHeight * CGFloat(cursor.y) }
        let x = max(0, min(CGFloat(cursor.x) * cellWidth, bounds.width - size.width))
        view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event) ?? event
            }
        }
    }

    private var popupContent: SuggestionPopup {
        SuggestionPopup(suggestions: shown, selected: selected, fontSize: max(font.pointSize - 1, 9))
    }

    private func hideSuggestions() {
        popup?.removeFromSuperview()
        popup = nil
        shown = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// ↑/↓ move, Tab or → accept, Esc hides. Anything else, or a key with a modifier, goes to the shell.
    /// The popup only shows for a line we followed key by key, so the cursor is at its end and → can accept.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard !shown.isEmpty, event.window === window, window?.firstResponder === self,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else { return event }
        switch event.keyCode {
        case 126: selected = (selected + shown.count - 1) % shown.count
        case 125: selected = (selected + 1) % shown.count
        case 48, 124:
            let insert = shown[selected].insert
            session?.send(Array(insert.utf8))
            line.accepted(insert)
            refreshSuggestions()
            return nil
        case 53:
            update?.cancel()
            hideSuggestions()
            return nil
        default: return event
        }
        popup?.rootView = popupContent
        return nil
    }
}

extension SSHTerminalView: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(Array(data))
        typed(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session?.resize(cols: newCols, rows: newRows) }

    /// OSC 7 sends `file://host/path`.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.scheme == "file" {
            session?.setCwd(url.path(percentEncoded: false))
        } else {
            session?.setCwd(directory)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52 from the remote program.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Hosts the tab's terminal view, like `WebViewContainer` hosts its web view.
struct TerminalHost: NSViewRepresentable {
    let terminal: SSHTerminalView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { container.window?.makeFirstResponder(terminal) }
    }
}
