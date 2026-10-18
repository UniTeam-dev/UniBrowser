import Foundation
import Observation
import WebKit

/// Files the pages download: attachments, types WebKit can't show, `<a download>`
/// (blob: and data: links too). Mac: ~/Downloads; iPhone: the app's Documents, seen in «Файлы».
/// One list for the app; it lives until quit (the files stay).
@MainActor
@Observable
final class Downloads: NSObject {
    static let shared = Downloads()

    private(set) var items: [DownloadItem] = []
    var activeCount: Int { items.count { $0.state == .running } }

    @ObservationIgnored let directory: URL = {
        #if os(macOS)
        URL.downloadsDirectory
        #else
        URL.documentsDirectory
        #endif
    }()

    /// Takes over a download WebKit started from a navigation.
    func track(_ download: WKDownload) {
        let item = DownloadItem(download: download)
        items.insert(item, at: 0)
        download.delegate = self
    }

    func cancel(_ item: DownloadItem) {
        guard item.state == .running else { return }
        item.state = .cancelled
        item.download?.cancel { _ in }
    }

    /// Takes finished, failed and cancelled ones off the list; the files stay.
    func clear() {
        items.removeAll { $0.state != .running }
    }

    func remove(_ item: DownloadItem) {
        cancel(item)
        items.removeAll { $0 === item }
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    /// `name` made safe for one path component, then «name (1).ext», «name (2).ext»… until `isTaken` says no.
    nonisolated static func uniqueFileURL(in directory: URL, suggested name: String, isTaken: (URL) -> Bool) -> URL {
        var clean = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while clean.hasPrefix(".") { clean.removeFirst() } // no hidden files, no «..»
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = "download" }

        var base = (clean as NSString).deletingPathExtension
        var ext = (clean as NSString).pathExtension
        if (base as NSString).pathExtension.lowercased() == "tar" { // keep .tar.gz together
            ext = "tar." + ext
            base = (base as NSString).deletingPathExtension
        }
        var candidate = directory.appending(path: clean, directoryHint: .notDirectory)
        var n = 1
        while isTaken(candidate) {
            let numbered = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = directory.appending(path: numbered, directoryHint: .notDirectory)
            n += 1
        }
        return candidate
    }
}

extension Downloads {
    /// A response the page can't show, or one sent as an attachment, is saved instead.
    static func policy(for response: WKNavigationResponse) -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let isAttachment = disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        return response.canShowMIMEType && !isAttachment ? .allow : .download
    }
}

extension Downloads: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let item = item(for: download), item.state == .running else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inFlight = Set(items.compactMap(\.file))
        let url = Self.uniqueFileURL(in: directory, suggested: suggestedFilename) {
            inFlight.contains($0) || FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        item.file = url
        item.name = url.lastPathComponent
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.progress = 1
        #if os(macOS)
        // Like Safari: Gatekeeper checks a downloaded app or script before it first opens.
        if var file = item.file {
            var values = URLResourceValues()
            var quarantine: [String: Any] = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                kLSQuarantineAgentNameKey as String: "UniBrowser",
            ]
            if let source = item.source, !["blob", "data"].contains(source.scheme) {
                quarantine[kLSQuarantineDataURLKey as String] = source
            }
            values.quarantineProperties = quarantine
            try? file.setResourceValues(values)
        }
        #endif
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        if item.state == .running { item.state = .failed(error.localizedDescription) }
        // WebKit leaves the partial file behind; the name was free when we picked it, so it is ours.
        if let file = item.file { try? FileManager.default.removeItem(at: file) }
    }
}

@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable { case running, finished, cancelled, failed(String) }

    var name: String
    /// Where it is being saved; nil until WebKit asks.
    var file: URL?
    let source: URL?
    var state = State.running
    var progress = 0.0
    var totalBytes: Int64 = 0
    @ObservationIgnored weak var download: WKDownload?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(download: WKDownload) {
        self.download = download
        source = download.originalRequest?.url
        name = source?.lastPathComponent ?? "Загрузка"
        observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted, total = progress.totalUnitCount
            Task { @MainActor in
                self?.progress = fraction
                self?.totalBytes = total
            }
        }
    }

    /// «12,3 МБ», or «45 %» of an unknown size.
    var detail: String {
        switch state {
        case .running:
            totalBytes > 0
                ? "\(Int(progress * 100)) % из \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                : "Загружается…"
        case .finished: totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) : "Готово"
        case .cancelled: "Отменено"
        case .failed(let message): "Ошибка: \(message)"
        }
    }
}
