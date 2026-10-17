import CloudKit
import Foundation
import Observation
import Security

/// Mirrors the session through the user's private iCloud database: one record
/// holds the whole snapshot as a JSON asset. Last writer wins by `modifiedAt`.
///
/// It needs the app signed with an iCloud/CloudKit entitlement and the user
/// signed into iCloud; without that it stays `.unavailable` and the app runs
/// purely local. Convergence is on change (push) and on launch/activate (pull);
/// real-time push via CKSubscription is a later step.
@MainActor
@Observable
final class SyncService {
    enum Status: Equatable {
        case disabled, unavailable, syncing, ok
        case error(String)

        var label: String {
            switch self {
            case .disabled: "Синхронизация выключена"
            case .unavailable: "iCloud недоступен"
            case .syncing: "Синхронизация…"
            case .ok: "Синхронизировано через iCloud"
            case .error(let message): "Ошибка синхронизации: \(message)"
            }
        }
    }

    private(set) var status: Status = .disabled

    /// Called on the main actor with a newer snapshot from another device.
    var onRemote: ((SessionSnapshot) -> Void)?

    private let containerIdentifier: String
    private let recordID = CKRecord.ID(recordName: "session")
    private let recordType = "Session"
    private let assetKey = "snapshot"
    /// Created only once the entitlement is confirmed; touching CloudKit without it
    /// raises an uncatchable ObjC exception, so an unsigned build must never reach it.
    @ObservationIgnored private var database: CKDatabase?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pending: SessionSnapshot?
    /// The last record we saw, so we overwrite the right version.
    @ObservationIgnored private var knownRecord: CKRecord?

    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    /// True when this binary is signed with the iCloud container entitlement.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) != nil
    }

    /// Checks the iCloud account and does the first pull. Safe to call when offline or unsigned.
    func start() async {
        guard Self.isEntitled else { status = .unavailable; return }
        let container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else { self.status = .unavailable; return }
            self.status = .syncing
            await pull()
        } catch {
            status = .unavailable
        }
    }

    /// Queues a push; bursts of local edits collapse into one upload.
    func push(_ snapshot: SessionSnapshot) {
        guard status != .disabled, status != .unavailable else { return }
        pending = snapshot
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let snapshot = self.pending else { return }
            await self.upload(snapshot)
        }
    }

    /// Fetches the remote snapshot and hands a newer one to `onRemote`.
    func pull() async {
        guard let database, status != .disabled, status != .unavailable else { return }
        do {
            let record = try await database.record(for: recordID)
            knownRecord = record
            if let snapshot = Self.decode(record, assetKey: assetKey) {
                onRemote?(snapshot)
            }
            status = .ok
        } catch let error as CKError where error.code == .unknownItem {
            status = .ok // nothing synced yet
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func upload(_ snapshot: SessionSnapshot) async {
        guard let database, let data = try? JSONEncoder().encode(snapshot) else { return }
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString).json")
        do {
            try data.write(to: fileURL)
            let record = knownRecord ?? CKRecord(recordType: recordType, recordID: recordID)
            record[assetKey] = CKAsset(fileURL: fileURL)
            record["modifiedAt"] = (snapshot.modifiedAt ?? .now) as NSDate
            let saved = try await database.save(record)
            knownRecord = saved
            status = .ok
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Another device wrote first: take theirs, then let the next edit re-push.
            knownRecord = error.serverRecord
            if let server = error.serverRecord, let snapshot = Self.decode(server, assetKey: assetKey) {
                onRemote?(snapshot)
            }
            status = .ok
        } catch {
            status = .error(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func decode(_ record: CKRecord, assetKey: String) -> SessionSnapshot? {
        guard let asset = record[assetKey] as? CKAsset, let url = asset.fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
