import Foundation
import WebKit

/// Things every tab's web view shares: cookies and site data, the login-form
/// script, and the password provider.
@MainActor
final class WebEnvironment {
    weak var store: BrowserStore?
    /// A private window: cookies and storage in memory only, no session file, not mirrored
    /// to the iPhone. History recording must check this and record nothing.
    let isPrivate: Bool
    /// The common store: spaces without «Отдельные входы» and private windows.
    let dataStore: WKWebsiteDataStore
    /// Stores of spaces with separate logins, by store id; one object per store.
    private var separateStores: [UUID: WKWebsiteDataStore] = [:]
    let passwords: CredentialProvider
    let extensions: ExtensionManager
    /// Where finished page loads are recorded; nil records nothing (a private window).
    var history: HistoryStore?
    /// Per-site permissions and the ad-blocking allow list.
    let siteSettings: SiteSettingsStore
    /// ⌥+click on a link; AppModel shows the URL in Peek.
    var onPeek: ((URL) -> Void)?

    init(passwords: CredentialProvider, siteSettings: SiteSettingsStore, isPrivate: Bool = false) {
        self.passwords = passwords
        self.siteSettings = siteSettings
        self.isPrivate = isPrivate
        dataStore = isPrivate ? .nonPersistent() : .default()
        extensions = ExtensionManager(dataStore: dataStore)
        ContentBlocker.shared.prepare()
    }

    /// The cookies and site data a page in `spaceID` uses: the space's own store when it
    /// keeps separate logins, else the common one.
    func dataStore(forSpace spaceID: UUID?) -> WKWebsiteDataStore {
        guard !isPrivate, let space = store?.spaces.first(where: { $0.id == spaceID }), space.separateLogins == true
        else { return dataStore }
        let id = Space.loginStoreID(space.id, mode: "mac")
        if let existing = separateStores[id] { return existing }
        let new = WKWebsiteDataStore(forIdentifier: id)
        separateStores[id] = new
        return new
    }

    func dataStore(forTab tabID: UUID) -> WKWebsiteDataStore {
        dataStore(forSpace: store?.spaces.first { $0.allTabIDs.contains(tabID) }?.id)
    }

    /// Deletes a deleted space's own cookies and site data. Its tabs must be asleep by now.
    func removeSeparateStore(of spaceID: UUID) {
        guard !isPrivate else { return }
        let id = Space.loginStoreID(spaceID, mode: "mac")
        separateStores[id] = nil
        Task {
            // Retried: WebKit refuses while a just-closed web view still holds the store.
            for attempt in 1...5 {
                do { return try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    if attempt == 5 { print("UniBrowser: space store not removed: \(error)") }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// Settings «Удалить cookies и кэш»: the common store and every space's own.
    func eraseAllWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers {
            await (separateStores[id] ?? WKWebsiteDataStore(forIdentifier: id)).removeData(ofTypes: types, modifiedSince: .distantPast)
        }
    }

    /// User agent and inspector, no tab scripts: what Peek's temporary page uses.
    func makeBaseConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        WebInspector.enable(configuration)
        return configuration
    }

    func makeConfiguration(for controller: TabWebController, devTools: DevToolsSession, dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = makeBaseConfiguration(dataStore: dataStore)
        // Lets installed extensions inject content scripts into tabs.
        configuration.webExtensionController = extensions.controller

        let content = WKUserContentController()
        content.addUserScript(WKUserScript(
            source: LoginFormScript.source,
            injectionTime: .atDocumentEnd,
            // Many sites sign in inside an iframe (SSO widgets, embedded login forms).
            forMainFrameOnly: false,
            in: LoginFormScript.world
        ))
        content.add(WeakScriptHandler(controller), contentWorld: LoginFormScript.world, name: LoginFormScript.handlerName)
        // Developer tools: every frame, page world, buffering until the panel opens.
        if let script = DevToolsSession.script { content.addUserScript(script) }
        content.add(WeakScriptHandler(devTools), contentWorld: .page, name: DevToolsSession.handlerName)
        configuration.userContentController = content
        return configuration
    }
}

/// WKUserContentController retains its handlers; this breaks the
/// controller → web view → configuration → controller cycle.
@MainActor
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
