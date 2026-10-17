import SwiftUI

/// Panel «Покрытие» (spec «Покрытие»): CSS coverage of every frame's stylesheets. A rule is
/// used if its selector matched something while recording. Источники reads the unused
/// lines through `unusedLines(url:inline:)`.
@MainActor
@Observable
final class CoverageModel {
    struct Sheet: Identifiable {
        /// Frame id + the script's key for the sheet.
        var id: String { "\(frame)/\(key)" }
        let frame: String
        let key: Int
        /// The file URL; for an inline `<style>` and a constructed sheet, the document URL.
        let url: String
        /// Index among the document's `<style>` elements, for an inline sheet.
        let inline: Int?
        let constructed: Bool
        /// The text was rebuilt from the CSSOM (file not readable), so offsets are not the file's.
        let rebuilt: Bool
        let error: String?
        /// UTF-8 bytes.
        let total: Int
        let unused: Int
        /// Unused rules as UTF-16 offsets into the sheet's text (end exclusive); after stop only.
        var unusedRanges: [Range<Int>] = []
        /// Lines touched by unused rules, 1-based; after stop only.
        var unusedLines: [ClosedRange<Int>] = []

        var used: Int { total - unused }
        var unusedShare: Double { total > 0 ? Double(unused) / Double(total) : 0 }

        var title: String {
            if let inline { return "\(url) — <style> №\(inline + 1)" }
            if constructed { return "\(url) — созданная таблица стилей" }
            return url
        }
    }

    private(set) var isRecording = false
    private(set) var sheets: [Sheet] = []
    var error: String?

    @ObservationIgnored private weak var session: DevToolsSession?

    func bind(_ session: DevToolsSession) {
        self.session = session
        // Live totals while recording.
        session.on("coverage") { [weak self] message in
            guard let self, isRecording else { return }
            replace(frame: message.frame, with: message["sheets"] as? [[String: Any]] ?? [])
        }
        session.on("hello") { [weak self] message in
            guard let self, isRecording, message["isTop"] as? Bool == true else { return }
            isRecording = false
            error = "Запись прервана: страница перешла на другой адрес. Показаны данные до перехода."
        }
    }

    func start() async {
        guard let session, !isRecording else { return }
        error = nil
        sheets = []
        isRecording = true
        for (frame, result) in await session.callAll("coverage.start") {
            replace(frame: frame, with: result as? [[String: Any]] ?? [])
        }
    }

    func stop() async {
        guard let session, isRecording else { return }
        isRecording = false
        for (frame, result) in await session.callAll("coverage.stop") {
            replace(frame: frame, with: result as? [[String: Any]] ?? [])
        }
    }

    func clear() {
        sheets = []
        error = nil
    }

    /// For Источники: lines of `url` (or of its `inline`-th `<style>`) inside unused rules,
    /// 1-based, merged. Empty when nothing was recorded for it or the text was rebuilt.
    func unusedLines(url: String, inline: Int? = nil) -> [ClosedRange<Int>] {
        sheet(url: url, inline: inline)?.unusedLines ?? []
    }

    /// For Источники: unused rules of `url` as UTF-16 offsets into the file's text.
    func unusedRanges(url: String, inline: Int? = nil) -> [Range<Int>] {
        sheet(url: url, inline: inline)?.unusedRanges ?? []
    }

    func sheet(url: String, inline: Int? = nil) -> Sheet? {
        sheets.first { $0.url == url && $0.inline == inline && !$0.constructed && !$0.rebuilt && $0.error == nil }
    }

    private func replace(frame: String, with items: [[String: Any]]) {
        // The page can post anything: at most 2000 sheets and 100 000 ranges each.
        let new = items.prefix(2000).map { item in
            var sheet = Sheet(
                frame: frame,
                key: (item["key"] as? NSNumber)?.intValue ?? 0,
                url: item["url"] as? String ?? "",
                inline: (item["inline"] as? NSNumber)?.intValue,
                constructed: item["constructed"] as? Bool == true,
                rebuilt: item["rebuilt"] as? Bool == true,
                error: item["error"] as? String,
                total: (item["total"] as? NSNumber)?.intValue ?? 0,
                unused: (item["unused"] as? NSNumber)?.intValue ?? 0
            )
            sheet.unusedRanges = Self.pairs(item["ranges"]).compactMap { $0 <= $1 ? $0..<$1 : nil }
            sheet.unusedLines = Self.pairs(item["lines"]).compactMap { $0 <= $1 ? $0...$1 : nil }
            return sheet
        }
        // Live updates have no ranges: keep the old ones until the final result.
        let old = Dictionary(sheets.filter { $0.frame == frame }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let merged = new.map { sheet in
            var sheet = sheet
            if sheet.unusedRanges.isEmpty, sheet.unused > 0, let previous = old[sheet.key] {
                sheet.unusedRanges = previous.unusedRanges
                sheet.unusedLines = previous.unusedLines
            }
            return sheet
        }
        sheets = sheets.filter { $0.frame != frame } + merged
    }

    private static func pairs(_ value: Any?) -> [(Int, Int)] {
        (value as? [[NSNumber]] ?? []).prefix(100_000).compactMap { $0.count == 2 ? ($0[0].intValue, $0[1].intValue) : nil }
    }
}

struct CoveragePanel: View {
    let session: DevToolsSession
    @State private var filter = ""
    @State private var selection: CoverageModel.Sheet.ID?
    @State private var sortOrder = [KeyPathComparator(\CoverageModel.Sheet.unused, order: .reverse)]

    private var model: CoverageModel { session.coverage }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if model.sheets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text(model.isRecording
                         ? "Идёт запись. Поработайте со страницей: правила, которые совпадут, станут используемыми."
                         : "Нажмите «Начать запись», чтобы узнать, какие CSS-правила страница использует.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.isRecording {
                Button { Task { await model.stop() } } label: { Label("Остановить", systemImage: "stop.fill").foregroundStyle(.red) }
                    .help("Остановить запись и показать неиспользуемые правила")
            } else {
                Button { Task { await model.start() } } label: { Label("Начать запись", systemImage: "record.circle") }
                    .help("Записывать, какие CSS-правила совпадают с элементами страницы")
            }
            Button { model.clear() } label: { Image(systemName: "trash") }
                .help("Очистить")
                .accessibilityLabel("Очистить")
                .disabled(model.sheets.isEmpty || model.isRecording)
            TextField("Фильтр по URL", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var rows: [CoverageModel.Sheet] {
        let filtered = filter.isEmpty ? model.sheets : model.sheets.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        return filtered.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("URL", value: \.url) { sheet in
                Text(sheet.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sheet.error ?? (sheet.rebuilt ? "\(sheet.title)\nТекст собран из CSSOM: файл недоступен, номера строк не совпадут с Источниками" : sheet.title))
            }
            TableColumn("Тип") { _ in Text("CSS") }.width(40)
            TableColumn("Всего байт", value: \.total) { Text($0.error == nil ? Self.bytes($0.total) : "—").monospacedDigit() }
                .width(min: 70, ideal: 90, max: 120)
            TableColumn("Не используется", value: \.unused) { sheet in
                Text(sheet.error == nil ? "\(Self.bytes(sheet.unused)) (\(Int((sheet.unusedShare * 100).rounded())) %)" : "—").monospacedDigit()
            }
            .width(min: 100, ideal: 130, max: 170)
            TableColumn("Использование") { sheet in
                UsageBar(share: sheet.error == nil ? 1 - sheet.unusedShare : 0)
                    .help(sheet.error ?? "Используется \(Self.bytes(sheet.used)) из \(Self.bytes(sheet.total))")
            }
            .width(min: 80, ideal: 200)
        }
        .contextMenu(forSelectionType: CoverageModel.Sheet.ID.self) { ids in
            if let id = ids.first, let sheet = model.sheets.first(where: { $0.id == id }) {
                Button("Открыть в Источниках") { openInSources(sheet) }
                Button("Копировать URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sheet.url, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let sheet = model.sheets.first(where: { $0.id == id }) { openInSources(sheet) }
        }
    }

    private func openInSources(_ sheet: CoverageModel.Sheet) {
        session.panel = .sources
        // merge: when Источники has its reveal API, call it here, e.g.
        // session.sources.reveal(url: sheet.url, inline: sheet.inline, line: sheet.unusedLines.first?.lowerBound)
    }

    private var footer: some View {
        let sheets = rows.filter { $0.error == nil }
        let total = sheets.reduce(0) { $0 + $1.total }
        let unused = sheets.reduce(0) { $0 + $1.unused }
        return HStack {
            if total > 0 {
                Text("\(Self.bytes(unused)) из \(Self.bytes(total)) (\(Int((Double(unused) / Double(total) * 100).rounded())) %) не используется")
            }
            Spacer()
            Text("Покрытие JavaScript WebKit не предоставляет").foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Used part green, unused part red, like Chrome's coverage bars.
private struct UsageBar: View {
    let share: Double

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle().fill(Color.green.opacity(0.7)).frame(width: geometry.size.width * share)
                Rectangle().fill(Color.red.opacity(0.7))
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
