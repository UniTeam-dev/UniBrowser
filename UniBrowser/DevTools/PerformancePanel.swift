import SwiftUI

/// Panel «Производительность» (spec «Производительность»): record/stop of rAF frames and
/// PerformanceObserver entries in every frame, a zoomable timeline, the page load summary,
/// and the hand-off to Web Inspector's Timelines for JS profiles and memory.
@MainActor
@Observable
final class PerformanceModel {
    struct Entry: Identifiable {
        let id: Int
        /// PerformanceEntry.entryType.
        let type: String
        let name: String
        /// Milliseconds from the start of the recording.
        let start: Double
        let duration: Double
        var end: Double { start + duration }
        let initiator: String?
        /// Request sent → first byte, for the waterfall's darker part.
        let waiting: ClosedRange<Double>?
        /// Rows for the details pane.
        let details: [(String, String)]
    }

    struct Recording {
        var duration: Double
        /// rAF timestamps of the main frame, ms from the start.
        var frames: [Double]
        var entries: [Entry]
        var types: [String]

        /// Frames over 50 ms (spec): (start, length).
        var longFrames: [(start: Double, length: Double)] {
            zip(frames, frames.dropFirst()).compactMap { $1 - $0 > 50 ? ($0, $1 - $0) : nil }
        }

        var averageFPS: Double? {
            guard frames.count > 1, let first = frames.first, let last = frames.last, last > first else { return nil }
            return Double(frames.count - 1) * 1000 / (last - first)
        }
    }

    struct Metric: Identifiable {
        var id: String { title }
        let title: String
        let value: String
        var help: String?
    }

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var recording: Recording?
    private(set) var load: [Metric] = []
    var error: String?

    @ObservationIgnored private weak var session: DevToolsSession?
    /// Absolute start (timeOrigin + start, ms since 1970) the recording's times count from.
    @ObservationIgnored private var base = 0.0
    @ObservationIgnored private var types: [String] = []
    /// «Перезагрузить и записать»: start on the next main-frame `hello`.
    @ObservationIgnored private var recordAfterReload = false

    /// Total entries kept from all frames (each frame keeps at most 5000).
    static let maxEntries = 20000

    func bind(_ session: DevToolsSession) {
        self.session = session
        session.on("hello") { [weak self, weak session] message in
            guard let self, let session else { return }
            let isTop = message["isTop"] as? Bool == true
            if isTop { load = [] }
            if isTop, recordAfterReload {
                recordAfterReload = false
                isRecording = true
                startedAt = Date()
                base = 0
                Task { await self.startFrame(message.frame, buffered: true) }
            } else if isTop, isRecording {
                isRecording = false
                error = "Запись прервана: страница перешла на другой адрес. Для записи загрузки используйте «Перезагрузить и записать»."
            } else if isRecording {
                // An iframe that appeared during the recording: take its entries from its start.
                Task { await self.startFrame(message.frame, buffered: true) }
            }
            if isTop, session.isOpen {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await self.refreshLoad()
                }
            }
        }
    }

    // MARK: Recording

    func start() async {
        guard let session, !isRecording else { return }
        error = nil
        isRecording = true
        startedAt = Date()
        base = 0
        types = []
        var started: [String: [String: Any]] = [:]
        for (frame, result) in await session.callAll("performance.start") {
            if let result = result as? [String: Any] { started[frame] = result }
        }
        // Times count from the main frame's start; other frames are shifted by their timeOrigin.
        let origin = session.topFrame.flatMap { started[$0] } ?? started.values.first
        if let origin { base = number(origin["timeOrigin"]) + number(origin["start"]) }
        types = origin?["types"] as? [String] ?? []
    }

    func reloadAndRecord() {
        guard let session, let webView = session.webView, !isRecording else { return }
        error = nil
        recordAfterReload = true
        webView.reload()
    }

    func stop() async {
        guard let session, isRecording else { return }
        isRecording = false
        startedAt = nil
        var frames: [Double] = []
        var entries: [Entry] = []
        var duration = 0.0
        for (frame, result) in await session.callAll("performance.stop") {
            guard let result = result as? [String: Any] else { continue }
            let shift = number(result["timeOrigin"]) - base
            let url = session.frames[frame]?.url ?? result["url"] as? String ?? ""
            if result["isTop"] as? Bool == true {
                frames = (result["frames"] as? [Any] ?? []).map { number($0) + shift }
                duration = number(result["end"]) + shift
            }
            for item in result["entries"] as? [[String: Any]] ?? [] where entries.count < Self.maxEntries {
                entries.append(entry(item, id: entries.count, shift: shift, frameURL: url, isTop: frame == session.topFrame))
            }
        }
        entries.sort { $0.start < $1.start }
        duration = max(duration, entries.map(\.end).max() ?? 0, 1)
        recording = Recording(duration: duration, frames: frames, entries: entries, types: types)
    }

    func clear() {
        recording = nil
        error = nil
    }

    private func startFrame(_ frame: String, buffered: Bool) async {
        guard let session else { return }
        let result = try? await session.call(frame: frame, "performance.start", args: ["buffered": buffered]) as? [String: Any]
        if frame == session.topFrame, base == 0, let result {
            base = number(result["timeOrigin"]) + number(result["start"])
            types = result["types"] as? [String] ?? []
        }
    }

    private func entry(_ item: [String: Any], id: Int, shift: Double, frameURL: String, isTop: Bool) -> Entry {
        let type = item["type"] as? String ?? ""
        let name = String((item["name"] as? String ?? "").prefix(2000))
        let start = number(item["start"]) + shift
        let duration = max(number(item["duration"]), 0)
        var details: [(String, String)] = [("Тип", type), ("Имя", name), ("Начало", Self.format(ms: start)), ("Длительность", Self.format(ms: duration))]
        var waiting: ClosedRange<Double>?
        if let initiator = item["initiator"] as? String { details.append(("Инициатор", initiator)) }
        if let transfer = item["transfer"] as? NSNumber { details.append(("Передано", Self.format(bytes: transfer.doubleValue))) }
        if let size = item["size"] as? NSNumber, type != "largest-contentful-paint" { details.append(("Размер", Self.format(bytes: size.doubleValue))) }
        if let request = item["requestStart"] as? NSNumber, let response = item["responseStart"] as? NSNumber,
           request.doubleValue > 0, response.doubleValue >= request.doubleValue {
            waiting = (request.doubleValue + shift)...(response.doubleValue + shift)
            details.append(("Ожидание ответа", Self.format(ms: response.doubleValue - request.doubleValue)))
        }
        if let dnsStart = item["dnsStart"] as? NSNumber, let dnsEnd = item["dnsEnd"] as? NSNumber, dnsEnd.doubleValue > dnsStart.doubleValue {
            details.append(("DNS", Self.format(ms: dnsEnd.doubleValue - dnsStart.doubleValue)))
        }
        if let from = item["connectStart"] as? NSNumber, let to = item["connectEnd"] as? NSNumber, to.doubleValue > from.doubleValue {
            details.append(("Соединение", Self.format(ms: to.doubleValue - from.doubleValue)))
        }
        if let from = item["processingStart"] as? NSNumber, let to = item["processingEnd"] as? NSNumber {
            details.append(("Задержка обработки", Self.format(ms: from.doubleValue + shift - start)))
            details.append(("Обработка", Self.format(ms: to.doubleValue - from.doubleValue)))
        }
        if let element = item["element"] as? String { details.append(("Элемент", element)) }
        if let url = item["url"] as? String, !url.isEmpty { details.append(("URL", url)) }
        if let value = item["value"] as? NSNumber { details.append(("Сдвиг", String(format: "%.4f", value.doubleValue))) }
        if !isTop { details.append(("Фрейм", frameURL)) }
        return Entry(id: id, type: type, name: name, start: start, duration: duration,
                     initiator: item["initiator"] as? String, waiting: waiting, details: details)
    }

    // MARK: Page load

    func refreshLoad() async {
        guard let session, let top = session.topFrame,
              let result = try? await session.call(frame: top, "performance.load") as? [String: Any]
        else { return }
        var metrics: [Metric] = []
        let nav = result["navigation"] as? [String: Any]
        func add(_ title: String, _ value: Any?, help: String? = nil) {
            if let value = value as? NSNumber, value.doubleValue > 0 { metrics.append(Metric(title: title, value: Self.format(ms: value.doubleValue), help: help)) }
        }
        add("Первый байт", nav?["responseStart"], help: "Time to First Byte: от начала перехода до первого байта ответа")
        add("Первая отрисовка", result["fp"])
        add("FCP", result["fcp"], help: "First Contentful Paint: первая отрисовка текста или изображения")
        let lcp = result["lcp"] as? [String: Any]
        add("LCP", lcp?["start"], help: ["Largest Contentful Paint", lcp?["element"] as? String, lcp?["url"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        add("Интерактивность DOM", nav?["domInteractive"])
        add("DOMContentLoaded", nav?["dcl"])
        add("load", nav?["load"])
        if let nav {
            let dns = number(nav["dnsEnd"]) - number(nav["dnsStart"])
            if dns > 0 { metrics.append(Metric(title: "DNS", value: Self.format(ms: dns))) }
            let connect = number(nav["connectEnd"]) - number(nav["connectStart"])
            if connect > 0 { metrics.append(Metric(title: "Соединение", value: Self.format(ms: connect))) }
            let download = number(nav["responseEnd"]) - number(nav["responseStart"])
            if download > 0 { metrics.append(Metric(title: "Загрузка документа", value: Self.format(ms: download))) }
            if number(nav["transfer"]) > 0 { metrics.append(Metric(title: "Передано", value: Self.format(bytes: number(nav["transfer"])))) }
            if let type = nav["navigation"] as? String { metrics.append(Metric(title: "Переход", value: type)) }
        }
        if let count = result["resources"] as? NSNumber { metrics.append(Metric(title: "Ресурсов", value: "\(count.intValue)")) }
        load = metrics
    }

    // MARK: Formatting

    private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    static func format(ms: Double) -> String {
        abs(ms) >= 1000 ? String(format: "%.2f с", ms / 1000) : String(format: ms.rounded() == ms ? "%.0f мс" : "%.1f мс", ms)
    }

    static func format(bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct PerformancePanel: View {
    let session: DevToolsSession
    @Environment(\.devToolsFontSize) private var fontSize
    @State private var range: ClosedRange<Double>?
    @State private var selection: PerformanceModel.Entry.ID?

    private var model: PerformanceModel { session.performance }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            loadSummary
            Divider()
            content
        }
        .task { await model.refreshLoad() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if model.isRecording {
                Button { Task { await model.stop() } } label: { Label("Остановить", systemImage: "stop.fill").foregroundStyle(.red) }
                    .help("Остановить запись и показать результат")
                if let startedAt = model.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                        Text("Запись… \(Int(context.date.timeIntervalSince(startedAt))) с").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                Button { Task { range = nil; selection = nil; await model.start() } } label: { Label("Записать", systemImage: "record.circle") }
                    .help("Записать кадры, метки, события и загрузки ресурсов")
                Button { range = nil; selection = nil; model.reloadAndRecord() } label: { Label("Перезагрузить и записать", systemImage: "arrow.clockwise") }
                    .help("Перезагрузить страницу и записать её загрузку")
                Button { model.clear(); range = nil; selection = nil } label: { Image(systemName: "trash") }
                    .help("Очистить запись")
                    .accessibilityLabel("Очистить запись")
                    .disabled(model.recording == nil)
                if range != nil {
                    Button("Весь диапазон") { range = nil }
                        .help("Сбросить масштаб (двойной щелчок по шкале времени)")
                }
            }
            Spacer()
            Button {
                if let webView = session.webView { WebInspector.profile(webView) }
            } label: { Label("Профиль JavaScript и память в Web Inspector", systemImage: "flame") }
                .help("Открыть «Временные шкалы» Web Inspector и начать запись (профиль JavaScript, память, выделения)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var loadSummary: some View {
        HStack(spacing: 6) {
            Text("Загрузка страницы").foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    if model.load.isEmpty { Text("нет данных").foregroundStyle(.tertiary) }
                    ForEach(model.load) { metric in
                        HStack(spacing: 4) {
                            Text(metric.title).foregroundStyle(.secondary)
                            Text(metric.value).monospacedDigit()
                        }
                        .help(metric.help ?? metric.title)
                    }
                }
            }
            Button { Task { await model.refreshLoad() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Обновить сводку загрузки")
                .accessibilityLabel("Обновить сводку загрузки")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    @ViewBuilder private var content: some View {
        if let error = model.error {
            message(error, symbol: "exclamationmark.triangle")
        } else if model.isRecording {
            message("Идёт запись. Поработайте со страницей, затем нажмите «Остановить».", symbol: "record.circle")
        } else if let recording = model.recording {
            let visible = range ?? 0...recording.duration
            VSplitView {
                VStack(spacing: 0) {
                    recordingSummary(recording)
                    PerformanceTimeline(recording: recording, range: visible, selection: $selection) { range = $0 }
                }
                .frame(minHeight: 140, idealHeight: 260)
                entriesTable(recording, visible: visible)
                    .frame(minHeight: 80)
            }
        } else {
            message("Нажмите «Записать», чтобы записать работу страницы, или «Перезагрузить и записать» для её загрузки.", symbol: "speedometer")
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordingSummary(_ recording: PerformanceModel.Recording) -> some View {
        var parts = ["Длительность \(PerformanceModel.format(ms: recording.duration))"]
        if let fps = recording.averageFPS { parts.append(String(format: "средний FPS %.0f", fps)) }
        parts.append("долгих кадров \(recording.longFrames.count)")
        parts.append("записей \(recording.entries.count)")
        return HStack {
            Text(parts.joined(separator: " · ")).foregroundStyle(.secondary)
            Spacer()
            Text("Перетащите по шкале, чтобы увеличить").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
    }

    private func entriesTable(_ recording: PerformanceModel.Recording, visible: ClosedRange<Double>) -> some View {
        let rows = recording.entries.filter { $0.end >= visible.lowerBound && $0.start <= visible.upperBound }
        let selected = recording.entries.first { $0.id == selection }
        return HStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Тип") { Text($0.type) }.width(min: 60, ideal: 110, max: 180)
                TableColumn("Имя") { Text($0.name).lineLimit(1).help($0.name) }
                TableColumn("Начало") { Text(PerformanceModel.format(ms: $0.start)).monospacedDigit() }.width(min: 60, ideal: 80, max: 120)
                TableColumn("Длительность") { Text(PerformanceModel.format(ms: $0.duration)).monospacedDigit() }.width(min: 60, ideal: 90, max: 120)
            }
            if let selected {
                Divider()
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(Array(selected.details.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.0).foregroundStyle(.secondary)
                                Text(row.1).textSelection(.enabled).lineLimit(4)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 280)
            }
        }
    }
}

/// The timeline (spec): FPS graph, long frames, paints, marks and measures, events, other
/// entries, then the resource waterfall. Drag to zoom, click to select, double-click the
/// ruler to see everything.
private struct PerformanceTimeline: View {
    let recording: PerformanceModel.Recording
    let range: ClosedRange<Double>
    @Binding var selection: PerformanceModel.Entry.ID?
    let zoom: (ClosedRange<Double>?) -> Void
    @Environment(\.devToolsFontSize) private var fontSize
    @State private var drag: ClosedRange<CGFloat>?

    private static let labelWidth: CGFloat = 112
    private static let rulerHeight: CGFloat = 18
    private static let fpsHeight: CGFloat = 44

    /// One row of the timeline: a title and the boxes in it.
    private struct Track {
        let title: String
        var lanes: [[PerformanceModel.Entry]]
        var color: Color
    }

    private var rowHeight: CGFloat { max(14, fontSize + 5) }

    /// Entries by track; overlapping ones get more lanes.
    private var tracks: [Track] {
        var marks: [PerformanceModel.Entry] = [], measures: [PerformanceModel.Entry] = [], paints: [PerformanceModel.Entry] = []
        var events: [PerformanceModel.Entry] = [], resources: [PerformanceModel.Entry] = [], other: [PerformanceModel.Entry] = []
        for entry in recording.entries {
            switch entry.type {
            case "mark": marks.append(entry)
            case "measure": measures.append(entry)
            case "paint", "largest-contentful-paint", "layout-shift", "element": paints.append(entry)
            case "event", "first-input": events.append(entry)
            case "resource", "navigation": resources.append(entry)
            default: other.append(entry)
            }
        }
        var result: [Track] = []
        if !paints.isEmpty { result.append(Track(title: "Отрисовка", lanes: [paints], color: .green)) }
        if !marks.isEmpty || !measures.isEmpty {
            result.append(Track(title: "Метки и измерения", lanes: [marks] + Self.lanes(measures), color: .orange))
        }
        if !events.isEmpty { result.append(Track(title: "События", lanes: Self.lanes(events), color: .purple)) }
        if !other.isEmpty { result.append(Track(title: "Прочее", lanes: Self.lanes(other), color: .gray)) }
        // The waterfall: one resource per row.
        if !resources.isEmpty { result.append(Track(title: "Сеть", lanes: resources.map { [$0] }, color: .blue)) }
        return result
    }

    private static func lanes(_ entries: [PerformanceModel.Entry]) -> [[PerformanceModel.Entry]] {
        var lanes: [[PerformanceModel.Entry]] = []
        for entry in entries {
            if let index = lanes.firstIndex(where: { ($0.last?.end ?? 0) <= entry.start }) { lanes[index].append(entry) } else { lanes.append([entry]) }
        }
        return lanes.isEmpty ? [[]] : lanes
    }

    var body: some View {
        let tracks = tracks
        let height = Self.rulerHeight + Self.fpsHeight + rowHeight + CGFloat(tracks.reduce(0) { $0 + $1.lanes.count }) * rowHeight + 6
        GeometryReader { geometry in
            let width = max(geometry.size.width - Self.labelWidth, 10)
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(context, size: size, width: width, tracks: tracks)
                    }
                    .frame(height: height)
                    if let drag {
                        Rectangle()
                            .fill(Palette.accent.opacity(0.15))
                            .overlay { Rectangle().stroke(Palette.accent.opacity(0.6)) }
                            .frame(width: drag.upperBound - drag.lowerBound, height: height)
                            .offset(x: Self.labelWidth + drag.lowerBound)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(gesture(width: width, tracks: tracks))
                .simultaneousGesture(TapGesture(count: 2).onEnded { zoom(nil) })
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Временная шкала записи")
    }

    // MARK: Geometry

    private func x(_ time: Double, width: CGFloat) -> CGFloat {
        CGFloat((time - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.001)) * width
    }

    private func time(_ x: CGFloat, width: CGFloat) -> Double {
        range.lowerBound + Double(x / width) * (range.upperBound - range.lowerBound)
    }

    /// Boxes of every entry, in content coordinates (x from the labels' right edge).
    private func boxes(width: CGFloat, tracks: [Track]) -> [(CGRect, PerformanceModel.Entry, Color)] {
        var result: [(CGRect, PerformanceModel.Entry, Color)] = []
        var y = Self.rulerHeight + Self.fpsHeight + rowHeight
        for track in tracks {
            for lane in track.lanes {
                for entry in lane where entry.end >= range.lowerBound && entry.start <= range.upperBound {
                    let left = x(entry.start, width: width)
                    let w = max(x(entry.end, width: width) - left, entry.duration == 0 ? 0 : 1)
                    result.append((CGRect(x: left, y: y + 2, width: w, height: rowHeight - 4), entry, track.color))
                }
                y += rowHeight
            }
        }
        return result
    }

    private func gesture(width: CGFloat, tracks: [Track]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let a = min(max(value.startLocation.x - Self.labelWidth, 0), width)
                let b = min(max(value.location.x - Self.labelWidth, 0), width)
                drag = abs(b - a) > 3 ? min(a, b)...max(a, b) : nil
            }
            .onEnded { value in
                defer { drag = nil }
                if let drag, drag.upperBound - drag.lowerBound > 3 {
                    zoom(time(drag.lowerBound, width: width)...time(drag.upperBound, width: width))
                    return
                }
                // A click: the box under it (markers get a few points of slack).
                let point = CGPoint(x: value.location.x - Self.labelWidth, y: value.location.y)
                let hit = boxes(width: width, tracks: tracks).last { $0.0.insetBy(dx: -3, dy: 0).contains(point) }
                selection = hit?.1.id
            }
    }

    // MARK: Drawing

    private func draw(_ context: GraphicsContext, size: CGSize, width: CGFloat, tracks: [Track]) {
        let left = Self.labelWidth
        let font = Font.system(size: max(fontSize - 1, 9))
        var content = context
        content.translateBy(x: left, y: 0)
        content.clip(to: Path(CGRect(x: 0, y: 0, width: width, height: size.height)))

        // Ruler.
        let span = range.upperBound - range.lowerBound
        let step = Self.niceStep(span / Double(max(width / 90, 1)))
        var tick = (range.lowerBound / step).rounded(.up) * step
        while tick <= range.upperBound {
            let tx = x(tick, width: width)
            content.stroke(Path { $0.move(to: CGPoint(x: tx, y: 12)); $0.addLine(to: CGPoint(x: tx, y: size.height)) }, with: .color(.primary.opacity(0.08)))
            content.draw(Text(PerformanceModel.format(ms: tick)).font(font).foregroundStyle(.secondary), at: CGPoint(x: tx + 2, y: 1), anchor: .topLeading)
            tick += step
        }

        // FPS graph: frames per second at each frame, 0…60 (higher is clipped).
        let top = Self.rulerHeight
        let fpsBottom = top + Self.fpsHeight - 2
        var graph = Path()
        var started = false
        for (previous, frame) in zip(recording.frames, recording.frames.dropFirst()) where frame >= range.lowerBound && previous <= range.upperBound {
            let fps = min(1000 / max(frame - previous, 1), 60)
            let point = CGPoint(x: x(frame, width: width), y: fpsBottom - CGFloat(fps / 60) * (Self.fpsHeight - 4))
            if started { graph.addLine(to: point) } else { graph.move(to: CGPoint(x: x(previous, width: width), y: point.y)); graph.addLine(to: point); started = true }
        }
        content.stroke(graph, with: .color(.green), lineWidth: 1.2)
        if recording.frames.count < 2 {
            // WebKit pauses requestAnimationFrame while the page is not visible.
            content.draw(Text("Кадры не записаны: страница была скрыта").font(font).foregroundStyle(.secondary), at: CGPoint(x: 6, y: top + Self.fpsHeight / 2), anchor: .leading)
        }
        content.stroke(Path { $0.move(to: CGPoint(x: 0, y: fpsBottom)); $0.addLine(to: CGPoint(x: width, y: fpsBottom)) }, with: .color(.primary.opacity(0.15)))

        // Long frames.
        let longY = top + Self.fpsHeight
        for frame in recording.longFrames where frame.start + frame.length >= range.lowerBound && frame.start <= range.upperBound {
            let fx = x(frame.start, width: width)
            let rect = CGRect(x: fx, y: longY + 2, width: max(x(frame.start + frame.length, width: width) - fx, 1), height: rowHeight - 4)
            content.fill(Path(rect), with: .color(.red.opacity(0.75)))
        }

        // Entries.
        for (rect, entry, color) in boxes(width: width, tracks: tracks) {
            let isSelected = entry.id == selection
            if rect.width == 0 {
                // A point in time: a diamond.
                let c = CGPoint(x: rect.minX, y: rect.midY), r = rect.height / 2
                let diamond = Path { $0.move(to: CGPoint(x: c.x, y: c.y - r)); $0.addLine(to: CGPoint(x: c.x + r, y: c.y)); $0.addLine(to: CGPoint(x: c.x, y: c.y + r)); $0.addLine(to: CGPoint(x: c.x - r, y: c.y)); $0.closeSubpath() }
                content.fill(diamond, with: .color(color))
                if isSelected { content.stroke(diamond, with: .color(.primary), lineWidth: 1.5) }
                content.draw(Text(Self.short(entry)).font(font).foregroundStyle(.secondary), at: CGPoint(x: c.x + r + 2, y: c.y), anchor: .leading)
                continue
            }
            if entry.type == "resource" || entry.type == "navigation" {
                content.fill(Path(rect), with: .color(Self.color(initiator: entry.initiator).opacity(0.45)))
                if let waiting = entry.waiting {
                    let wx = x(waiting.lowerBound, width: width)
                    content.fill(Path(CGRect(x: wx, y: rect.minY, width: max(x(waiting.upperBound, width: width) - wx, 0.5), height: rect.height)), with: .color(Self.color(initiator: entry.initiator)))
                }
                content.draw(Text(Self.short(entry)).font(font).foregroundStyle(.primary), at: CGPoint(x: rect.maxX + 4, y: rect.midY), anchor: .leading)
            } else {
                content.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.7)))
                if rect.width > 30 {
                    var inner = content
                    inner.clip(to: Path(rect))
                    inner.draw(Text(Self.short(entry)).font(font).foregroundStyle(.white), at: CGPoint(x: rect.minX + 3, y: rect.midY), anchor: .leading)
                }
            }
            if isSelected { content.stroke(Path(rect.insetBy(dx: -1, dy: -1)), with: .color(.primary), lineWidth: 1.5) }
        }

        // Track titles over the left column.
        var y = Self.rulerHeight
        context.fill(Path(CGRect(x: 0, y: 0, width: left, height: size.height)), with: .color(Palette.surfaceAlt))
        context.draw(Text("FPS").font(font).foregroundStyle(.secondary), at: CGPoint(x: 6, y: y + 4), anchor: .topLeading)
        y += Self.fpsHeight
        context.draw(Text("Долгие кадры").font(font).foregroundStyle(.secondary), at: CGPoint(x: 6, y: y + rowHeight / 2), anchor: .leading)
        y += rowHeight
        for track in tracks {
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.primary.opacity(0.08)))
            context.draw(Text(track.title).font(font).foregroundStyle(.secondary), at: CGPoint(x: 6, y: y + rowHeight / 2), anchor: .leading)
            y += CGFloat(track.lanes.count) * rowHeight
        }
    }

    private static func short(_ entry: PerformanceModel.Entry) -> String {
        guard entry.type == "resource" || entry.type == "navigation", let url = URL(string: entry.name) else { return entry.name }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host() ?? entry.name) : last
    }

    private static func color(initiator: String?) -> Color {
        switch initiator {
        case "script": .orange
        case "link", "css": .purple
        case "img", "image": .green
        case "fetch", "xmlhttprequest", "beacon": .yellow
        case "navigation", "iframe": .blue
        default: .gray
        }
    }

    /// 1, 2, 5 × 10ⁿ at or above `raw`.
    private static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let power = pow(10, floor(log10(raw)))
        for factor in [1.0, 2, 5, 10] where factor * power >= raw { return factor * power }
        return 10 * power
    }
}
