import AppKit
import SwiftUI

/// The selected request in «Сеть»: Заголовки, Полезная нагрузка, Ответ, Тайминги, Сообщения.
struct NetworkDetailsView: View {
    let model: NetworkModel
    let entry: NetworkEntry
    @State private var tab = Tab.headers

    enum Tab: String, CaseIterable, Identifiable {
        case headers, payload, response, timing, messages
        var id: Self { self }
        var title: String {
            switch self {
            case .headers: "Заголовки"
            case .payload: "Полезная нагрузка"
            case .response: "Ответ"
            case .timing: "Тайминги"
            case .messages: "Сообщения"
            }
        }
    }

    private var tabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .payload: entry.requestBody != nil || !entry.queryItems.isEmpty
            case .messages: entry.kind == .websocket
            case .response: entry.kind != .websocket
            default: true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(tabs) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                Menu {
                    Button("Копировать URL") { NetworkPanel.copy(entry.url) }
                    Button("Копировать как cURL") { NetworkPanel.copy(NetworkFormat.curl(entry)) }
                    Button("Копировать как fetch") { NetworkPanel.copy(NetworkFormat.fetch(entry)) }
                } label: { Image(systemName: "doc.on.doc") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Копировать")
                    .accessibilityLabel("Копировать")
                if entry.canReplay {
                    Button { model.replay(entry) } label: { Image(systemName: "arrow.clockwise") }
                        .help("Повторить запрос")
                        .accessibilityLabel("Повторить запрос")
                }
                Button { model.selection = nil } label: { Image(systemName: "xmark") }
                    .help("Закрыть")
                    .accessibilityLabel("Закрыть подробности")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(6)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: entry.id) { if !tabs.contains(tab) { tab = .headers } }
    }

    @ViewBuilder private var content: some View {
        switch tabs.contains(tab) ? tab : .headers {
        case .headers: headers
        case .payload: payload
        case .response: NetworkResponseView(model: model, entry: entry)
        case .timing: NetworkTimingView(entry: entry)
        case .messages: NetworkMessagesView(entry: entry)
        }
    }

    private var headers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                NetworkKeyValueSection(title: "Общие", rows: general)
                if entry.kind == .document || entry.kind == .other || entry.kind == .stylesheet || entry.kind == .script
                    || entry.kind == .image || entry.kind == .font || entry.kind == .media,
                   entry.responseHeaders.isEmpty, entry.requestHeaders.isEmpty {
                    Text("WebKit не сообщает странице заголовки этого ресурса.")
                        .foregroundStyle(Palette.secondaryText)
                }
                if !entry.responseHeaders.isEmpty {
                    NetworkKeyValueSection(title: "Заголовки ответа (\(entry.responseHeaders.count))",
                                           rows: entry.responseHeaders.map { ($0.name, $0.value) })
                }
                if !entry.requestHeaders.isEmpty {
                    NetworkKeyValueSection(title: "Заголовки запроса (\(entry.requestHeaders.count))",
                                           rows: entry.requestHeaders.map { ($0.name, $0.value) })
                }
                if !entry.stack.isEmpty {
                    NetworkKeyValueSection(title: "Стек инициатора", rows: entry.stack.split(separator: "\n").map { ("", String($0)) })
                }
            }
            .padding(8)
        }
    }

    private var general: [(String, String)] {
        var rows = [("URL запроса", entry.url), ("Метод", entry.method)]
        rows.append(("Код статуса", entry.statusDescription + (entry.statusText.isEmpty ? "" : " " + entry.statusText)))
        if !entry.protocolName.isEmpty { rows.append(("Протокол", entry.protocolName)) }
        if !entry.mimeType.isEmpty { rows.append(("Тип содержимого", entry.mimeType)) }
        if !entry.initiator.isEmpty { rows.append(("Инициатор", entry.initiator)) }
        if let frame = entry.frame { rows.append(("Фрейм", frame)) }
        if entry.imported { rows.append(("Источник", "импортировано из HAR")) }
        return rows
    }

    private var payload: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !entry.queryItems.isEmpty {
                    NetworkKeyValueSection(title: "Параметры строки запроса", rows: entry.queryItems.map { ($0.name, $0.value) })
                }
                if let body = entry.requestBody {
                    let type = entry.header("content-type", request: true) ?? ""
                    if entry.isForm || type.contains("x-www-form-urlencoded"),
                       let items = URLComponents(string: "?" + body)?.queryItems {
                        NetworkKeyValueSection(title: entry.isForm ? "Данные формы" : "Данные формы (url-encoded)",
                                               rows: items.map { ($0.name, $0.value ?? "") })
                    } else {
                        NetworkKeyValueSection(title: "Тело запроса", rows: [])
                        Text(NetworkFormat.prettyJSON(body) ?? body)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Bold names and selectable values, like Chrome's header lists.
struct NetworkKeyValueSection: View {
    let title: String
    let rows: [(String, String)]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if !row.0.isEmpty {
                            Text(row.0)
                                .bold()
                                .foregroundStyle(Palette.secondaryText)
                                .frame(width: 150, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Text(row.1)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(.leading, 4)
        } label: {
            Text(title).bold()
        }
        .disabled(rows.isEmpty)
    }
}

/// «Ответ»: text (JSON pretty-printed), image preview, or a button to load the body.
private struct NetworkResponseView: View {
    let model: NetworkModel
    let entry: NetworkEntry
    @State private var isPretty = true
    @State private var isLoading = false

    var body: some View {
        if let body = entry.responseBody {
            if let data = entry.isBase64 ? Data(base64Encoded: body) : entry.mimeType.contains("svg") ? Data(body.utf8) : nil,
               let image = NSImage(data: data) {
                ScrollView {
                    VStack(spacing: 6) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                            .background(Palette.surfaceAlt)
                        Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(NetworkFormat.bytes(data.count)) · \(entry.mimeType)")
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                }
            } else {
                let pretty = NetworkFormat.prettyJSON(body)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if pretty != nil {
                            Toggle("{ } Форматировать", isOn: $isPretty).toggleStyle(.checkbox)
                        }
                        if entry.isRefetched { Text("загружено повторно").foregroundStyle(.orange) }
                        if body.utf8.count >= DevToolsSession.maxBodyBytes { Text("обрезано до 1 МБ").foregroundStyle(.orange) }
                        Spacer()
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    NetworkTextView(text: isPretty ? pretty ?? body : body)
                }
            }
        } else if entry.imported || entry.kind == .websocket {
            placeholder("Нет данных ответа")
        } else if entry.kind == .fetch || entry.kind == .xhr {
            placeholder(entry.end == nil ? "Ожидание ответа…" : "Тело записывается, только пока панель открыта")
        } else {
            VStack(spacing: 8) {
                Text("WebKit не передаёт странице тело этого ресурса.").foregroundStyle(Palette.secondaryText)
                Button(isLoading ? "Загрузка…" : "Загрузить ответ") {
                    isLoading = true
                    Task {
                        await model.loadBody(entry.id)
                        isLoading = false
                    }
                }
                .disabled(isLoading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(Palette.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// «Тайминги»: the HAR phases as bars on one scale.
private struct NetworkTimingView: View {
    let entry: NetworkEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Начало: " + Date(timeIntervalSince1970: entry.start / 1000).formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                    .foregroundStyle(Palette.secondaryText)
                if let timings = entry.timings {
                    let phases = NetworkTimings.names.map { (title: $0.2, value: timings[keyPath: $0.0]) }.filter { $0.value > 0 }
                    let total = max(phases.map(\.value).reduce(0, +), 1)
                    if phases.count <= 1 && timings.wait < 0 {
                        Text("Фазы недоступны: сервер другого источника не прислал Timing-Allow-Origin.")
                            .foregroundStyle(Palette.secondaryText)
                    }
                    var offset = 0.0
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        let before = offset
                        let _ = offset += phase.value
                        HStack(spacing: 8) {
                            Text(phase.title).frame(width: 170, alignment: .leading)
                            GeometryReader { geometry in
                                Rectangle()
                                    .fill(Palette.accent)
                                    .frame(width: max(2, geometry.size.width * phase.value / total), height: 8)
                                    .offset(x: geometry.size.width * before / total, y: 3)
                            }
                            .frame(height: 14)
                            Text(NetworkFormat.milliseconds(phase.value)).frame(width: 70, alignment: .trailing)
                        }
                    }
                } else {
                    Text("Фазы запроса неизвестны.").foregroundStyle(Palette.secondaryText)
                }
                Divider()
                HStack {
                    Text("Всего").bold()
                    Spacer()
                    Text(NetworkFormat.milliseconds(entry.duration)).bold()
                }
            }
            .padding(10)
        }
    }
}

/// «Сообщения» of a WebSocket: sent ↑ and received ↓, filterable; the selected one in full.
private struct NetworkMessagesView: View {
    let entry: NetworkEntry
    @State private var filter = ""
    @State private var selection: Int?

    var body: some View {
        let frames = entry.frames.enumerated().filter { filter.isEmpty || $0.element.data.localizedCaseInsensitiveContains(filter) }
        VSplitView {
            VStack(spacing: 0) {
                TextField("Фильтр сообщений", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(6)
                List(frames, id: \.offset, selection: $selection) { offset, frame in
                    HStack(spacing: 6) {
                        Image(systemName: frame.outgoing ? "arrow.up" : "arrow.down")
                            .foregroundStyle(frame.outgoing ? .green : .red)
                        Text(frame.data).lineLimit(1).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Text(NetworkFormat.bytes(frame.length)).foregroundStyle(Palette.secondaryText)
                        Text(Date(timeIntervalSince1970: frame.time / 1000).formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .tag(offset)
                }
                .listStyle(.plain)
                .overlay { if entry.frames.isEmpty { Text("Сообщений нет").foregroundStyle(.secondary) } }
            }
            .frame(minHeight: 80)
            if let selection, entry.frames.indices.contains(selection) {
                let data = entry.frames[selection].data
                NetworkTextView(text: NetworkFormat.prettyJSON(data) ?? data).frame(minHeight: 60)
            }
        }
    }
}

/// Read-only monospaced text that stays fast for a 1 MB body.
struct NetworkTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textColor = .textColor
            view.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
