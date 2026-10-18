import Foundation
import Observation

/// What a site may use. iPhone shows only camera and microphone: WebKit asks for
/// geolocation itself there and has no web notifications.
enum SitePermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera, microphone, geolocation, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "Камера"
        case .microphone: "Микрофон"
        case .geolocation: "Геопозиция"
        case .notifications: "Уведомления"
        }
    }

    /// «Сайт хочет использовать …»
    var accusative: String {
        switch self {
        case .camera: "камеру"
        case .microphone: "микрофон"
        case .geolocation: "вашу геопозицию"
        case .notifications: "уведомления"
        }
    }
}

enum SiteDecision: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, allow, deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Спрашивать"
        case .allow: "Разрешить"
        case .deny: "Запретить"
        }
    }
}

/// One host's choices, as saved in site-permissions.json.
struct SitePermissions: Codable, Equatable, Sendable {
    /// SitePermission.rawValue → decision; a missing key is «Спрашивать».
    var decisions: [String: SiteDecision] = [:]
    /// «Блокировать рекламу на этом сайте» switched off.
    var allowsAds = false
}

/// Per-host permission decisions and the ad-blocking allow list. The private window
/// and the iPhone's private mode get a copy that never reaches the disk.
@MainActor
@Observable
final class SiteSettingsStore {
    private(set) var sites: [String: SitePermissions]
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        sites = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: SitePermissions].self, from: $0) } ?? [:]
    }

    /// Application Support/UniBrowser/site-permissions.json.
    static func persistent() -> SiteSettingsStore {
        let dir = URL.applicationSupportDirectory.appending(path: "UniBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SiteSettingsStore(fileURL: dir.appending(path: "site-permissions.json"))
    }

    /// Starts from the saved choices; whatever changes stays in memory.
    func privateCopy() -> SiteSettingsStore {
        let copy = SiteSettingsStore(fileURL: nil)
        copy.sites = sites
        return copy
    }

    static func key(_ host: String) -> String { host.lowercased() }

    func decision(_ permission: SitePermission, host: String) -> SiteDecision {
        sites[Self.key(host)]?.decisions[permission.rawValue] ?? .ask
    }

    func set(_ decision: SiteDecision, for permission: SitePermission, host: String) {
        update(host) { $0.decisions[permission.rawValue] = decision == .ask ? nil : decision }
    }

    func allowsAds(host: String) -> Bool {
        sites[Self.key(host)]?.allowsAds ?? false
    }

    func setAllowsAds(_ allows: Bool, host: String) {
        update(host) { $0.allowsAds = allows }
    }

    private func update(_ host: String, _ change: (inout SitePermissions) -> Void) {
        let key = Self.key(host)
        var site = sites[key] ?? SitePermissions()
        change(&site)
        sites[key] = site == SitePermissions() ? nil : site
        guard let fileURL, let data = try? JSONEncoder().encode(sites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The stored answer for all of `permissions`, or the user's answer from the prompt bar
    /// that `present` shows. Any «Запретить» wins; «Разрешить» needs every one allowed.
    func resolve(_ permissions: [SitePermission], host: String, present: (PermissionRequest) -> Void) async -> Bool {
        let decisions = permissions.map { decision($0, host: host) }
        if decisions.contains(.deny) { return false }
        if decisions.allSatisfy({ $0 == .allow }) { return true }
        let request = PermissionRequest(host: host, permissions: permissions)
        let allowed = await withCheckedContinuation { continuation in
            request.continuation = continuation
            present(request)
        }
        if request.remember {
            for permission in permissions { set(allowed ? .allow : .deny, for: permission, host: host) }
        }
        return allowed
    }
}

/// A site asking for camera, microphone, geolocation or notifications; the page waits
/// until `answer` is called. The tab answers «no» if it navigates away or sleeps first.
@MainActor
@Observable
final class PermissionRequest: Identifiable {
    let host: String
    let permissions: [SitePermission]
    var remember = true
    @ObservationIgnored fileprivate var continuation: CheckedContinuation<Bool, Never>?

    init(host: String, permissions: [SitePermission]) {
        self.host = host
        self.permissions = permissions
    }

    var text: String {
        "\(host) хочет использовать " + permissions.map(\.accusative).joined(separator: " и ")
    }

    func answer(_ allowed: Bool) {
        continuation?.resume(returning: allowed)
        continuation = nil
    }

    /// The page went away before the user answered: «no», and nothing is remembered.
    func cancel() {
        remember = false
        answer(false)
    }
}
