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
        do {
            let entries = try await fetch(path)
            cache[path] = (.now, entries)
            self.path = path
            all = entries
            error = nil
        } catch {
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

    /// Writes `<name>.unibrowser-tmp` and renames it over the original, keeping the original's permissions.
    func writeText(_ text: String, to entry: SFTPEntry) async throws {
        try await Self.writeText(text, to: entry.path, client: session.sftp())
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

    nonisolated private static func writeText(_ text: String, to path: String, client: SFTPClient) async throws {
        let mode = try await client.getAttributes(at: path).permissions
        let temp = path + ".unibrowser-tmp"
        do {
            try await client.withFile(filePath: temp, flags: [.write, .create, .truncate]) { file in
                try await file.write(ByteBuffer(string: text))
            }
            do {
                try await client.rename(at: temp, to: path)
            } catch is SFTPMessage.Status {
                // SFTP v3 rename doesn't replace an existing file.
                try await client.remove(at: path)
                try await client.rename(at: temp, to: path)
            }
        } catch {
            try? await client.remove(at: temp)
            throw error
        }
        if let mode {
            var attributes = SFTPFileAttributes.none
            attributes.permissions = mode & 0o7777
            try await client.setAttributes(at: path, to: attributes)
        }
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

    private(set) var items: [Item] = []
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

    init(session: SSHSession) { self.session = session }

    func upload(_ local: URL, to remoteDir: String, conflict: @escaping (String) async -> ConflictChoice) {
        add(Item(name: Self.remoteName(local), direction: .upload), .upload(local: local, dir: remoteDir, remote: nil, conflict: conflict))
    }

    func download(_ entry: SFTPEntry, to localDir: URL) {
        add(Item(name: entry.name, direction: .download, bytesTotal: entry.size), .download(remote: entry.path, dir: localDir))
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
        running = (id, Task { [weak self] in
            await self?.run(id)
            self?.running = nil
            self?.pump()
        })
    }

    private func run(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        let progress: @Sendable (UInt64) async -> Void = { [weak self] done in await self?.progress(id, done) }
        var partial: URL?, partialRemote: String?
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
                        items.removeAll { $0.id == id }
                        jobs[id] = nil
                        return
                    }
                    remote = target
                    jobs[id] = .upload(local: local, dir: dir, remote: remote, conflict: conflict)
                    update(id) { $0.name = (remote as NSString).lastPathComponent }
                }
                let total = (try FileManager.default.attributesOfItem(atPath: local.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value ?? 0
                update(id) { $0.bytesTotal = total }
                partialRemote = remote
                try await Self.upload(local, to: remote, client: client, progress: progress)
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
                try await Self.download(remote, to: file, client: client, progress: progress)
                Downloads.quarantine(file, source: nil)
            }
            update(id) { $0.state = .done; $0.bytesPerSecond = 0 }
        } catch {
            if let partial { try? FileManager.default.removeItem(at: partial) }
            let cancelled = error is CancellationError || Task.isCancelled
            // A cancelled upload leaves nothing half-written; after a dropped connection the server can't be asked.
            if cancelled, let partialRemote { try? await client.remove(at: partialRemote) }
            update(id) { $0.state = cancelled ? .cancelled : .failed(SFTPBrowser.message(for: error)); $0.bytesPerSecond = 0 }
        }
    }

    /// macOS hands out decomposed names (й as и + ˘); Linux tools expect the composed form.
    private static func remoteName(_ local: URL) -> String { local.lastPathComponent.precomposedStringWithCanonicalMapping }

    /// The remote path to write, or nil to skip. «Оставить оба» → «name 2.ext», «name 3.ext»…
    private func resolve(_ name: String, in dir: String, client: SFTPClient, conflict: (String) async -> ConflictChoice) async throws -> String? {
        func exists(_ path: String) async -> Bool { (try? await client.getAttributes(at: path)) != nil }
        let target = SFTPBrowser.join(dir, name)
        guard await exists(target) else { return target }
        switch await conflict(name) {
        case .replace: return target
        case .skip: return nil
        case .keepBoth:
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            for n in 2... {
                let candidate = SFTPBrowser.join(dir, "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
                if await !exists(candidate) { return candidate }
            }
            return nil
        }
    }

    private func progress(_ id: UUID, _ done: UInt64) {
        let now = Date.now
        samples.append((now, done))
        samples.removeAll { now.timeIntervalSince($0.at) > 2 }
        let speed = samples.count > 1 ? Double(done - samples[0].bytes) / now.timeIntervalSince(samples[0].at) : 0
        update(id) { $0.bytesDone = done; $0.bytesPerSecond = speed }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // Off the main actor, 32 KiB at a time; cancelling the task stops after the current chunk.

    nonisolated private static func upload(_ local: URL, to remote: String, client: SFTPClient, progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        try await client.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
            var offset: UInt64 = 0
            while let data = try handle.read(upToCount: Int(chunk)), !data.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
                await progress(offset)
            }
        }
    }

    nonisolated private static func download(_ remote: String, to local: URL, client: SFTPClient, progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        let handle = try FileHandle(forWritingTo: local)
        defer { try? handle.close() }
        try await client.withFile(filePath: remote, flags: .read) { file in
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await file.read(from: offset, length: chunk)
                if chunk.readableBytes == 0 { break }
                try handle.write(contentsOf: chunk.readableBytesView)
                offset += UInt64(chunk.readableBytes)
                await progress(offset)
            }
        }
    }
}
