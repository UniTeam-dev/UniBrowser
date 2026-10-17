import Foundation

/// The serialized browser session: spaces, tabs, selection and archive.
/// This is both the on-disk format (session.json) and the wire format of the
/// live mirror with the iPhone (Shared/ViaMac), which compiles this same file.
struct SessionSnapshot: Codable {
    struct TabRecord: Codable {
        var id: UUID
        var url: URL?
        var title: String
        /// The name the user gave the tab; nil shows the page title.
        var customTitle: String?
        var lastActivated: Date
    }

    var spaces: [Space]
    var activeSpaceID: UUID
    var tabs: [TabRecord]
    /// Optional so sessions saved before the archive existed still load.
    var archive: [ArchivedTab]?
    /// When this snapshot was produced; drives last-writer-wins across devices.
    var modifiedAt: Date?
    /// The device that produced it, so a device ignores the echo of its own push.
    var deviceID: String?
}
