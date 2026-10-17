import AppKit
import SwiftUI

/// Panel «Изменения» (spec «Изменения»): every edit made from «Элементы», grouped by
/// resource (stylesheet or document), as a diff with «Отменить» and «Копировать».
/// The page script keeps the original state (`ub.trackChange`, #region changes).
@MainActor
@Observable
final class ChangesModel {
    struct Change: Identifiable {
        /// The page script's key, e.g. "rule:12", unique within its frame.
        let key: String
        let frame: String
        var resource: String
        var title: String
        var before: String
        var after: String
        var id: String { frame + "|" + key }
        var isCSS: Bool { key.hasPrefix("rule:") || key.hasPrefix("inline:") }
    }

    @ObservationIgnored private weak var session: DevToolsSession?
    /// In order of the first edit.
    private(set) var changes: [Change] = []
    var selectedResource: String?

    func bind(_ session: DevToolsSession) {
        self.session = session
        session.on("change") { [weak self] message in
            guard let self, let key = message["id"] as? String else { return }
            let id = message.frame + "|" + key
            if message["removed"] as? Bool == true {
                changes.removeAll { $0.id == id }
                return
            }
            let change = Change(
                key: key, frame: message.frame,
                resource: message["resource"] as? String ?? "",
                title: message["title"] as? String ?? "",
                before: String((message["before"] as? String ?? "").prefix(DevToolsSession.maxBodyBytes)),
                after: String((message["after"] as? String ?? "").prefix(DevToolsSession.maxBodyBytes))
            )
            if let index = changes.firstIndex(where: { $0.id == id }) { changes[index] = change } else { changes.append(change) }
            if selectedResource == nil { selectedResource = change.resource }
        }
        // Edits live in the page (CSSOM, DOM) and are gone after a reload.
        session.on("hello") { [weak self] message in
            if message["isTop"] as? Bool == true { self?.changes = [] }
        }
    }

    var resources: [String] {
        var seen = Set<String>()
        return changes.map(\.resource).filter { seen.insert($0).inserted }
    }

    func changes(in resource: String) -> [Change] { changes.filter { $0.resource == resource } }

    func revert(_ change: Change) {
        guard let session else { return }
        Task {
            _ = try? await session.call(frame: change.frame, "changes.revert", args: ["id": change.key])
            session.elements.refresh()
        }
    }

    func copy(_ changes: [Change]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(changes.map(\.after).filter { !$0.isEmpty }.joined(separator: "\n\n"), forType: .string)
    }
}

struct ChangesPanel: View {
    let session: DevToolsSession

    var body: some View {
        let model = session.changes
        if model.changes.isEmpty {
            Text("Здесь появятся правки, сделанные в панели «Элементы»: стили, атрибуты, текст, HTML, удалённые и перемещённые узлы.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.secondaryText)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                List(model.resources, id: \.self, selection: Binding(get: { model.selectedResource }, set: { model.selectedResource = $0 })) { resource in
                    HStack {
                        Text(Self.name(resource)).lineLimit(1).help(resource)
                        Spacer()
                        Text("\(model.changes(in: resource).count)").foregroundStyle(Palette.secondaryText).monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
                .frame(minWidth: 160, idealWidth: 220)
                detail(model)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    static func name(_ resource: String) -> String {
        let parts = resource.components(separatedBy: " — ")
        let url = URL(string: parts[0])
        let file = url?.lastPathComponent.isEmpty == false && url?.lastPathComponent != "/" ? url!.lastPathComponent : (url?.host() ?? parts[0])
        return ([file] + parts.dropFirst()).joined(separator: " — ")
    }

    @ViewBuilder private func detail(_ model: ChangesModel) -> some View {
        let resource = model.selectedResource.flatMap { model.resources.contains($0) ? $0 : nil } ?? model.resources.first
        if let resource {
            let list = model.changes(in: resource)
            VStack(spacing: 0) {
                HStack {
                    Text(resource).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Копировать всё") { model.copy(list) }
                    Button("Отменить всё") { list.reversed().forEach(model.revert) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 28)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(list) { change in entry(change, model) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func entry(_ change: ChangesModel.Change, _ model: ChangesModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(change.title).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer()
                Button("Отменить") { model.revert(change) }
                Button("Копировать") { model.copy([change]) }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            ForEach(Array(LineDiff.lines(change.before, change.after).enumerated()), id: \.offset) { _, line in
                Text((line.kind == .removed ? "- " : line.kind == .added ? "+ " : "  ") + line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(line.kind == .same ? Palette.secondaryText : Palette.text)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.kind == .removed ? Color.red.opacity(0.15) : line.kind == .added ? Color.green.opacity(0.15) : .clear)
                    .textSelection(.enabled)
            }
        }
    }
}
