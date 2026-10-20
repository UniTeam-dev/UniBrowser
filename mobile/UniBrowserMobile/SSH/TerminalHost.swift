import SwiftTerm
import SwiftUI
import UIKit

/// An SSH tab's terminal. Owned by the tab with its session, so switching tabs keeps the screen.
/// The keys and suggestions above the keyboard are one strip (`KeyStrip`), in place of SwiftTerm's own.
final class SSHTerminalView: TerminalView {
    private weak var session: SSHSession?
    private let suggestions: SuggestionEngine
    private var line = CommandLineModel()
    /// The server's command list is asked for once per connection, at its first output.
    private var commandsRequested = false
    private var update: Task<Void, Never>?
    let strip = KeyStripModel()

    init(session: SSHSession, suggestions: SuggestionEngine) {
        self.session = session
        self.suggestions = suggestions
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 600), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        terminalDelegate = self
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SSHTerminalView, _) in view.applyColors() }
        strip.showsSuggestions = suggestionsEnabled
        inputAccessoryView = KeyStripHost(terminal: self)
        session.onOutput = { [weak self] bytes in self?.received(bytes) }
        NotificationCenter.default.addObserver(self, selector: #selector(controlReset), name: .terminalViewControlModifierReset, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// Logs in (again) at the terminal's current size and starts the input line afresh.
    /// The session itself ignores it while connecting or connected.
    func connect() {
        guard let session else { return }
        switch session.state {
        case .failed, .closed: feed(text: "\r\n") // the new shell starts below the old screen
        default: break
        }
        let terminal = getTerminal()
        line = CommandLineModel()
        commandsRequested = false
        update?.cancel()
        strip.suggestions = []
        Task { await session.connect(cols: terminal.cols, rows: terminal.rows) }
    }

    /// The system text colors follow light/dark; SwiftTerm copies them once, so copy again.
    private func applyColors() {
        nativeForegroundColor = UIColor.label.resolvedColor(with: traitCollection)
        nativeBackgroundColor = UIColor.systemBackground.resolvedColor(with: traitCollection)
    }

    // MARK: - Strip keys

    /// Sticky: the next key typed goes with Ctrl, then it turns off by itself.
    func toggleControl() {
        controlModifier.toggle()
        strip.isControl = controlModifier
    }

    @objc private func controlReset() { strip.isControl = false }

    /// Esc, Tab: sent as they are. A sticky Ctrl is used up by them too, like by a typed key,
    /// rather than staying armed for the next letter.
    func sendKey(_ bytes: [UInt8]) {
        send(bytes)
        controlModifier = false
    }

    func sendArrow(_ arrow: KeyStripModel.Arrow) {
        let app = getTerminal().applicationCursor
        switch arrow {
        case .up: sendKey(app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
        case .down: sendKey(app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
        case .left: sendKey(app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
        case .right: sendKey(app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
        }
    }

    /// Tap on a suggestion: its missing suffix goes to the shell as keystrokes.
    func accept(_ suggestion: Suggestion) {
        controlModifier = false
        session?.send(Array(suggestion.insert.utf8))
        line.accepted(suggestion.insert)
        refreshSuggestions()
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

    private var suggestionsEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.terminalSuggestions) as? Bool ?? true
    }

    /// «Подсказки в терминале» turned off hides the strip's row at once. Posted on whichever thread changed a default.
    @objc nonisolated private func defaultsChanged() {
        Task { @MainActor [weak self] in
            guard let self, strip.showsSuggestions != suggestionsEnabled else { return }
            strip.showsSuggestions = suggestionsEnabled
            update?.cancel()
            strip.suggestions = []
            (inputAccessoryView as? KeyStripHost)?.fit()
            if isFirstResponder { reloadInputViews() }
        }
    }

    private func typed(_ bytes: [UInt8]) {
        for entered in line.typed(bytes) { suggestions.history.add(entered) }
        refreshSuggestions()
    }

    /// Clears the strip at once, and fills it 80 ms after typing stops (and the echo came back).
    private func refreshSuggestions() {
        update?.cancel()
        strip.suggestions = []
        guard line.showsSuggestions, suggestionsEnabled else { return }
        let model = line, cwd = session?.cwd
        update = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let list = await self?.suggestions.suggestions(for: model, cwd: cwd),
                  !Task.isCancelled, let self, line.showsSuggestions, line.line == model.line else { return }
            strip.suggestions = list
        }
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
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

    /// OSC 52 from the remote program.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        UIPasteboard.general.string = text
    }
}

/// Hosts the tab's terminal view, like `WebViewContainer` hosts its web view.
struct TerminalHost: UIViewRepresentable {
    let terminal: SSHTerminalView

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ container: UIView, context: Context) {
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(terminal)
    }
}
