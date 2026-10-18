import Foundation
import WebKit

/// Ad and tracker blocking: EasyList + EasyPrivacy, converted by scripts/make_blocklists.py
/// into Blocklists/blocklist-N.json, compiled once into WKContentRuleListStore (again only
/// when a list file changes) and added to every tab's page loads.
///
/// - Global switch: UserDefaults bool `adBlockEnabled` (`ContentBlocker.enabledKey`), missing
///   means on. Settings flip it; each tab picks it up on its next page load.
/// - Per-site allow («Блокировать рекламу на этом сайте» off): the tab loads that host's
///   pages without the lists. WebKit applies `ignore-previous-rules` only inside its own
///   list, so an allow rule would mean recompiling all 130k rules on every toggle; leaving
///   the lists out of that tab's loads has the same effect at once.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()
    static let enabledKey = "adBlockEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private(set) var lists: [WKContentRuleList] = []
    private var lookup: Task<Void, Never>?

    /// Finds the compiled lists (milliseconds); lists not compiled yet are compiled in
    /// the background and join later page loads. Await it before a tab's first load.
    @discardableResult
    func prepare() -> Task<Void, Never> {
        if let lookup { return lookup }
        let task = Task { await load() }
        lookup = task
        return task
    }

    /// Adds or removes the lists for a page load of `url`. `applied` is the tab's current
    /// state (number of lists added), so an unchanged tab isn't touched.
    func apply(to controller: WKUserContentController, url: URL?, settings: SiteSettingsStore, applied: inout Int) {
        let allowed = url?.host().map { settings.allowsAds(host: $0) } ?? false
        let wanted = Self.isEnabled && !allowed ? lists.count : 0
        guard wanted != applied else { return }
        controller.removeAllContentRuleLists()
        if wanted > 0 { lists.forEach(controller.add) }
        applied = wanted
    }

    private static var bundledLists: [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("blocklist-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Name plus size: a regenerated list gets a new identifier and is compiled again.
    private static func identifier(for file: URL) -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(file.deletingPathExtension().lastPathComponent)-\(size)"
    }

    private func load() async {
        guard let store = WKContentRuleListStore.default() else { return }
        let files = Self.bundledLists
        let identifiers = files.map(Self.identifier)
        // Lists compiled from an older build only take disk space.
        for old in await store.availableIdentifiers() ?? [] where old.hasPrefix("blocklist-") && !identifiers.contains(old) {
            try? await store.removeContentRuleList(forIdentifier: old)
        }
        var missing: [(URL, String)] = []
        for (file, identifier) in zip(files, identifiers) {
            if let list = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(list)
            } else {
                missing.append((file, identifier))
            }
        }
        guard !missing.isEmpty else { return }
        Task {
            for (file, identifier) in missing {
                guard let json = try? String(contentsOf: file, encoding: .utf8) else { continue }
                do {
                    if let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
                        lists.append(list)
                    }
                } catch {
                    print("ContentBlocker: \(file.lastPathComponent) did not compile: \(error)")
                }
            }
        }
    }
}
