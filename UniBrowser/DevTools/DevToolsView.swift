import AppKit
import SwiftUI

/// Where the panel sits; one choice for all tabs, kept in UserDefaults.
enum DevToolsDockSide: String, CaseIterable, Identifiable {
    case bottom, right, window

    var id: Self { self }

    var title: String {
        switch self {
        case .bottom: "Снизу"
        case .right: "Справа"
        case .window: "В отдельном окне"
        }
    }

    var symbol: String {
        switch self {
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .window: "macwindow.on.rectangle"
        }
    }
}

/// UserDefaults keys of the panel settings (gear popover, spec «Opening and layout»). Panels
/// read them with `@AppStorage(DevToolsSettings.x)` and the default written next to each key.
enum DevToolsSettings {
    /// `DevToolsDockSide` raw value; default `.bottom`.
    static let dock = "devToolsDock"
    /// Bool, default false: Консоль shows each message's time.
    static let consoleTimestamps = "devToolsConsoleTimestamps"
    /// Bool, default true: Консоль folds identical consecutive messages into one with a count.
    static let consoleGroupSimilar = "devToolsConsoleGroupSimilar"
    /// Bool, default false: what «Сохранять при переходе» starts as in Консоль and Сеть.
    static let preserveLog = "devToolsPreserveLog"
    /// Bool, default false: what «Отключить кэш» starts as in Сеть.
    static let disableCache = "devToolsDisableCache"
    /// Double, default `defaultFontSize`: text size of panel contents. Also given to panels
    /// as `@Environment(\.devToolsFontSize)` and as the default `.font`.
    static let fontSize = "devToolsFontSize"
    static let defaultFontSize = 11.0
    static let fontSizes = 9.0...20.0
    /// Comma-separated `DevToolsPanel` raw values, the header's tab order; empty = default.
    static let tabOrder = "devToolsTabOrder"

    /// The stored order, with panels it doesn't know (added later) at their default place.
    static func panels(order: String) -> [DevToolsPanel] {
        var result: [DevToolsPanel] = []
        for name in order.split(separator: ",") {
            if let panel = DevToolsPanel(rawValue: String(name)), !result.contains(panel) { result.append(panel) }
        }
        for panel in DevToolsPanel.allCases where !result.contains(panel) {
            let index = DevToolsPanel.allCases.firstIndex(of: panel) ?? result.count
            result.insert(panel, at: min(index, result.count))
        }
        return result
    }
}

extension EnvironmentValues {
    /// Text size of panel contents (`DevToolsSettings.fontSize`).
    @Entry var devToolsFontSize = DevToolsSettings.defaultFontSize
}

/// Puts a tab's open developer tools beside its page: below, to the right with a
/// draggable divider, or in a separate window.
struct DevToolsDock<Content: View>: View {
    let tab: BrowserTab
    @ViewBuilder let content: Content
    @AppStorage(DevToolsSettings.dock) private var side = DevToolsDockSide.bottom
    @AppStorage("devToolsHeight") private var height = 300.0
    @AppStorage("devToolsWidth") private var width = 460.0
    @State private var dragStart: Double?

    private static var minSize: Double { 120 }

    var body: some View {
        let session = tab.devTools
        let isOpen = session?.isOpen == true
        let isRight = side == .right
        GeometryReader { geometry in
            let total = isRight ? geometry.size.width : geometry.size.height
            let size = min(max(isRight ? width : height, Self.minSize), max(total - Self.minSize, Self.minSize))
            // AnyLayout keeps the page's identity when the dock side changes.
            let layout = isRight ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                content
                if let session, isOpen, side != .window {
                    divider(isRight: isRight, size: size)
                    DevToolsView(session: session, tab: tab)
                        .frame(width: isRight ? size : nil, height: isRight ? nil : size)
                }
            }
        }
        .onChange(of: isOpen && side == .window, initial: true) { _, windowed in
            guard let session else { return }
            if windowed { DevToolsWindow.show(session, tab: tab) } else { DevToolsWindow.hide(session) }
        }
    }

    private func divider(isRight: Bool, size: Double) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: isRight ? 1 : nil, height: isRight ? nil : 1)
            .padding(isRight ? .horizontal : .vertical, 3)
            .contentShape(Rectangle())
            .padding(isRight ? .horizontal : .vertical, -3)
            .pointerStyle(isRight ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? size
                        dragStart = start
                        if isRight { width = start - value.translation.width } else { height = start - value.translation.height }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel("Граница инструментов разработчика")
    }
}

/// The «В отдельном окне» dock. Closing the window closes the panel.
@MainActor
enum DevToolsWindow {
    static func show(_ session: DevToolsSession, tab: BrowserTab) {
        if let window = session.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Инструменты разработчика — \(tab.displayTitle)"
        window.contentView = NSHostingView(rootView: DevToolsView(session: session, tab: tab))
        window.setFrameAutosaveName("DevToolsWindow")
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak session] _ in
            MainActor.assumeIsolated {
                // Only a close by the user; hide() detaches the window first.
                guard let session, let current = session.window, ObjectIdentifier(current) == id else { return }
                session.window = nil
                session.close()
            }
        }
        session.window = window
        window.makeKeyAndOrderFront(nil)
    }

    static func hide(_ session: DevToolsSession) {
        let window = session.window
        session.window = nil
        window?.close()
    }
}

/// The panel: header with the tab strip and controls, then the selected panel.
struct DevToolsView: View {
    @Bindable var session: DevToolsSession
    let tab: BrowserTab
    @AppStorage(DevToolsSettings.dock) private var side = DevToolsDockSide.bottom
    @AppStorage(DevToolsSettings.tabOrder) private var tabOrder = ""
    @AppStorage(DevToolsSettings.fontSize) private var fontSize = DevToolsSettings.defaultFontSize
    @AppStorage(DevToolsSettings.consoleTimestamps) private var consoleTimestamps = false
    @AppStorage(DevToolsSettings.consoleGroupSimilar) private var consoleGroupSimilar = true
    @AppStorage(DevToolsSettings.preserveLog) private var preserveLog = false
    @AppStorage(DevToolsSettings.disableCache) private var disableCache = false
    @State private var isSettingsVisible = false
    @State private var isCommandMenuVisible = false
    @State private var draggedPanel: DevToolsPanel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panel
                .font(.system(size: fontSize))
                .environment(\.devToolsFontSize, fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
        .background(PanelKeyMonitor { isCommandMenuVisible = true })
        .overlay(alignment: .top) {
            if isCommandMenuVisible {
                DevToolsCommandMenu(commands: commands) { isCommandMenuVisible = false }
                    .padding(.top, 32)
            }
        }
    }

    private var panels: [DevToolsPanel] { DevToolsSettings.panels(order: tabOrder) }

    private var header: some View {
        HStack(spacing: 2) {
            // The longest strip that fits; the rest goes into «»».
            ViewThatFits(in: .horizontal) {
                ForEach((0...DevToolsPanel.allCases.count).reversed(), id: \.self) { visible in
                    tabStrip(visible: visible)
                }
            }
            Spacer(minLength: 8)
            Group {
                Button { tab.deviceMode.isOn.toggle() } label: {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(tab.deviceMode.isOn ? Palette.accent : Palette.secondaryText)
                }
                .help("Режим устройства (⌥⇧⌘M)")
                .accessibilityLabel("Режим устройства")
                Button("Web Inspector") {
                    if let webView = session.webView { WebInspector.show(webView) }
                }
                .help("Открыть Web Inspector WebKit (⌥⌘U)")
                Button { isCommandMenuVisible = true } label: { Image(systemName: "command") }
                    .help("Командное меню (⇧⌘P)")
                    .accessibilityLabel("Командное меню")
                Button { isSettingsVisible.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Настройки")
                    .accessibilityLabel("Настройки")
                    .popover(isPresented: $isSettingsVisible) { settings }
                Menu {
                    Picker("Расположение", selection: $side) {
                        ForEach(DevToolsDockSide.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: side.symbol)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Расположение панели")
                .accessibilityLabel("Расположение панели")
                Button { session.close() } label: { Image(systemName: "xmark") }
                    .help("Закрыть (F12)")
                    .accessibilityLabel("Закрыть инструменты разработчика")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.secondaryText)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    private func tabStrip(visible: Int) -> some View {
        let all = panels
        return HStack(spacing: 0) {
            ForEach(all.prefix(visible)) { panel in
                Button { session.panel = panel } label: {
                    Text(panel.title)
                        .padding(.horizontal, 8)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if session.panel == panel { Rectangle().fill(Palette.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.panel == panel ? Palette.text : Palette.secondaryText)
                .opacity(draggedPanel == panel ? 0.5 : 1)
                // Drag a tab onto another to reorder (spec «Opening and layout»); remembered.
                .onDrag {
                    draggedPanel = panel
                    return NSItemProvider(object: panel.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(target: panel, dragged: $draggedPanel, move: move))
            }
            if visible < all.count {
                Menu("»") {
                    ForEach(all.dropFirst(visible)) { panel in
                        Toggle(panel.title, isOn: Binding(get: { session.panel == panel }, set: { if $0 { session.panel = panel } }))
                    }
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Другие вкладки")
            }
        }
        .fixedSize()
    }

    private func move(_ panel: DevToolsPanel, to target: DevToolsPanel) {
        var order = panels
        guard let from = order.firstIndex(of: panel), let to = order.firstIndex(of: target), from != to else { return }
        order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        tabOrder = order.map(\.rawValue).joined(separator: ",")
    }

    private var settings: some View {
        Form {
            Section("Консоль") {
                Toggle("Показывать время сообщений", isOn: $consoleTimestamps)
                Toggle("Группировать похожие сообщения", isOn: $consoleGroupSimilar)
                Toggle("Сохранять журнал при переходе", isOn: $preserveLog)
            }
            Section("Сеть") {
                Toggle("Сохранять журнал при переходе", isOn: $preserveLog)
                Toggle("Отключать кэш, пока панель открыта", isOn: $disableCache)
            }
            Section("Панель") {
                Picker("Расположение", selection: $side) {
                    ForEach(DevToolsDockSide.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Размер шрифта: \(Int(fontSize)) пт", value: $fontSize, in: DevToolsSettings.fontSizes)
                Button("Вернуть порядок вкладок") { tabOrder = "" }
                    .disabled(tabOrder.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
    }

    @ViewBuilder private var panel: some View {
        switch session.panel {
        case .elements: ElementsPanel(session: session)
        case .console: ConsolePanel(session: session)
        case .sources: SourcesPanel(session: session)
        case .network: NetworkPanel(session: session)
        case .performance: PerformancePanel(session: session)
        case .application: ApplicationPanel(session: session)
        case .rendering: RenderingPanel(session: session)
        case .issues: IssuesPanel(session: session)
        case .security: SecurityPanel(session: session)
        case .coverage: CoveragePanel(session: session)
        case .changes: ChangesPanel(session: session)
        }
    }

    // MARK: Command menu (⇧⌘P)

    /// What ⇧⌘P offers. Entries marked «merge:» toggle the shared default until the panel
    /// that owns the feature exposes its own switch; wire them to it when merging.
    private var commands: [DevToolsCommand] {
        var list: [DevToolsCommand] = panels.map { panel in
            DevToolsCommand(title: "Показать панель «\(panel.title)»", group: "Панель") { session.panel = panel }
        }
        list += DevToolsDockSide.allCases.map { dock in
            DevToolsCommand(title: "Расположение: \(dock.title.lowercased())", group: "Вид") { side = dock }
        }
        list += [
            DevToolsCommand(title: tab.deviceMode.isOn ? "Выключить режим устройства" : "Включить режим устройства", group: "Вид", shortcut: "⇧⌘M") {
                tab.deviceMode.isOn.toggle()
            },
            DevToolsCommand(title: "Выбрать элемент на странице", group: "Элементы", shortcut: "⇧⌘C") {
                session.panel = .elements
                session.elements.pick()
            },
            DevToolsCommand(title: "Очистить консоль", group: "Консоль") { session.console.clear() },
            DevToolsCommand(title: consoleTimestamps ? "Скрыть время сообщений" : "Показывать время сообщений", group: "Консоль") {
                consoleTimestamps.toggle()
            },
            DevToolsCommand(title: consoleGroupSimilar ? "Не группировать похожие сообщения" : "Группировать похожие сообщения", group: "Консоль") {
                consoleGroupSimilar.toggle()
            },
            // merge: wire to the Console/Network preserve-log switch (it starts from this default).
            DevToolsCommand(title: preserveLog ? "Не сохранять журнал при переходе" : "Сохранять журнал при переходе", group: "Консоль и сеть") {
                preserveLog.toggle()
            },
            // merge: wire to the Network «Отключить кэш» switch (it starts from this default).
            DevToolsCommand(title: disableCache ? "Включить кэш" : "Отключить кэш", group: "Сеть") { disableCache.toggle() },
            DevToolsCommand(title: "Жёсткая перезагрузка", group: "Страница", shortcut: "⇧⌘R") { session.webView?.reloadFromOrigin() },
            DevToolsCommand(title: session.performance.isRecording ? "Остановить запись производительности" : "Записать производительность", group: "Производительность") {
                session.panel = .performance
                Task { session.performance.isRecording ? await session.performance.stop() : await session.performance.start() }
            },
            DevToolsCommand(title: "Перезагрузить и записать производительность", group: "Производительность") {
                session.panel = .performance
                session.performance.reloadAndRecord()
            },
            DevToolsCommand(title: session.coverage.isRecording ? "Остановить запись покрытия" : "Записать покрытие CSS", group: "Покрытие") {
                session.panel = .coverage
                Task { session.coverage.isRecording ? await session.coverage.stop() : await session.coverage.start() }
            },
            DevToolsCommand(title: "Открыть Web Inspector", group: "Web Inspector", shortcut: "⌥⌘U") {
                if let webView = session.webView { WebInspector.show(webView) }
            },
            DevToolsCommand(title: "Профиль JavaScript и память в Web Inspector", group: "Web Inspector") {
                if let webView = session.webView { WebInspector.profile(webView) }
            },
            DevToolsCommand(title: "Увеличить шрифт панели", group: "Вид") {
                fontSize = min(fontSize + 1, DevToolsSettings.fontSizes.upperBound)
            },
            DevToolsCommand(title: "Уменьшить шрифт панели", group: "Вид") {
                fontSize = max(fontSize - 1, DevToolsSettings.fontSizes.lowerBound)
            },
            DevToolsCommand(title: "Обычный размер шрифта панели", group: "Вид") { fontSize = DevToolsSettings.defaultFontSize },
            DevToolsCommand(title: "Вернуть порядок вкладок", group: "Вид") { tabOrder = "" },
            DevToolsCommand(title: "Настройки инструментов разработчика", group: "Вид") { isSettingsVisible = true },
            DevToolsCommand(title: "Закрыть инструменты разработчика", group: "Вид", shortcut: "F12") { session.close() },
        ]
        return list
    }
}

/// Live reorder while a tab is dragged over another.
private struct TabDropDelegate: DropDelegate {
    let target: DevToolsPanel
    @Binding var dragged: DevToolsPanel?
    let move: (DevToolsPanel, DevToolsPanel) -> Void

    func dropEntered(info: DropInfo) {
        if let dragged, dragged != target { move(dragged, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// One entry of the ⇧⌘P menu.
struct DevToolsCommand: Identifiable {
    var id: String { title }
    let title: String
    let group: String
    var shortcut: String?
    let run: () -> Void
}

/// The panel's command menu: type to filter, ↑/↓ to choose, ↩ to run, Esc to close.
private struct DevToolsCommandMenu: View {
    let commands: [DevToolsCommand]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var isFocused: Bool

    /// Every word of the query is in the title or the group.
    private var matches: [DevToolsCommand] {
        let words = query.lowercased().split(separator: " ")
        return commands.filter { command in
            let text = (command.title + " " + command.group).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            TextField("Команда или панель", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .focused($isFocused)
                .onSubmit { run(matches) }
                .onKeyPress(.downArrow) { index = min(index + 1, max(matches.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onChange(of: query) { index = 0 }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { offset, command in
                            HStack {
                                Text(command.group).foregroundStyle(.secondary).frame(width: 120, alignment: .leading).lineLimit(1)
                                Text(command.title).lineLimit(1)
                                Spacer()
                                if let shortcut = command.shortcut { Text(shortcut).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(offset == index ? Palette.accent.opacity(0.2) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { index = offset; run(matches) }
                            .id(offset)
                        }
                        if matches.isEmpty {
                            Text("Ничего не найдено").foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .onChange(of: index) { proxy.scrollTo(index) }
            }
            .frame(maxHeight: 280)
        }
        .font(.system(size: 12))
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Palette.dimmed) }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .onAppear { isFocused = true }
        .onExitCommand(perform: dismiss)
        .onChange(of: isFocused) { _, focused in if !focused { dismiss() } }
    }

    private func run(_ matches: [DevToolsCommand]) {
        guard matches.indices.contains(index) else { return }
        dismiss()
        matches[index].run()
    }
}

/// ⇧⌘P while the panel has focus (spec «Opening and layout»): the last click in this window
/// was inside the panel, or the panel is the whole window. Elsewhere ⇧⌘P stays the menu's.
/// A local monitor runs before menu key equivalents, so it wins only in that case.
private struct PanelKeyMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.action = action }

    final class MonitorView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?
        private var hasFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            hasFocus = false
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseDown {
                hasFocus = inside
                return event
            }
            let isWholeWindow = window.contentView.map { bounds.size == $0.bounds.size } ?? false
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "p",
                  hasFocus || isWholeWindow
            else { return event }
            action()
            return nil
        }
    }
}

/// What a panel shows until it is built.
struct DevToolsPlaceholder: View {
    let panel: DevToolsPanel

    var body: some View {
        Text("Панель «\(panel.title)» ещё не готова")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
