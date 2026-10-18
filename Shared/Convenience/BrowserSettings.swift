import SwiftUI
import Foundation

/// «Настройки» → «Поисковая система»: where a typed query that is not an address goes.
/// Kept in UserDefaults under `defaultsKey`, read by `url(fromInput:)` in both apps.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google, yandex, duckDuckGo, bing

    static let defaultsKey = "searchEngine"

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init) ?? .google
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .yandex: "Яндекс"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    /// Results page and the name of its query parameter.
    private var search: (base: String, parameter: String) {
        switch self {
        case .google: ("https://www.google.com/search", "q")
        case .yandex: ("https://yandex.ru/search/", "text")
        case .duckDuckGo: ("https://duckduckgo.com/", "q")
        case .bing: ("https://www.bing.com/search", "q")
        }
    }

    func searchURL(for query: String) -> URL {
        var components = URLComponents(string: search.base)!
        components.queryItems = [URLQueryItem(name: search.parameter, value: query)]
        return components.url!
    }

    /// The query when `url` is this engine's results page, so the address entry can say «Искать …».
    func query(in url: URL) -> String? {
        let base = URL(string: search.base)!
        guard url.host() == base.host(), url.path() == base.path() else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == search.parameter }?.value
    }

    /// The engine's suggest endpoint; all four answer in the OpenSearch format `["query", ["s1", …]]`.
    func suggestURL(for query: String) -> URL {
        let (base, parameter, extra): (String, String, [URLQueryItem]) = switch self {
        case .google: ("https://suggestqueries.google.com/complete/search", "q",
                       [.init(name: "client", value: "firefox"), .init(name: "ie", value: "utf-8"), .init(name: "oe", value: "utf-8")])
        case .yandex: ("https://suggest.yandex.ru/suggest-ff.cgi", "part", [.init(name: "uil", value: "ru")])
        case .duckDuckGo: ("https://duckduckgo.com/ac/", "q", [.init(name: "type", value: "list")])
        case .bing: ("https://api.bing.com/osjson.aspx", "query", [])
        }
        var components = URLComponents(string: base)!
        components.queryItems = extra + [URLQueryItem(name: parameter, value: query)]
        return components.url!
    }
}

/// Search suggestions in the Mac ⌘K palette and the iPhone address entry.
enum SearchSuggestions {
    /// «Подсказки поиска» switch; on unless turned off.
    static let enabledKey = "searchSuggestions"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The suggestions in an OpenSearch answer; [] for anything else.
    static func parse(_ data: Data) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any], array.count > 1,
              let items = array[1] as? [Any] else { return [] }
        return items.compactMap { $0 as? String }
    }

    /// Waits 150 ms first, so call it from `.task(id: query)`: typing cancels the wait and nothing is sent.
    /// Nothing is sent in private browsing (`isPrivate`), with the switch off, or for a typed URL.
    /// `session` lets the iPhone's via-Mac mode send the request through the Mac like its pages.
    static func fetch(_ query: String, isPrivate: Bool, session: URLSession = .shared) async -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPrivate, isEnabled, !query.isEmpty, !query.contains("://") else { return [] }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled,
              let (data, _) = try? await session.data(from: SearchEngine.current.suggestURL(for: query)),
              !Task.isCancelled
        else { return [] }
        return Array(parse(data).filter { $0.lowercased() != query.lowercased() }.prefix(6))
    }
}

/// «Стартовая страница»: an address ⌘T (Mac) or «+» (iPhone) opens; empty opens the address entry as before.
enum HomePage {
    static let key = "startPage"

    static var url: URL? {
        let text = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return nil }
        return URL(string: text.contains("://") ? text : "https://\(text)")
    }
}

/// Settings other parts read.
enum SettingsKeys {
    /// Days of history to keep; 0 keeps everything. Applied at launch by `pruneForRetentionSetting()`.
    static let historyRetentionDays = "historyRetentionDays"
    /// The content blocker's global switch (missing = on).
    static let adBlockingEnabled = "adBlockEnabled" // ContentBlocker.enabledKey
    static let readerFontSize = "readerFontSize"
    static let readerTheme = "readerTheme"
}

extension HistoryStore {
    /// Prunes to «Хранить историю» from the settings (90 days by default, 0 keeps everything).
    func pruneForRetentionSetting() {
        let days = UserDefaults.standard.object(forKey: SettingsKeys.historyRetentionDays) as? Int ?? 90
        if days > 0 { prune(olderThan: days) }
    }
}

/// «Очистить историю…» in both apps' settings: the same periods as the history screens.
struct ClearHistoryButton: View {
    let history: HistoryStore
    @State private var isAsking = false
    @State private var cleared = false

    var body: some View {
        Button(cleared ? "История очищена" : "Очистить историю…", role: .destructive) { isAsking = true }
            .disabled(cleared)
            .confirmationDialog("Очистить историю посещений?", isPresented: $isAsking) {
                Button("За последний час", role: .destructive) { clear(since: .now.addingTimeInterval(-3600)) }
                Button("За сегодня", role: .destructive) { clear(since: Calendar.current.startOfDay(for: .now)) }
                Button("За всё время", role: .destructive) { history.deleteAll(); cleared = true }
            }
    }

    private func clear(since date: Date) {
        history.delete(since: date)
        cleared = true
    }
}

/// Sites with a remembered permission or an ad-blocking exception, each resettable.
struct SitePermissionsSection: View {
    let settings: SiteSettingsStore

    var body: some View {
        Section("Разрешения сайтов") {
            if settings.sites.isEmpty {
                Text("Сайты ещё ничего не спрашивали.").foregroundStyle(.secondary)
            }
            ForEach(settings.sites.keys.sorted(), id: \.self) { host in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host)
                        Text(summary(settings.sites[host] ?? SitePermissions()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Сбросить") { settings.reset(host: host) }
                }
            }
        }
    }

    private func summary(_ site: SitePermissions) -> String {
        var parts = SitePermission.allCases.compactMap { permission -> String? in
            guard let decision = site.decisions[permission.rawValue] else { return nil }
            return "\(permission.title): \(decision.title.lowercased())"
        }
        if site.allowsAds { parts.append("реклама разрешена") }
        return parts.joined(separator: ", ")
    }
}
