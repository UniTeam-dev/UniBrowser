import SwiftUI

/// One problem on the page (spec «Проблемы»).
struct DevToolsIssue: Identifiable {
    enum Kind: String, CaseIterable {
        case csp, mixed, cookie, failed, label, autocomplete, deprecation, intervention

        var title: String {
            switch self {
            case .csp: "Политика безопасности контента (CSP)"
            case .mixed: "Смешанное содержимое"
            case .cookie: "Cookie"
            case .failed: "Ошибки загрузки"
            case .label: "Поля формы без меток"
            case .autocomplete: "Автозаполнение форм"
            case .deprecation: "Устаревшие API"
            case .intervention: "Вмешательства браузера"
            }
        }

        var symbol: String {
            switch self {
            case .csp, .mixed: "lock.trianglebadge.exclamationmark"
            case .cookie: "birthday.cake"
            case .failed: "xmark.octagon"
            case .label, .autocomplete: "character.cursor.ibeam"
            case .deprecation, .intervention: "clock.badge.exclamationmark"
            }
        }

        var color: Color {
            switch self {
            case .csp, .mixed, .failed: .red
            case .cookie, .deprecation, .intervention: .orange
            case .label, .autocomplete: .blue
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let text: String
    var detail: String?
    var url: String?
    /// Script location, for «Источники».
    var source: String?
    var line: Int?
    let frame: String
    /// Handle of the affected element in that frame.
    var element: Int?
    /// The failed request in «Сеть».
    var networkID: String?
}

/// Panel «Проблемы»: issues from every frame of the current page, plus failed requests
/// from «Сеть». Cleared when the main frame loads a new document.
@MainActor
@Observable
final class IssuesModel {
    private(set) var issues: [DevToolsIssue] = []
    var count: Int { issues.count }

    @ObservationIgnored private weak var session: DevToolsSession?
    @ObservationIgnored private var failedRequests: Set<String> = []

    private static let maxIssues = 1000

    func bind(_ session: DevToolsSession) {
        self.session = session
        session.on("hello") { [weak self] message in
            if message["isTop"] as? Bool == true { self?.clear() }
        }
        session.on("issue") { [weak self] message in
            guard let raw = message["kind"] as? String, let kind = DevToolsIssue.Kind(rawValue: raw),
                  let text = message["text"] as? String else { return }
            func string(_ key: String) -> String? { (message[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(10_000)) } }
            self?.append(DevToolsIssue(
                kind: kind, text: String(text.prefix(2000)), detail: string("detail"), url: string("url"), source: string("source"),
                line: (message["line"] as? NSNumber)?.intValue, frame: message.frame, element: (message["element"] as? NSNumber)?.intValue))
        }
        // Failed fetch/XHR/WebSocket loads (not the ones the panel itself blocked).
        session.on("network") { [weak self] message in
            guard let self, let error = message["error"] as? String, message["blocked"] as? Bool != true,
                  let id = message["id"] as? String, let url = message["url"] as? String else { return }
            let key = message.frame + ":" + id
            guard failedRequests.insert(key).inserted else { return }
            append(DevToolsIssue(kind: .failed, text: "Запрос не выполнен: \(error)", url: url, frame: message.frame, networkID: key))
        }
    }

    private func append(_ issue: DevToolsIssue) {
        guard issues.count < Self.maxIssues else { return }
        issues.append(issue)
    }

    func clear() {
        issues.removeAll()
        failedRequests.removeAll()
    }

    // MARK: - Links into other panels

    func showRequest(_ issue: DevToolsIssue) {
        guard let session else { return }
        let id = issue.networkID ?? session.network.entries.last { $0.url == issue.url }?.id
        guard let id else { return }
        session.network.selection = id
        session.panel = .network
    }

    func canShowRequest(_ issue: DevToolsIssue) -> Bool {
        guard let session else { return false }
        if let id = issue.networkID { return session.network.entry(id) != nil }
        return issue.url.map { url in session.network.entries.contains { $0.url == url } } ?? false
    }

    /// Opens Элементы and points at the element on the page.
    // ponytail: Элементы has no "select node by handle" call yet; when it does, select it
    // in the tree here too.
    func showElement(_ issue: DevToolsIssue) {
        guard let session, let element = issue.element else { return }
        session.panel = .elements
        Task { _ = try? await session.call(frame: issue.frame, "issues.reveal", args: ["handle": element]) }
    }

    func showSource(_ issue: DevToolsIssue) {
        session?.panel = .sources
    }
}

struct IssuesPanel: View {
    let session: DevToolsSession

    private var model: IssuesModel { session.issues }

    var body: some View {
        let groups = DevToolsIssue.Kind.allCases.compactMap { kind -> (DevToolsIssue.Kind, [DevToolsIssue])? in
            let items = model.issues.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
        VStack(spacing: 0) {
            HStack {
                Text(model.count == 0 ? "Проблем не найдено" : "Проблем: \(model.count)")
                    .foregroundStyle(Palette.secondaryText)
                Spacer()
                Button { model.clear() } label: { Image(systemName: "nosign") }
                    .buttonStyle(.borderless)
                    .help("Очистить")
                    .accessibilityLabel("Очистить")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            Divider()
            if groups.isEmpty {
                Text("На этой странице проблем пока нет.\nСюда попадают нарушения CSP, смешанное содержимое, ошибки загрузки, отклонённые cookie, поля форм без меток и устаревшие API.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.0) { kind, items in
                        Section {
                            ForEach(items) { IssueRow(issue: $0, model: model) }
                        } header: {
                            Label("\(kind.title) — \(items.count)", systemImage: kind.symbol)
                                .foregroundStyle(kind.color)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .font(.system(size: 12))
    }
}

private struct IssueRow: View {
    let issue: DevToolsIssue
    let model: IssuesModel
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(issue.text).textSelection(.enabled)
            if let url = issue.url {
                Text(url).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondaryText).lineLimit(2).textSelection(.enabled)
            }
            if let source = issue.source {
                Text(source + (issue.line.map { ":\($0)" } ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                if model.canShowRequest(issue) { Button("Показать в «Сети»") { model.showRequest(issue) } }
                if issue.element != nil { Button("Показать элемент") { model.showElement(issue) } }
                if issue.source != nil { Button("Открыть в «Источниках»") { model.showSource(issue) } }
                if issue.detail != nil { Button(isExpanded ? "Скрыть подробности" : "Подробности") { isExpanded.toggle() } }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            if isExpanded, let detail = issue.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.secondaryText)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
