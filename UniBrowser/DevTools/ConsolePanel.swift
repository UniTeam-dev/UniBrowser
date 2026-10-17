import SwiftUI

/// Panel «Консоль» (spec «Консоль»). Foundation version: `console` messages from every
/// frame as plain text rows.
@MainActor
@Observable
final class ConsoleModel {
    struct Entry: Identifiable {
        let id = UUID()
        let level: String
        let text: String
        /// The sending frame's URL.
        let source: String
    }

    private(set) var entries: [Entry] = []

    func bind(_ session: DevToolsSession) {
        session.on("console") { [weak self, weak session] message in
            let args = message["args"] as? [[String: Any]] ?? []
            let text = args.map { $0["text"] as? String ?? "" }.joined(separator: " ")
            let source = session?.frames[message.frame]?.url ?? ""
            self?.append(Entry(level: message["level"] as? String ?? "log", text: text, source: source))
        }
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > DevToolsSession.maxConsoleEntries {
            entries.removeFirst(entries.count - DevToolsSession.maxConsoleEntries)
        }
    }

    func clear() { entries.removeAll() }
}

struct ConsolePanel: View {
    let session: DevToolsSession

    var body: some View {
        ScrollViewReader { proxy in
            List(session.console.entries) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.text)
                        .foregroundStyle(color(entry.level))
                        .textSelection(.enabled)
                    Spacer()
                    Text(URL(string: entry.source)?.lastPathComponent ?? entry.source)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(entry.source)
                }
                .font(.system(size: 11, design: .monospaced))
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: session.console.entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": .red
        case "warn": .orange
        case "debug": .secondary
        default: .primary
        }
    }
}
