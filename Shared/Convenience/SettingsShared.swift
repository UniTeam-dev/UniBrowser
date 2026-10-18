import SwiftUI

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
