import SwiftUI
import WebKit

/// «Режим устройства» of one tab (spec «Режим устройства»): stays on with the panel closed
/// and across sleep, so it lives on `BrowserTab`, not on the session. ⌥⇧⌘M and the panel
/// header button toggle it; `DeviceFrame` draws it.
@MainActor
@Observable
final class DeviceMode {
    struct Preset: Hashable, Identifiable {
        let name: String
        /// CSS pixels, portrait.
        let width: Int
        let height: Int
        let userAgent: String?

        var id: String { name }
    }

    private static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let iPad = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static func android(_ model: String) -> String {
        "Mozilla/5.0 (Linux; Android 14; \(model)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    }

    static let responsive = Preset(name: "Адаптивный", width: 0, height: 0, userAgent: nil)
    static let presets = [
        Preset(name: "iPhone SE", width: 375, height: 667, userAgent: iPhone),
        Preset(name: "iPhone 15", width: 393, height: 852, userAgent: iPhone),
        Preset(name: "iPhone 15 Pro Max", width: 430, height: 932, userAgent: iPhone),
        Preset(name: "iPad mini", width: 744, height: 1133, userAgent: iPad),
        Preset(name: "iPad Pro 11", width: 834, height: 1194, userAgent: iPad),
        Preset(name: "Pixel 8", width: 412, height: 915, userAgent: android("Pixel 8")),
        Preset(name: "Galaxy S23", width: 360, height: 780, userAgent: android("SM-S911B")),
        responsive,
    ]
    static let zooms = [0.5, 0.75, 1, 1.25, 1.5]

    var isOn = false
    private(set) var preset = DeviceMode.responsive
    /// The emulated viewport as typed; `size` is what is used.
    var width = 400
    var height = 800
    /// 0 fits the frame into the page card (never above 100 %).
    var zoom = 0.0

    func choose(_ preset: Preset) {
        self.preset = preset
        if preset != Self.responsive {
            width = preset.width
            height = preset.height
        }
    }

    func rotate() { (width, height) = (height, width) }

    /// The emulated viewport in CSS pixels.
    var size: CGSize { CGSize(width: min(max(width, 50), 4000), height: min(max(height, 50), 4000)) }

    /// What `customUserAgent` should be: the preset's while on, WebKit's own otherwise.
    var userAgent: String? { isOn ? preset.userAgent : nil }

    /// The factor the frame is drawn at in `size`; also the page zoom, so the page lays out
    /// `width` CSS pixels wide in a view `width × scale` points wide.
    func scale(in size: CGSize) -> Double {
        if zoom > 0 { return zoom }
        let fit = min((size.width - 24) / self.size.width, (size.height - 24) / self.size.height)
        return min(max(fit, 0.1), 1)
    }
}

/// The page area of `TabPane`: the web view as is, or with device mode on, the toolbar and
/// the web view framed to the device size, centered and scaled to fit.
struct DeviceFrame<Content: View>: View {
    let tab: BrowserTab
    @ViewBuilder let content: Content

    var body: some View {
        let mode = tab.deviceMode
        VStack(spacing: 0) {
            if mode.isOn {
                DeviceToolbar(mode: mode)
                Divider()
            }
            GeometryReader { geometry in
                let scale = mode.isOn ? mode.scale(in: geometry.size) : 1
                // `content` keeps one place in the tree either way, so the web view is not re-hosted.
                content
                    .frame(
                        width: mode.isOn ? mode.size.width * scale : geometry.size.width,
                        height: mode.isOn ? mode.size.height * scale : geometry.size.height
                    )
                    .overlay {
                        if mode.isOn { Rectangle().stroke(Color.primary.opacity(0.18)) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onChange(of: [scale, tab.isAsleep ? 0 : 1], initial: true) {
                        if let webView = tab.webView, webView.pageZoom != scale { webView.pageZoom = scale }
                    }
            }
            .clipped()
            .background(mode.isOn ? Palette.surfaceAlt : Color.clear)
        }
        .onChange(of: "\(mode.userAgent ?? "")|\(tab.isAsleep)", initial: true) {
            applyUserAgent(mode.userAgent)
        }
    }

    /// The page reloads when the user agent changes, so the server sees the new one too.
    private func applyUserAgent(_ userAgent: String?) {
        guard let webView = tab.webView else { return }
        let current = webView.customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
        guard current != userAgent else { return }
        webView.customUserAgent = userAgent
        if webView.url != nil { webView.reload() }
    }
}

private struct DeviceToolbar: View {
    @Bindable var mode: DeviceMode

    var body: some View {
        HStack(spacing: 8) {
            Picker("Устройство", selection: Binding(get: { mode.preset }, set: { mode.choose($0) })) {
                ForEach(DeviceMode.presets) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 4) {
                TextField("Ширина", value: $mode.width, format: .number.grouping(.never))
                    .frame(width: 52)
                Text("×").foregroundStyle(Palette.secondaryText)
                TextField("Высота", value: $mode.height, format: .number.grouping(.never))
                    .frame(width: 52)
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .disabled(mode.preset != DeviceMode.responsive)
            Button { mode.rotate() } label: { Image(systemName: "rotate.right") }
                .buttonStyle(.borderless)
                .help("Повернуть")
                .accessibilityLabel("Повернуть")
            Picker("Масштаб", selection: $mode.zoom) {
                Text("Вписать").tag(0.0)
                ForEach(DeviceMode.zooms, id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button { mode.isOn = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Выключить режим устройства (⌥⇧⌘M)")
                .accessibilityLabel("Выключить режим устройства")
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Palette.surface)
    }
}
