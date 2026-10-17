import AppKit
import SwiftUI

/// Panel «Сеть» (spec «Сеть»): toolbar, filters, the request table with its waterfall,
/// search, and the details of the selected request (NetworkDetails.swift).
struct NetworkPanel: View {
    let session: DevToolsSession
    @State private var sortOrder = [KeyPathComparator(\NetworkEntry.start)]
    @State private var isBlockingVisible = false

    private var model: NetworkModel { session.network }

    var body: some View {
        @Bindable var model = model
        let rows = model.visible().sorted(using: sortOrder)
        VStack(spacing: 0) {
            toolbar
            Divider()
            filterBar
            Divider()
            HSplitView {
                if model.isSearchVisible {
                    NetworkSearchView(model: model)
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 400)
                }
                table(rows)
                    .frame(minWidth: 260)
                if let entry = model.selected {
                    NetworkDetailsView(model: model, entry: entry)
                        .frame(minWidth: 280, idealWidth: 440)
                }
            }
            Divider()
            statusBar(rows)
        }
        .font(.system(size: 11))
        .alert("Ошибка", isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) {
            Button("OK") { model.importError = nil }
        } message: {
            Text(model.importError ?? "")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Button { model.clear() } label: { Image(systemName: "nosign") }
                .help("Очистить")
                .accessibilityLabel("Очистить")
            Toggle("Сохранять журнал", isOn: $model.preserveLog)
                .help("Не очищать список при переходе на другую страницу")
            Toggle("Отключить кэш", isOn: $model.disableCache)
                .help("Пока панель открыта: fetch/XHR без кэша, перезагрузка без кэша")
            Picker("Регулирование", selection: $model.throttle) {
                ForEach(NetworkThrottle.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Регулирование сети для этой вкладки")
            if model.throttle != .none {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Регулирование включено")
            }
            Divider().frame(height: 14)
            Button { isBlockingVisible.toggle() } label: {
                Image(systemName: "hand.raised")
                    .foregroundStyle(model.isBlockingOn && !model.activePatterns.isEmpty ? Color.red : Palette.secondaryText)
            }
            .help("Блокировка запросов")
            .accessibilityLabel("Блокировка запросов")
            .popover(isPresented: $isBlockingVisible) { NetworkBlockingView(model: model) }
            Button { model.importHAR() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Импортировать HAR")
                .accessibilityLabel("Импортировать HAR")
            Button { model.exportHAR() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Экспортировать всё в HAR")
                .accessibilityLabel("Экспортировать в HAR")
                .disabled(model.entries.isEmpty)
            Button { model.isSearchVisible.toggle() } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command)
                .help("Поиск по запросам (⌘F)")
                .accessibilityLabel("Поиск по запросам")
            Spacer()
        }
        .toggleStyle(.checkbox)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            TextField("Фильтр", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            HStack(spacing: 0) {
                ForEach(NetworkTypeFilter.allCases) { filter in
                    Button(filter.title) { model.typeFilter = filter }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(model.typeFilter == filter ? Palette.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
                        .foregroundStyle(model.typeFilter == filter ? Palette.text : Palette.secondaryText)
                }
            }
            .fixedSize()
            Picker("Статус", selection: $model.statusFilter) {
                ForEach(NetworkStatusFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Menu(model.domainFilter ?? "Все домены") {
                Button("Все домены") { model.domainFilter = nil }
                Divider()
                ForEach(model.domains, id: \.self) { domain in
                    Button(domain) { model.domainFilter = domain }
                }
            }
            .fixedSize()
            Toggle("Скрыть data: URL", isOn: $model.hideDataURLs)
            Toggle("Только сторонние", isOn: $model.onlyThirdParty)
            Spacer()
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .clipped()
    }

    // MARK: - Table

    private func table(_ rows: [NetworkEntry]) -> some View {
        @Bindable var model = model
        let start = rows.map(\.start).min() ?? 0
        let end = max(rows.map { $0.end ?? $0.start }.max() ?? 0, start + 1)
        return Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Имя", value: \.name) { entry in
                HStack(spacing: 4) {
                    Image(systemName: Self.symbol(entry.kind))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 12)
                    Text(entry.name)
                        .lineLimit(1)
                        .foregroundStyle(entry.error != nil ? Color.red : entry.imported ? Palette.secondaryText : Palette.text)
                }
                .help(entry.url)
            }
            .width(min: 120, ideal: 220)
            TableColumn("Метод", value: \.method).width(min: 40, ideal: 50)
            TableColumn("Статус", value: \.statusSort) { entry in
                Text(entry.statusDescription)
                    .lineLimit(1)
                    .foregroundStyle(entry.error != nil || (entry.status ?? 0) >= 400 ? Color.red : Palette.text)
                    .help(entry.error ?? entry.statusText)
            }
            .width(min: 40, ideal: 60)
            TableColumn("Тип", value: \.kindTitle).width(min: 40, ideal: 70)
            TableColumn("Инициатор", value: \.initiator) { entry in
                Text(Self.shortInitiator(entry.initiator))
                    .lineLimit(1)
                    .foregroundStyle(Palette.secondaryText)
                    .help(entry.stack.isEmpty ? entry.initiator : entry.stack)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Размер", value: \.sizeSort) { entry in
                Text(Self.sizeText(entry)).lineLimit(1)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Время", value: \.duration) { entry in
                Text(NetworkFormat.milliseconds(entry.duration)).lineLimit(1)
            }
            .width(min: 40, ideal: 60)
            TableColumn("Водопад", value: \.start) { entry in
                NetworkWaterfallBar(entry: entry, start: start, end: end)
            }
            .width(min: 80, ideal: 180)
        }
        .contextMenu(forSelectionType: NetworkEntry.ID.self) { ids in
            if let id = ids.first, let entry = model.entry(id) { contextMenu(entry) }
        }
    }

    @ViewBuilder private func contextMenu(_ entry: NetworkEntry) -> some View {
        Button("Копировать URL") { Self.copy(entry.url) }
        Button("Копировать как cURL") { Self.copy(NetworkFormat.curl(entry)) }
        Button("Копировать как fetch") { Self.copy(NetworkFormat.fetch(entry)) }
        if let body = entry.responseBody, !entry.isBase64 { Button("Копировать ответ") { Self.copy(body) } }
        Divider()
        if entry.canReplay { Button("Повторить запрос") { model.replay(entry) } }
        if !entry.imported, entry.scheme != "data" {
            Button("Заблокировать URL") { model.block(entry.url) }
            if !entry.host.isEmpty { Button("Заблокировать домен") { model.block("*://\(entry.host)/*") } }
        }
        Divider()
        Button("Экспортировать всё в HAR…") { model.exportHAR() }
        Button("Очистить") { model.clear() }
    }

    private func statusBar(_ rows: [NetworkEntry]) -> some View {
        let transferred = rows.compactMap(\.transferSize).reduce(0, +)
        let resources = rows.compactMap(\.resourceSize).reduce(0, +)
        let span = (rows.compactMap(\.end).max() ?? 0) - (rows.map(\.start).min() ?? 0)
        var parts = ["\(rows.count) из \(model.entries.count) запросов",
                     "передано \(NetworkFormat.bytes(transferred))", "ресурсы \(NetworkFormat.bytes(resources))"]
        if span > 0 { parts.append("готово за \(NetworkFormat.milliseconds(span))") }
        return HStack {
            Text(parts.joined(separator: " · "))
            Spacer()
            if model.throttle != .none { Text(model.throttle.title).foregroundStyle(.orange) }
        }
        .foregroundStyle(Palette.secondaryText)
        .padding(.horizontal, 8)
        .frame(height: 20)
    }

    // MARK: - Helpers

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func symbol(_ kind: NetworkKind) -> String {
        switch kind {
        case .document: "doc.text"
        case .stylesheet: "paintbrush"
        case .script: "curlybraces"
        case .image: "photo"
        case .font: "textformat"
        case .media: "play.rectangle"
        case .fetch, .xhr: "arrow.left.arrow.right"
        case .websocket: "bolt.horizontal"
        case .other: "doc"
        }
    }

    static func shortInitiator(_ initiator: String) -> String {
        guard let url = URL(string: initiator), url.scheme != nil else { return initiator }
        // "https://host/path/app.js:12" → "app.js:12"
        return initiator.split(separator: "/").last.map(String.init) ?? initiator
    }

    static func sizeText(_ entry: NetworkEntry) -> String {
        if entry.kind == .websocket { return "—" }
        if let transfer = entry.transferSize { return transfer == 0 ? "(кэш)" : NetworkFormat.bytes(transfer) }
        return entry.resourceSize.map(NetworkFormat.bytes) ?? "—"
    }

    static func color(_ kind: NetworkKind) -> Color {
        switch kind {
        case .document: .blue
        case .stylesheet: .purple
        case .script: .orange
        case .image: .green
        case .font: .pink
        case .media: .teal
        case .fetch, .xhr: .yellow
        case .websocket: .gray
        case .other: .secondary
        }
    }
}

/// The Водопад cell: the request's span within all visible requests.
private struct NetworkWaterfallBar: View {
    let entry: NetworkEntry
    let start: Double
    let end: Double

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / (end - start)
            let x = (entry.start - start) * scale
            let width = max(2, ((entry.end ?? end) - entry.start) * scale)
            let wait = entry.timings.map { max(0, $0.wait) * scale } ?? 0
            HStack(spacing: 0) {
                // Lighter part: waiting for the first byte; solid: the rest.
                Rectangle().fill(NetworkPanel.color(entry.kind).opacity(0.45)).frame(width: min(wait, width))
                Rectangle().fill(NetworkPanel.color(entry.kind)).frame(width: max(width - wait, 0))
            }
            .opacity(entry.end == nil ? 0.5 : 1)
            .frame(height: 6)
            .offset(x: min(x, max(geometry.size.width - 2, 0)), y: (geometry.size.height - 6) / 2)
        }
        .help(NetworkFormat.milliseconds(entry.duration))
    }
}

/// «Блокировка запросов»: patterns with `*`, each toggled.
private struct NetworkBlockingView: View {
    @Bindable var model: NetworkModel
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Блокировать запросы", isOn: $model.isBlockingOn)
                .toggleStyle(.checkbox)
                .font(.headline)
            Text("Шаблоны URL со знаком *, например *.png или example.com/ads/*. Действуют, пока панель открыта.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.blockPatterns.isEmpty {
                Text("Шаблонов нет").foregroundStyle(.secondary)
            }
            ForEach($model.blockPatterns) { $pattern in
                HStack {
                    Toggle("", isOn: $pattern.isOn).labelsHidden().toggleStyle(.checkbox)
                    TextField("Шаблон", text: $pattern.pattern).textFieldStyle(.roundedBorder)
                    Button { model.blockPatterns.removeAll { $0.id == pattern.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Удалить шаблон")
                }
                .disabled(!model.isBlockingOn)
            }
            HStack {
                TextField("Новый шаблон", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Добавить", action: add).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.ruleListError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        model.block(pattern)
        newPattern = ""
    }
}

/// ⌘F «Поиск»: matches in URLs, headers and bodies, grouped by request.
private struct NetworkSearchView: View {
    @Bindable var model: NetworkModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                Button { model.isSearchVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Закрыть поиск")
            }
            .padding(6)
            Divider()
            let results = model.search()
            List(results) { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.entry.name).bold().lineLimit(1)
                    ForEach(Array(result.matches.prefix(5).enumerated()), id: \.offset) { _, match in
                        Text("\(match.label): \(match.line)")
                            .lineLimit(2)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    if result.matches.count > 5 {
                        Text("ещё \(result.matches.count - 5)").foregroundStyle(Palette.secondaryText)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selection = result.entry.id }
            }
            .listStyle(.plain)
            .overlay {
                if !model.searchText.isEmpty && results.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary) }
            }
        }
        .onAppear { isFocused = true }
    }
}
