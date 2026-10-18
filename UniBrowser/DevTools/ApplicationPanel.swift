import SwiftUI
import WebKit

/// Panel «Приложение» (spec «Приложение»): frames and their origins, the sidebar and the
/// app-level sections (manifest, service workers, storage overview, frames). Storage
/// sections are in `ApplicationStorage.swift`.
@MainActor
@Observable
final class ApplicationModel {
    enum Section: Hashable {
        case manifest, serviceWorkers, storage, frames
        case local(String), session(String), indexedDB(String), cache(String)
        /// By host: cookies belong to hosts, not origins.
        case cookies(String)
    }

    struct FrameInfo: Identifiable {
        let id: String
        let url: String
        let origin: String
        let title: String
        let secure: Bool
        let isolated: Bool
        let manifest: String?
        let parent: String?
        let isTop: Bool

        var host: String? { URL(string: url)?.host() }
    }

    var selection: Section? = .storage
    /// Every frame that answered `application.info`, the main frame first.
    private(set) var frames: [FrameInfo] = []
    /// Bumped on every refresh, so the open section reloads too.
    private(set) var generation = 0

    @ObservationIgnored private(set) weak var session: DevToolsSession?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func bind(_ session: DevToolsSession) {
        self.session = session
        // New documents (navigation, new iframes): reload once they settle.
        session.on("hello") { [weak self] _ in self?.scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard session?.isOpen == true else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let session else { return }
        let results = await session.callAll("application.info")
        frames = results.compactMap { id, value -> FrameInfo? in
            guard let info = value as? [String: Any] else { return nil }
            return FrameInfo(
                id: id,
                url: info["url"] as? String ?? "",
                origin: info["origin"] as? String ?? "null",
                title: info["title"] as? String ?? "",
                secure: info["secure"] as? Bool ?? false,
                isolated: info["isolated"] as? Bool ?? false,
                manifest: info["manifest"] as? String,
                parent: session.frames[id]?.parent,
                isTop: id == session.topFrame
            )
        }
        .sorted { ($0.isTop ? 0 : 1, $0.url) < ($1.isTop ? 0 : 1, $1.url) }
        generation += 1
    }

    /// Distinct origins of the frames, main frame first; opaque ones ("null") have no storage.
    var origins: [String] {
        var seen = Set<String>()
        return frames.map(\.origin).filter { $0 != "null" && seen.insert($0).inserted }
    }

    var hosts: [String] {
        var seen = Set<String>()
        return frames.compactMap(\.host).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// A frame of that origin, to run storage calls in.
    func frame(origin: String) -> String? { frames.first { $0.origin == origin }?.id }

    var top: FrameInfo? { frames.first(where: \.isTop) }

    /// `session.call` with the error as text, for the views.
    func call(_ frame: String?, _ name: String, _ args: [String: Any] = [:]) async -> Result<Any?, CallFailure> {
        guard let session, let frame else { return .failure(CallFailure(message: "Фрейм недоступен")) }
        do {
            return .success(try await session.call(frame: frame, name, args: args))
        } catch {
            return .failure(CallFailure(message: (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription))
        }
    }

    struct CallFailure: Error { let message: String }
}

struct ApplicationPanel: View {
    let session: DevToolsSession

    var body: some View {
        let model = session.application
        HStack(spacing: 0) {
            sidebar(model)
                .frame(width: 190)
            Divider()
            detail(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 12))
        .task { await model.refresh() }
    }

    private func sidebar(_ model: ApplicationModel) -> some View {
        typealias Item = ApplicationModel.Section
        @Bindable var model = model
        return VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section("Приложение") {
                    Label("Манифест", systemImage: "doc.text").tag(Item.manifest)
                    Label("Service workers", systemImage: "gearshape.2").tag(Item.serviceWorkers)
                    Label("Хранилище", systemImage: "internaldrive").tag(Item.storage)
                    Label("Фреймы", systemImage: "rectangle.3.group").tag(Item.frames)
                }
                Section("Local storage") {
                    ForEach(model.origins, id: \.self) { Text($0).lineLimit(1).tag(Item.local($0)) }
                }
                Section("Session storage") {
                    ForEach(model.origins, id: \.self) { Text($0).lineLimit(1).tag(Item.session($0)) }
                }
                Section("IndexedDB") {
                    ForEach(model.origins, id: \.self) { Text($0).lineLimit(1).tag(Item.indexedDB($0)) }
                }
                Section("Cookies") {
                    ForEach(model.hosts, id: \.self) { Text($0).lineLimit(1).tag(Item.cookies($0)) }
                }
                Section("Cache Storage") {
                    ForEach(model.origins, id: \.self) { Text($0).lineLimit(1).tag(Item.cache($0)) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden) // the sidebar material shows the desktop through the panel
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            HStack {
                Button { Task { await model.refresh() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(6)
        }
    }

    @ViewBuilder private func detail(_ model: ApplicationModel) -> some View {
        switch model.selection {
        case .manifest: ManifestView(model: model)
        case .serviceWorkers: ServiceWorkersView(model: model)
        case .storage, nil: StorageOverview(model: model)
        case .frames: FramesView(model: model)
        case .local(let origin): WebStorageView(model: model, kind: "local", origin: origin)
        case .session(let origin): WebStorageView(model: model, kind: "session", origin: origin)
        case .indexedDB(let origin): IndexedDBView(model: model, origin: origin)
        case .cookies(let host): CookiesView(model: model, host: host)
        case .cache(let origin): CacheStorageView(model: model, origin: origin)
        }
    }
}

// MARK: - Shared bits

/// The row of controls above a section's content.
struct ApplicationBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 30)
        Divider()
    }
}

struct ApplicationMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Int {
    var bytes: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) }
}

// MARK: - Manifest

/// The main frame's `<link rel="manifest">`, fetched natively (no page CSP, not in Сеть).
private struct ManifestView: View {
    let model: ApplicationModel
    @State private var json: [String: Any]?
    @State private var raw = ""
    @State private var status = "Загрузка…"

    private static let fields = ["name", "short_name", "description", "id", "start_url", "scope", "display", "orientation", "theme_color", "background_color", "lang", "dir"]

    var body: some View {
        Group {
            if let json {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.top?.manifest ?? "").foregroundStyle(.secondary).textSelection(.enabled)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(Self.fields.filter { json[$0] != nil }, id: \.self) { key in
                                GridRow {
                                    Text(key).foregroundStyle(.secondary)
                                    HStack {
                                        if key.hasSuffix("_color"), let hex = json[key] as? String, hex.hasPrefix("#") {
                                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: hex)).frame(width: 14, height: 14)
                                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.2)))
                                        }
                                        Text(String(describing: json[key]!)).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if let icons = json["icons"] as? [[String: Any]], !icons.isEmpty {
                            Text("Значки").font(.headline)
                            ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in
                                HStack {
                                    AsyncImage(url: iconURL(icon["src"] as? String)) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: { Color.primary.opacity(0.06) }
                                        .frame(width: 48, height: 48)
                                    VStack(alignment: .leading) {
                                        Text(icon["src"] as? String ?? "").textSelection(.enabled)
                                        Text([icon["sizes"], icon["type"], icon["purpose"]].compactMap { $0 as? String }.joined(separator: " · "))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Text("JSON").font(.headline)
                        Text(raw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ApplicationMessage(text: status)
            }
        }
        .task(id: model.generation) { await load() }
    }

    private func iconURL(_ src: String?) -> URL? {
        guard let src, let base = model.top?.manifest.flatMap(URL.init(string:)) else { return nil }
        return URL(string: src, relativeTo: base)?.absoluteURL
    }

    private func load() async {
        json = nil
        guard let top = model.top else { status = "Страница не загружена"; return }
        guard let link = top.manifest, let url = URL(string: link) else {
            status = "У страницы нет манифеста (<link rel=\"manifest\">)"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                status = "Манифест не является JSON-объектом"
                return
            }
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            raw = String(decoding: pretty, as: UTF8.self)
            json = object
        } catch {
            status = "Не удалось загрузить \(link): \(error.localizedDescription)"
        }
    }
}

// MARK: - Service workers

private struct ServiceWorkersView: View {
    let model: ApplicationModel
    @State private var registrations: [Registration] = []
    @State private var status: String?

    struct Registration: Identifiable {
        let frame: String
        let origin: String
        let scope: String
        let workers: [(String, String, String)] // role, script, state
        let updateViaCache: String
        var id: String { scope }
    }

    var body: some View {
        VStack(spacing: 0) {
            ApplicationBar {
                Button { Task { await load() } } label: { Label("Обновить список", systemImage: "arrow.clockwise") }
                Spacer()
                if let status { Text(status).foregroundStyle(.secondary).lineLimit(1) }
            }
            if registrations.isEmpty {
                ApplicationMessage(text: "Нет зарегистрированных service worker")
            } else {
                List(registrations) { registration in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(registration.scope).font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                            Spacer()
                            Button("Обновить") { act("application.update", registration, done: "Проверка обновления запущена") }
                            Button("Отменить регистрацию") { act("application.unregister", registration, done: "Регистрация отменена") }
                        }
                        ForEach(registration.workers, id: \.0) { role, script, state in
                            Text("\(role): \(script) — \(state)").foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("updateViaCache: \(registration.updateViaCache)").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
        }
        .task(id: model.generation) { await load() }
    }

    private func act(_ name: String, _ registration: Registration, done: String) {
        Task {
            switch await model.call(registration.frame, name, ["scope": registration.scope]) {
            case .success: status = done
            case .failure(let failure): status = failure.message
            }
            await load()
        }
    }

    private func load() async {
        var result: [Registration] = []
        for origin in model.origins {
            let frame = model.frame(origin: origin)
            guard case .success(let value) = await model.call(frame, "application.serviceWorkers"),
                  let list = value as? [[String: Any]], let frame else { continue }
            for item in list {
                let workers = ["installing", "waiting", "active"].compactMap { role -> (String, String, String)? in
                    guard let worker = item[role] as? [String: Any] else { return nil }
                    return (role, worker["scriptURL"] as? String ?? "", worker["state"] as? String ?? "")
                }
                result.append(Registration(
                    frame: frame,
                    origin: origin,
                    scope: item["scope"] as? String ?? "",
                    workers: workers,
                    updateViaCache: item["updateViaCache"] as? String ?? ""
                ))
            }
        }
        registrations = result
    }
}

// MARK: - Storage overview

private struct StorageOverview: View {
    let model: ApplicationModel
    @State private var estimates: [(origin: String, usage: Int, quota: Int, persisted: Bool?)] = []
    @State private var status: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(estimates, id: \.origin) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.origin).font(.system(size: 12, weight: .semibold))
                        ProgressView(value: Double(item.usage), total: Double(max(item.quota, 1)))
                        Text("Использовано \(item.usage.bytes) из \(item.quota.bytes)")
                            .foregroundStyle(.secondary)
                        Text(item.persisted.map { $0 ? "Постоянное хранилище (persisted)" : "Хранилище может быть очищено браузером" } ?? "persisted() недоступен")
                            .foregroundStyle(.secondary)
                    }
                }
                if estimates.isEmpty {
                    Text("navigator.storage недоступен в этих фреймах").foregroundStyle(.secondary)
                }
                Divider()
                if let host = model.top?.host {
                    Button("Очистить данные сайта \(host)") { Task { await clear(host) } }
                    Text("Удаляет cookies, хранилища, IndexedDB, кэши и service workers этого сайта из WKWebsiteDataStore.")
                        .foregroundStyle(.secondary)
                }
                if let status { Text(status) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.generation) { await load() }
    }

    private func load() async {
        var result: [(String, Int, Int, Bool?)] = []
        for origin in model.origins {
            guard case .success(let value) = await model.call(model.frame(origin: origin), "application.estimate"),
                  let estimate = value as? [String: Any] else { continue }
            result.append((origin, estimate["usage"] as? Int ?? 0, estimate["quota"] as? Int ?? 0, estimate["persisted"] as? Bool))
        }
        estimates = result
    }

    /// Data records are per registrable domain («example.com», «127.0.0.1»).
    private func clear(_ host: String) async {
        guard let store = model.session?.webView?.configuration.websiteDataStore else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter {
            host == $0.displayName || host.hasSuffix("." + $0.displayName)
        }
        await store.removeData(ofTypes: types, for: records)
        status = records.isEmpty ? "Данных сайта не найдено" : "Удалено: " + records.map(\.displayName).joined(separator: ", ")
        await model.refresh()
    }
}

// MARK: - Frames

private struct FramesView: View {
    let model: ApplicationModel

    struct Node: Identifiable {
        let info: ApplicationModel.FrameInfo
        let children: [Node]?
        var id: String { info.id }
    }

    private var roots: [Node] {
        let ids = Set(model.frames.map(\.id))
        func node(_ info: ApplicationModel.FrameInfo) -> Node {
            let children = model.frames.filter { $0.parent == info.id }.map(node)
            return Node(info: info, children: children.isEmpty ? nil : children)
        }
        // Frames whose parent is unknown (not linked yet) show at the top level.
        return model.frames.filter { $0.parent.map { !ids.contains($0) } ?? true }.map(node)
    }

    var body: some View {
        List(roots, children: \.children) { node in
            let info = node.info
            VStack(alignment: .leading, spacing: 2) {
                Text(info.isTop ? "top" : (info.title.isEmpty ? "iframe" : info.title))
                    .font(.system(size: 12, weight: .semibold))
                Text(info.url).textSelection(.enabled).lineLimit(2)
                HStack(spacing: 12) {
                    Text("Источник: \(info.origin)")
                    Label(info.secure ? "Безопасный контекст" : "Небезопасный контекст",
                          systemImage: info.secure ? "lock.fill" : "lock.open")
                    Label(info.isolated ? "Межсайтовая изоляция" : "Без межсайтовой изоляции",
                          systemImage: info.isolated ? "checkmark.shield" : "shield.slash")
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .overlay { if model.frames.isEmpty { ApplicationMessage(text: "Нет фреймов") } }
    }
}
