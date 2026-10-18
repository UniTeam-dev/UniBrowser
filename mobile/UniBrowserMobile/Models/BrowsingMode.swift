import Foundation

/// The two ways the phone browses. Each mode has its own tabs, cookies and history.
enum BrowsingMode: String, CaseIterable, Identifiable, Codable {
    /// A normal browser: requests go straight from the phone.
    case direct
    /// Every request goes through the user's Mac and its network.
    case viaMac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Обычный"
        case .viaMac: "Через Mac"
        }
    }

    var systemImage: String {
        switch self {
        case .direct: "globe"
        case .viaMac: "laptopcomputer.and.iphone"
        }
    }
}
