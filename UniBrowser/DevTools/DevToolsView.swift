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

/// Puts a tab's open developer tools beside its page: below, to the right with a
/// draggable divider, or in a separate window.
struct DevToolsDock<Content: View>: View {
    let tab: BrowserTab
    @ViewBuilder let content: Content
    @AppStorage("devToolsDock") private var side = DevToolsDockSide.bottom
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
    @AppStorage("devToolsDock") private var side = DevToolsDockSide.bottom
    @State private var isSettingsVisible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.surface)
    }

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
        let all = DevToolsPanel.allCases
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

    // ponytail: reordering tabs by drag (spec) is not done yet; add when someone misses it.

    private var settings: some View {
        Form {
            Picker("Расположение", selection: $side) {
                ForEach(DevToolsDockSide.allCases) { Text($0.title).tag($0) }
            }
        }
        .padding(16)
        .frame(width: 300)
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
