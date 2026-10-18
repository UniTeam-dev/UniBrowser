import Foundation

/// The ways the phone browses. Each mode has its own tabs, cookies and history.
enum BrowsingMode: String, CaseIterable, Identifiable, Codable {
    /// A normal browser: requests go straight from the phone.
    case direct
    /// Every request goes through the user's Mac and its network.
    case viaMac
    /// Like `direct`, but cookies and storage live in memory, nothing is saved or synced,
    /// no history is recorded, and the tabs close when the user leaves the mode.
    case `private`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Обычный"
        case .viaMac: "Через Mac"
        case .private: "Приватный"
        }
    }

    var systemImage: String {
        switch self {
        case .direct: "globe"
        case .viaMac: "laptopcomputer.and.iphone"
        case .private: "hand.raised"
        }
    }
}
