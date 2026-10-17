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
    /// Pinned tiles at the top of the sidebar.
    var pinnedTabIDs: [UUID] = []
    var groups: [TabGroup] = []
    /// Tabs under "Сегодня", newest last.
    var looseTabIDs: [UUID] = []
    var selectedTabID: UUID?

    var allTabIDs: [UUID] {
        pinnedTabIDs + groups.flatMap(\.tabIDs) + looseTabIDs
    }

    var color: Color { Color(hex: colorHex) }
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

enum Palette {
    static let sidebar = Color(hex: "#E8E8EC")
    static let secondaryText = Color(hex: "#5E5E63")
    static let accent = Color(hex: "#2563C9")
    static let spaceColors = ["#2563C9", "#E8833A", "#2E9E5B", "#6B4FD8", "#D93F2B"]
}
