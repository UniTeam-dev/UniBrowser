import Citadel
import Foundation
import NIO
import Observation

struct SFTPEntry: Identifiable, Hashable, Sendable {
    var name: String
    var path: String
    /// For a symlink: whether its target is a directory.
    var isDirectory: Bool
    var isSymlink: Bool
    var size: UInt64
    var modified: Date?
    /// `st_mode`: the type bits and the permission bits.
    var permissions: UInt32
    var id: String { path }
}

enum ConflictChoice: Sendable { case replace, keepBoth, skip }

/// The «Файлы» panel's model: one remote folder of an SSH tab, the file actions, and the tab's transfers.
@MainActor
@Observable
final class SFTPBrowser {
    private(set) var path = ""
    /// Folders first, then by name; dot files only with `showHidden`.
    var entries: [SFTPEntry] { showHidden ? all : all.filter { !$0.name.hasPrefix(".") } }
    var showHidden = false
    /// Follows the terminal's cwd until the user opens a folder themselves.
    var followsTerminal = true
    private(set) var error: String?
    let transfers: TransferQueue

    private var all: [SFTPEntry] = []
    @ObservationIgnored private let session: SSHSession
    /// Bumped by every load; a load that finds it changed is stale and drops its result.
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private var cache: [String: (at: Date, entries: [SFTPEntry])] = [:]

    nonisolated static let editorLimit: UInt64 = 5 * 1024 * 1024

    init(session: SSHSession) {
        self.session = session
        transfers = TransferQueue(session: session)
        transfers.onUploaded = { [weak self] dir in
            guard let self else { return }
            cache[dir] = nil
            if dir == path { Task { await self.reload() } }
        }
    }

    /// Navigating by hand stops following the terminal.
    func open(_ path: String) async {
        followsTerminal = false
        await load(Self.join(self.path.isEmpty ? "/" : self.path, path))
    }

    /// «↧ папка терминала»: back to the terminal's cwd, and keep following it.
    func followTerminal() async {
        followsTerminal = true
        guard let cwd = session.cwd else { return }
        await load(cwd)
    }

    func reload() async {
        guard !path.isEmpty else { return await followTerminal() }
        await load(path)
    }

    /// A failed listing keeps the folder shown before it, with `error` set.
    private func load(_ path: String) async {
        loads += 1
        let mine = loads
        do {
            let entries = try await fetch(path)
            cache[path] = (.now, entries)
            guard mine == loads else { return }
            self.path = path
            all = entries
            error = nil
        } catch {
            guard mine == loads else { return }
            if self.path.isEmpty { self.path = path }
            self.error = Self.message(for: error)
        }
    }

    /// For suggestions: up to 10 s old.
    func listing(_ dir: String) async throws -> [SFTPEntry] {
        if let hit = cache[dir], Date.now.timeIntervalSince(hit.at) < 10 { return hit.entries }
        let entries = try await fetch(dir)
        cache[dir] = (.now, entries)
        return entries
    }

    func makeDirectory(_ name: String) async throws {
        try await session.sftp().createDirectory(atPath: Self.join(path, try Self.checked(name)))
        await changed()
    }

    func rename(_ entry: SFTPEntry, to name: String) async throws {
        let target = Self.join(Self.parent(entry.path), try Self.checked(name))
        try await session.sftp().rename(at: entry.path, to: target)
        await changed()
    }

    /// Folders go with everything in them; a symlink is removed itself, never what it points to.
    func delete(_ entries: [SFTPEntry]) async throws {
        let client = try await session.sftp()
        do {
            for entry in entries { try await remove(entry, client) }
        } catch {
            await changed()
            throw error
        }
        await changed()
    }

    /// What `delete` removes: the entries and everything inside the folders among them.
    func countForDelete(_ entries: [SFTPEntry]) async throws -> Int {
        var count = 0
        for entry in entries {
            count += 1
            if entry.isDirectory, !entry.isSymlink { count += try await countForDelete(fetch(entry.path)) }
        }
        return count
    }

    func chmod(_ entry: SFTPEntry, _ mode: UInt32) async throws {
        var attributes = SFTPFileAttributes.none
        attributes.permissions = mode & 0o7777
        try await session.sftp().setAttributes(at: entry.path, to: attributes)
        await changed()
    }

    /// Nil for files over 5 MB or not UTF-8: those only offer download.
    func readText(_ entry: SFTPEntry) async throws -> String? {
        guard entry.size <= Self.editorLimit else { return nil }
        return try await Self.readText(entry.path, client: session.sftp())
    }

    /// Through `RemoteSwap`: keeps the original's permissions, and a symlink stays a link to the updated file.
    func writeText(_ text: String, to entry: SFTPEntry) async throws {
        try await RemoteSwap.write(entry.path, client: session.sftp()) { file in
            try await file.write(ByteBuffer(string: text))
        }
        await changed()
    }

    // MARK: - SFTP

    private func changed() async {
        cache = [:]
        await reload()
    }

    private func fetch(_ dir: String) async throws -> [SFTPEntry] {
        let client = try await session.sftp()
        var entries: [SFTPEntry] = []
        for component in try await client.listDirectory(atPath: dir).flatMap(\.components) {
            guard component.filename != ".", component.filename != ".." else { continue }
            let attributes = component.attributes
            let mode = attributes.permissions ?? 0
            let path = Self.join(dir, component.filename)
            let isSymlink = mode & 0o170000 == 0o120000
            var isDirectory = mode & 0o170000 == 0o040000
            if isSymlink, let target = try? await client.getAttributes(at: path) {
                isDirectory = (target.permissions ?? 0) & 0o170000 == 0o040000
            }
            entries.append(SFTPEntry(name: component.filename, path: path, isDirectory: isDirectory, isSymlink: isSymlink,
                                     size: attributes.size ?? 0, modified: attributes.accessModificationTime?.modificationTime,
                                     permissions: mode))
        }
        return entries.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func remove(_ entry: SFTPEntry, _ client: SFTPClient) async throws {
        guard entry.isDirectory, !entry.isSymlink else { return try await client.remove(at: entry.path) }
        for child in try await fetch(entry.path) { try await remove(child, client) }
        try await client.rmdir(at: entry.path)
    }

    nonisolated private static func readText(_ path: String, client: SFTPClient) async throws -> String? {
        let buffer = try await client.withFile(filePath: path, flags: .read) { file in
            var buffer = ByteBuffer()
            while buffer.readableBytes <= editorLimit {
                var chunk = try await file.read(from: UInt64(buffer.readableBytes), length: TransferQueue.chunk)
                if chunk.readableBytes == 0 { break }
                buffer.writeBuffer(&chunk)
            }
            return buffer
        }
        guard buffer.readableBytes <= editorLimit else { return nil }
        return String(bytes: buffer.readableBytesView, encoding: .utf8)
    }

    // MARK: - Paths and errors

    /// POSIX: `name` relative to `base` unless absolute; `.` and `..` resolved; the root stays `/`.
    nonisolated static func join(_ base: String, _ name: String) -> String {
        var parts: [Substring] = []
        for part in (name.hasPrefix("/") ? name : base + "/" + name).split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    nonisolated static func parent(_ path: String) -> String { join(path, "..") }

    /// A name for one path component.
    nonisolated static func checked(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw SFTPFailure("Недопустимое имя") }
        return name
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case let error as SFTPMessage.Status: error.message.isEmpty ? "ошибка сервера (\(error.errorCode))" : error.message
        case let error as SFTPError: if case .errorStatus(let status) = error { status.message } else { "нет соединения с сервером" }
        case let error as SFTPFailure: error.message
        case is SSHClientError, is ChannelError: "нет соединения с сервером"
        default: error.localizedDescription
        }
    }
}

struct SFTPFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Writes a remote file so that a whole copy always exists: the new content goes to `<name>.unibrowser-tmp`
/// (created with the original's mode), the original moves to `<name>.unibrowser-old`, the temp file takes the
/// name, and the old copy is removed. A missing original is a plain create. A symlink is resolved first, so the
/// file it points to is replaced and the link stays a link. An error or cancel before the swap removes only the
/// temp file; one in the middle of it puts the original back, or names where both copies are.
enum RemoteSwap {
    enum Step: Sendable { case tempWritten, originalMoved }
    /// For checks: runs after each step; throwing fails the write there.
    @TaskLocal static var hook: (@Sendable (Step) async throws -> Void)?

    static func write(_ path: String, client: SFTPClient, _ fill: @escaping @Sendable (SFTPFile) async throws -> Void) async throws {
        let target = (try? await client.getRealPath(atPath: path)) ?? path
        let old = target + ".unibrowser-old"
        let name = { (path: String) in (path as NSString).lastPathComponent }
        func exists(_ path: String) async -> Bool { (try? await client.getAttributes(at: path)) != nil }

        var original = try? await client.getAttributes(at: target)
        /// Why a leftover `.old` stayed; told only if the write then fails.
        var note: String?
        if original == nil, await exists(old) {
            // An earlier save dropped after moving the original away: put it back first.
            try await client.rename(at: old, to: target)
            original = try await client.getAttributes(at: target)
        } else if original != nil, let leftover = try? await client.getAttributes(at: old) {
            // Left by an earlier save that finished; the target is whole. Only a plain file is ever removed.
            if isRegularFile(leftover) {
                do { try await client.remove(at: old) } catch { note = "не удалось убрать \(name(old)): \(SFTPBrowser.message(for: error))" }
            } else {
                note = "\(name(old)) — не обычный файл, оставлен как есть"
            }
        }
        if let original, !isRegularFile(original) {
            let kind = (original.permissions ?? 0) & 0o170000 == 0o040000 ? "папка; заменить её файлом нельзя" : "не обычный файл"
            throw SFTPFailure("«\(name(target))» — \(kind)")
        }
        do {
            try await swap(target, original: original, client: client, fill)
        } catch let error where note != nil {
            throw SFTPFailure("\(SFTPBrowser.message(for: error)); \(note!)")
        }
    }

    private static func isRegularFile(_ attributes: SFTPFileAttributes) -> Bool {
        (attributes.permissions ?? 0) & 0o170000 == 0o100000
    }

    private static func swap(_ target: String, original: SFTPFileAttributes?, client: SFTPClient,
                             _ fill: @escaping @Sendable (SFTPFile) async throws -> Void) async throws {
        let temp = target + ".unibrowser-tmp", old = target + ".unibrowser-old"
        var attributes = SFTPFileAttributes.none
        let mode = original?.permissions.map { $0 & 0o7777 }
        if let mode {
            attributes.permissions = mode
            // The target is whole, so a leftover temp is never the last copy; O_TRUNC would keep its mode.
            try? await client.remove(at: temp)
        }
        do {
            try await client.withFile(filePath: temp, flags: [.write, .create, .truncate], attributes: attributes, fill)
            try await hook?(.tempWritten)
        } catch {
            try? await client.remove(at: temp)
            throw error
        }
        guard original != nil else {
            do {
                try await client.rename(at: temp, to: target)
            } catch {
                try? await client.remove(at: temp)
                throw error
            }
            return
        }
        do {
            try await client.rename(at: target, to: old)
        } catch {
            try? await client.remove(at: temp)
            throw error
        }
        do {
            try await hook?(.originalMoved)
            try await client.rename(at: temp, to: target)
        } catch {
            if (try? await client.rename(at: old, to: target)) != nil {
                try? await client.remove(at: temp)
                throw error
            }
            let name = { (path: String) in (path as NSString).lastPathComponent }
            throw SFTPFailure("\(SFTPBrowser.message(for: error)); прежняя версия сохранена как \(name(old)), новая — как \(name(temp))")
        }
        if let mode {
            // The server's umask may have narrowed the mode at create (never widened it).
            var restore = SFTPFileAttributes.none
            restore.permissions = mode
            try? await client.setAttributes(at: target, to: restore)
        }
        try? await client.remove(at: old) // a leftover goes with the next save
    }
}

/// The tab's uploads and downloads, one at a time.
@MainActor
@Observable
final class TransferQueue {
    enum Direction: Sendable { case upload, download }
    enum State: Equatable, Sendable { case queued, running, done, failed(String), cancelled }

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var direction: Direction
        var bytesDone: UInt64 = 0
        var bytesTotal: UInt64 = 0
        /// Over the last ~2 s.
        var bytesPerSecond: Double = 0
        var state = State.queued
    }

    /// A name clash waiting for «Заменить / Оставить оба / Пропустить». Any panel of the tab shows it.
    final class Clash: Identifiable {
        let name: String
        /// The existing one is a folder: only «Оставить оба» and «Пропустить» make sense.
        let isFolder: Bool
        private var continuation: CheckedContinuation<ConflictChoice, Never>?

        init(name: String, isFolder: Bool, continuation: CheckedContinuation<ConflictChoice, Never>) {
            self.name = name
            self.isFolder = isFolder
            self.continuation = continuation
        }

        /// Once; later calls do nothing.
        fileprivate func answer(_ choice: ConflictChoice) {
            continuation?.resume(returning: choice)
            continuation = nil
        }

        /// A clash nobody answered never holds up the queue.
        deinit { continuation?.resume(returning: .skip) }
    }

    private(set) var items: [Item] = []
    private(set) var clash: Clash?
    /// After an upload finishes: its remote folder.
    @ObservationIgnored var onUploaded: ((String) -> Void)?

    nonisolated static let chunk: UInt32 = 32 * 1024

    private enum Job {
        /// `remote` nil until a name clash is settled, then kept so «Повторить» doesn't ask again.
        case upload(local: URL, dir: String, remote: String?, conflict: (String) async -> ConflictChoice)
        case download(remote: String, dir: URL)
    }

    @ObservationIgnored private let session: SSHSession
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    @ObservationIgnored private var running: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var samples: [(at: Date, bytes: UInt64)] = []
    @ObservationIgnored private var shown = Date.distantPast
    /// What `resolve` found under the clashing name, for the `ask` it is about to cause.
    @ObservationIgnored private var clashIsFolder = false

    init(session: SSHSession) { self.session = session }

    func upload(_ local: URL, to remoteDir: String, conflict: @escaping (String) async -> ConflictChoice) {
        add(Item(name: Self.remoteName(local), direction: .upload), .upload(local: local, dir: remoteDir, remote: nil, conflict: conflict))
    }

    func download(_ entry: SFTPEntry, to localDir: URL) {
        add(Item(name: entry.name, direction: .download, bytesTotal: entry.size), .download(remote: entry.path, dir: localDir))
    }

    /// The panel's `conflict` for `upload`: shows the clash until `answer`, the transfer's cancel, or the queue's end.
    func ask(_ name: String) async -> ConflictChoice {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                clash?.answer(.skip)
                clash = Clash(name: name, isFolder: clashIsFolder, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(.skip) }
        }
    }

    func answer(_ choice: ConflictChoice) {
        let pending = clash
        clash = nil
        pending?.answer(choice)
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .queued: items[index].state = .cancelled
        case .running: running?.task.cancel()
        default: break
        }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .failed, .cancelled:
            items[index].state = .queued
            items[index].bytesDone = 0
            pump()
        default: break
        }
    }

    /// Takes finished, failed and cancelled ones off the list.
    func clear() {
        items.removeAll { $0.state != .queued && $0.state != .running }
        let kept = Set(items.map(\.id))
        jobs = jobs.filter { kept.contains($0.key) }
    }

    private func add(_ item: Item, _ job: Job) {
        items.append(item)
        jobs[item.id] = job
        pump()
    }

    private func pump() {
        guard running == nil, let item = items.first(where: { $0.state == .queued }) else { return }
        let id = item.id
        update(id) { $0.state = .running; $0.bytesPerSecond = 0 }
        samples = []
        shown = .distantPast
        running = (id, Task { [weak self] in
            await self?.run(id)
            self?.running = nil
            self?.pump()
        })
    }

    private func run(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        let progress: @Sendable (UInt64) async -> Void = { [weak self] done in await self?.progress(id, done) }
        var partial: URL?
        let client: SFTPClient
        do {
            client = try await session.sftp()
        } catch {
            update(id) { $0.state = .failed(SFTPBrowser.message(for: error)) }
            return
        }
        do {
            switch job {
            case .upload(let local, let dir, let resolved, let conflict):
                let remote: String
                if let resolved {
                    remote = resolved
                } else {
                    guard let target = try await resolve(Self.remoteName(local), in: dir, client: client, conflict: conflict) else {
                        if Task.isCancelled {
                            update(id) { $0.state = .cancelled }
                        } else {
                            items.removeAll { $0.id == id }
                            jobs[id] = nil
                        }
                        return
                    }
                    remote = target
                    jobs[id] = .upload(local: local, dir: dir, remote: remote, conflict: conflict)
                    update(id) { $0.name = (remote as NSString).lastPathComponent }
                }
                let total = (try FileManager.default.attributesOfItem(atPath: local.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value ?? 0
                update(id) { $0.bytesTotal = total }
                let sent = try await Self.upload(local, to: remote, client: client, progress: progress)
                update(id) { $0.bytesDone = sent }
                onUploaded?(dir)
            case .download(let remote, let dir):
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = Downloads.uniqueFileURL(in: dir, suggested: (remote as NSString).lastPathComponent) {
                    FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                }
                guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else {
                    throw SFTPFailure("Не удалось создать файл в \(dir.lastPathComponent)")
                }
                partial = file
                update(id) { $0.name = file.lastPathComponent }
                let total = try await client.getAttributes(at: remote).size ?? 0
                update(id) { $0.bytesTotal = total }
                let received = try await Self.download(remote, to: file, client: client, progress: progress)
                update(id) { $0.bytesDone = received }
                Downloads.quarantine(file, source: nil)
            }
            update(id) { $0.state = .done; $0.bytesPerSecond = 0 }
        } catch {
            if let partial { try? FileManager.default.removeItem(at: partial) }
            let cancelled = error is CancellationError || Task.isCancelled
            update(id) { $0.state = cancelled ? .cancelled : .failed(SFTPBrowser.message(for: error)); $0.bytesPerSecond = 0 }
        }
    }

    /// macOS hands out decomposed names (й as и + ˘); Linux tools expect the composed form.
    private static func remoteName(_ local: URL) -> String { local.lastPathComponent.precomposedStringWithCanonicalMapping }

    /// The remote path to write, or nil to skip. «Оставить оба» → «name 2.ext», «name 3.ext»…
    private func resolve(_ name: String, in dir: String, client: SFTPClient, conflict: (String) async -> ConflictChoice) async throws -> String? {
        func exists(_ path: String) async -> Bool { (try? await client.getAttributes(at: path)) != nil }
        let target = SFTPBrowser.join(dir, name)
        guard let existing = try? await client.getAttributes(at: target) else { return target }
        clashIsFolder = (existing.permissions ?? 0) & 0o170000 == 0o040000
        switch await conflict(name) {
        case .replace: return target
        case .skip: return nil
        case .keepBoth:
            for n in 2... {
                let candidate = SFTPBrowser.join(dir, Self.numbered(name, n))
                if await !exists(candidate) { return candidate }
            }
            return nil
        }
    }

    /// «a.txt» → «a 2.txt»; «a.tar.gz» → «a 2.tar.gz».
    nonisolated static func numbered(_ name: String, _ n: Int) -> String {
        let suffix = [".tar.gz", ".tar.bz2", ".tar.xz"].first { name.lowercased().hasSuffix($0) && name.count > $0.count }
            ?? ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension)
        return "\(name.dropLast(suffix.count)) \(n)\(name.suffix(suffix.count))"
    }

    /// Shown at most 10 times a second; the speed is over the last ~2 s.
    private func progress(_ id: UUID, _ done: UInt64) {
        let now = Date.now
        samples.append((now, done))
        samples.removeAll { now.timeIntervalSince($0.at) > 2 }
        guard now.timeIntervalSince(shown) >= 0.1 else { return }
        shown = now
        let speed = samples.count > 1 ? Double(done - samples[0].bytes) / now.timeIntervalSince(samples[0].at) : 0
        update(id) { $0.bytesDone = done; $0.bytesPerSecond = speed }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // Off the main actor, 32 KiB at a time; cancelling the task stops after the current chunk. Both return the bytes moved.

    /// Through `RemoteSwap`: a cancelled or dropped upload leaves the remote original as it was.
    nonisolated private static func upload(_ local: URL, to remote: String, client: SFTPClient, progress: @escaping @Sendable (UInt64) async -> Void) async throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let sent = OffsetBox()
        try await RemoteSwap.write(remote, client: client) { file in
            var offset: UInt64 = 0
            while let data = try handle.read(upToCount: Int(chunk)), !data.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                await progress(offset)
            }
            sent.value = offset
        }
        return sent.value
    }

    nonisolated private static func download(_ remote: String, to local: URL, client: SFTPClient, progress: @escaping @Sendable (UInt64) async -> Void) async throws -> UInt64 {
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        return try await client.withFile(filePath: remote, flags: .read) { file in
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await file.read(from: offset, length: chunk)
                if chunk.readableBytes == 0 { break }
                try handle.write(contentsOf: chunk.readableBytesView)
                offset += UInt64(chunk.readableBytes)
                await progress(offset)
            }
            return offset
        }
    }
}

/// Carries the byte count out of `RemoteSwap.write`'s fill closure, which runs before `write` returns.
private final class OffsetBox: @unchecked Sendable {
    var value: UInt64 = 0
}
