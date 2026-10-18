import CryptoKit
import Foundation
import SwiftUI

/// A folder of tabs in the sidebar ("Релиз 1.2"). A sleeping group keeps its
/// tabs but none of them hold a web view.
struct TabGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var tabIDs: [UUID] = []
    var isExpanded = true
    var isAsleep = false
}

/// A space ("Работа", "Личное") is a separate set of pinned tabs, groups and loose tabs.
struct Space: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String
    /// Small JPEG/PNG (≤128 px) shown instead of the colour; nil means use the colour.
    var imageData: Data?
    /// Pinned tiles at the top of the sidebar.
    var pinnedTabIDs: [UUID] = []
    var groups: [TabGroup] = []
    /// Tabs under "Сегодня", newest last.
    var looseTabIDs: [UUID] = []
    var selectedTabID: UUID?
    /// Two tabs shown side by side; nil when the space has no split.
    var split: SplitPair?
    /// «Отдельные входы»: the space keeps its own cookies and site data. Nil in sessions
    /// saved before the setting existed, until `migrateSeparateLogins` fills it in.
    var separateLogins: Bool? = true

    var allTabIDs: [UUID] {
        pinnedTabIDs + groups.flatMap(\.tabIDs) + looseTabIDs
    }

    var color: Color { Color(hex: colorHex) }

    /// The WKWebsiteDataStore identifier of a space with separate logins: SHA-256 of
    /// "<space id>|<mode>" with its halves XORed. `mode` is "mac" on the Mac and the
    /// browsing mode on the iPhone, so the phone's two modes never share a store.
    static func loginStoreID(_ spaceID: UUID, mode: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(spaceID.uuidString)|\(mode)".utf8)))
        return NSUUID(uuidBytes: (0..<16).map { digest[$0] ^ digest[$0 + 16] }) as UUID
    }

    /// Sessions from before «Отдельные входы»: the first space keeps the current logins
    /// (shared), every other space gets its own.
    static func migrateSeparateLogins(_ spaces: inout [Space]) {
        for i in spaces.indices where spaces[i].separateLogins == nil { spaces[i].separateLogins = i > 0 }
    }
}

/// Split View: `left` and `right` tab IDs and the left pane's share of the width.
struct SplitPair: Codable, Hashable {
    var left: UUID
    var right: UUID
    var fraction: Double = 0.5

    func contains(_ id: UUID) -> Bool { left == id || right == id }
}

/// A tab removed by cleanup; found again through ⌘K or the archive list.
struct ArchivedTab: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL?
    var title: String
    var archivedAt: Date
    /// The space it was closed in, where ⇧⌘T puts it back; nil for older entries.
    var spaceID: UUID?
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Color {
    /// Resolves to `light` or `dark` by the appearance of the view it is drawn in.
    init(light: String, dark: String) {
        #if os(macOS)
        let light = NSColor(Color(hex: light)), dark = NSColor(Color(hex: dark))
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
        #else
        let light = UIColor(Color(hex: light)), dark = UIColor(Color(hex: dark))
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #endif
    }
}

enum Palette {
    static let sidebar = Color(light: "#E8E8EC", dark: "#1C1C1F")
    static let secondaryText = Color(light: "#5E5E63", dark: "#A1A1A6")
    static let text = Color(light: "#1D1D1F", dark: "#F2F2F5")
    /// Cards, the selected tab row, popovers.
    static let surface = Color(light: "#FFFFFF", dark: "#2C2C30")
    static let surfaceAlt = Color(light: "#F2F2F5", dark: "#232326")
    static let dimmed = Color(light: "#C7C7CC", dark: "#48484A")
    static let accent = Color(hex: "#2563C9")
    static let spaceColors = ["#2563C9", "#E8833A", "#2E9E5B", "#6B4FD8", "#D93F2B"]
}
