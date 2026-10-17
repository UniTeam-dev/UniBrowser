import Foundation

/// The serialized browser session: spaces, tabs, selection and archive.
/// This is both the on-disk format (session.json) and the wire format mirrored
/// through iCloud, so the iOS app must encode/decode the same shape to sync.
struct SessionSnapshot: Codable {
    struct TabRecord: Codable {
        var id: UUID
        var url: URL?
        var title: String
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
