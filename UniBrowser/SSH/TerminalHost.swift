import AppKit
import SwiftTerm
import SwiftUI

/// An SSH tab's terminal. Owned by the tab with its session, so switching tabs keeps the screen.
final class SSHTerminalView: TerminalView {
    private weak var session: SSHSession?
    private let hostID: UUID

    init(session: SSHSession, hostID: UUID) {
        self.session = session
        self.hostID = hostID
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400),
                   font: .monospacedSystemFont(ofSize: Self.fontSize(for: hostID), weight: .regular))
        configureNativeColors()
        terminalDelegate = self
        session.onOutput = { [weak self] bytes in self?.feed(byteArray: bytes[...]) }
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
    }
}

extension SSHTerminalView: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) { session?.send(Array(data)) }

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
