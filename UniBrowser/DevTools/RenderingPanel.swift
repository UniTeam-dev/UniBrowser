import AppKit
import SwiftUI
import WebKit

/// Panel «Рендеринг» (spec «Рендеринг»): emulated media, vision deficiency, JavaScript off,
/// geolocation, timezone and locale for this tab until turned off or the tab sleeps/closes.
///
/// Page-side overrides reach every frame twice: a user script at document start that defines
/// `window.__ubRenderingState` before `devtools.js` runs (so they hold on reload, before page
/// scripts), and `rendering.apply` in every frame for the page already shown.
@MainActor
@Observable
final class RenderingModel {
    enum ColorScheme: String, CaseIterable { case none, light, dark }

    struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
        let timezone: String
        let locale: String
    }

    /// Chrome's «Датчики» presets: position, time zone and locale together.
    static let places = [
        Place(name: "Берлин", latitude: 52.520007, longitude: 13.404954, timezone: "Europe/Berlin", locale: "de-DE"),
        Place(name: "Лондон", latitude: 51.507351, longitude: -0.127758, timezone: "Europe/London", locale: "en-GB"),
        Place(name: "Москва", latitude: 55.755826, longitude: 37.6173, timezone: "Europe/Moscow", locale: "ru-RU"),
        Place(name: "Маунтин-Вью", latitude: 37.386052, longitude: -122.083851, timezone: "America/Los_Angeles", locale: "en-US"),
        Place(name: "Мумбаи", latitude: 19.075984, longitude: 72.877656, timezone: "Asia/Kolkata", locale: "mr-IN"),
        Place(name: "Сан-Франциско", latitude: 37.774929, longitude: -122.419416, timezone: "America/Los_Angeles", locale: "en-US"),
        Place(name: "Шанхай", latitude: 31.230416, longitude: 121.473701, timezone: "Asia/Shanghai", locale: "zh-Hans-CN"),
        Place(name: "Сан-Паулу", latitude: -23.55052, longitude: -46.633309, timezone: "America/Sao_Paulo", locale: "pt-BR"),
        Place(name: "Токио", latitude: 35.689487, longitude: 139.691706, timezone: "Asia/Tokyo", locale: "ja-JP"),
    ]
    static let customLocation = "custom"
    static let unavailableLocation = "unavailable"

    var colorScheme = ColorScheme.none { didSet { applyAppearance() } }
    /// "" (no emulation), "reduce", "no-preference".
    var reducedMotion = "" { didSet { push() } }
    /// "" (no emulation), "more", "less", "custom", "no-preference".
    var contrast = "" { didSet { push() } }
    var print = false { didSet { push() } }
    /// "", "blurred", "protanopia", "deuteranopia", "tritanopia", "achromatopsia".
    var vision = "" { didSet { push() } }
    /// Read by `TabWebController` for every navigation (`WKWebpagePreferences`).
    var isJavaScriptDisabled = false {
        didSet { if oldValue != isJavaScriptDisabled { session?.webView?.reload() } }
    }
    /// "" (real position), a place name, `customLocation` or `unavailableLocation`.
    var location = "" { didSet { push() } }
    var latitude = 0.0 { didSet { push() } }
    var longitude = 0.0 { didSet { push() } }
    /// IANA name, e.g. "Europe/Berlin"; "" leaves the system zone.
    var timezone = "" { didSet { push() } }
    /// BCP 47 tag, e.g. "de-DE"; "" leaves the system locale.
    var locale = "" { didSet { push() } }

    @ObservationIgnored private weak var session: DevToolsSession?
    /// Our document-start script in the tab's content controller; nil when nothing is overridden.
    @ObservationIgnored private var script: WKUserScript?

    func bind(_ session: DevToolsSession) {
        self.session = session
    }

    var isTimezoneValid: Bool { timezone.isEmpty || TimeZone(identifier: timezone) != nil }

    func choosePlace(_ name: String) {
        location = name
        guard let place = Self.places.first(where: { $0.name == name }) else { return }
        latitude = place.latitude
        longitude = place.longitude
        timezone = place.timezone
        locale = place.locale
    }

    func reset() {
        colorScheme = .none
        reducedMotion = ""
        contrast = ""
        print = false
        vision = ""
        isJavaScriptDisabled = false
        location = ""
        timezone = ""
        locale = ""
    }

    /// What `devtools.js` reads (`setState` in its rendering region).
    private var state: [String: Any] {
        var media: [String: Any] = [:]
        if !reducedMotion.isEmpty { media["prefers-reduced-motion"] = reducedMotion }
        if !contrast.isEmpty { media["prefers-contrast"] = contrast }
        if print { media["print"] = true }
        var state: [String: Any] = ["media": media]
        if !vision.isEmpty { state["vision"] = vision }
        switch location {
        case "": break
        case Self.unavailableLocation: state["geolocation"] = Self.unavailableLocation
        default: state["geolocation"] = ["latitude": latitude, "longitude": longitude]
        }
        if !timezone.isEmpty { state["timezone"] = timezone }
        if !locale.isEmpty { state["locale"] = locale }
        return state
    }

    private var isDefault: Bool {
        reducedMotion.isEmpty && contrast.isEmpty && !print && vision.isEmpty && location.isEmpty && timezone.isEmpty && locale.isEmpty
    }

    private func applyAppearance() {
        session?.webView?.appearance = switch colorScheme {
        case .none: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func push() {
        guard let session else { return }
        installScript()
        let state = state
        Task { _ = await session.callAll("rendering.apply", args: state) }
    }

    /// Replaces our user script, keeping everyone else's in their order, ours first so it
    /// runs before `devtools.js` in every frame.
    private func installScript() {
        guard let content = session?.webView?.configuration.userContentController else { return }
        let others = content.userScripts.filter { $0 !== script }
        content.removeAllUserScripts()
        script = nil
        if !isDefault,
           let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            let script = WKUserScript(
                source: "Object.defineProperty(window, '__ubRenderingState', { value: \(json), configurable: true });",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
            content.addUserScript(script)
            self.script = script
        }
        others.forEach(content.addUserScript)
    }
}

struct RenderingPanel: View {
    let session: DevToolsSession

    var body: some View {
        @Bindable var model = session.rendering
        Form {
            Section("Эмуляция CSS-медиа") {
                Picker("prefers-color-scheme", selection: $model.colorScheme) {
                    Text("Нет эмуляции").tag(RenderingModel.ColorScheme.none)
                    Text("light").tag(RenderingModel.ColorScheme.light)
                    Text("dark").tag(RenderingModel.ColorScheme.dark)
                }
                Picker("prefers-reduced-motion", selection: $model.reducedMotion) {
                    Text("Нет эмуляции").tag("")
                    Text("reduce").tag("reduce")
                    Text("no-preference").tag("no-preference")
                }
                Picker("prefers-contrast", selection: $model.contrast) {
                    Text("Нет эмуляции").tag("")
                    ForEach(["more", "less", "custom", "no-preference"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("Тип носителя print", isOn: $model.print)
            }
            Section("Нарушения зрения") {
                Picker("Эмуляция", selection: $model.vision) {
                    Text("Нет").tag("")
                    Text("Размытое зрение").tag("blurred")
                    Text("Протанопия (нет красного)").tag("protanopia")
                    Text("Дейтеранопия (нет зелёного)").tag("deuteranopia")
                    Text("Тританопия (нет синего)").tag("tritanopia")
                    Text("Ахроматопсия (нет цвета)").tag("achromatopsia")
                }
            }
            Section("JavaScript") {
                Toggle("Отключить JavaScript", isOn: $model.isJavaScriptDisabled)
                    .help("Страница перезагрузится")
            }
            Section("Датчики и язык") {
                Picker("Местоположение", selection: Binding(get: { model.location }, set: { model.choosePlace($0) })) {
                    Text("Нет переопределения").tag("")
                    ForEach(RenderingModel.places, id: \.name) { Text($0.name).tag($0.name) }
                    Text("Другое…").tag(RenderingModel.customLocation)
                    Text("Позиция недоступна").tag(RenderingModel.unavailableLocation)
                }
                if !model.location.isEmpty, model.location != RenderingModel.unavailableLocation {
                    HStack {
                        TextField("Широта", value: $model.latitude, format: .number.precision(.fractionLength(0...6)))
                        TextField("Долгота", value: $model.longitude, format: .number.precision(.fractionLength(0...6)))
                    }
                    .disabled(model.location != RenderingModel.customLocation)
                }
                HStack {
                    TextField("Часовой пояс", text: $model.timezone, prompt: Text("Системный, например Europe/Berlin"))
                    Menu {
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { id in
                            Button(id) { model.timezone = id }
                        }
                    } label: { Image(systemName: "list.bullet") }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Выбрать часовой пояс")
                }
                if !model.isTimezoneValid {
                    Text("Неизвестный часовой пояс").foregroundStyle(.red).font(.caption)
                }
                TextField("Язык (locale)", text: $model.locale, prompt: Text("Системный, например de-DE"))
                Text("Переопределяются navigator.geolocation, Date, Intl и navigator.language(s) во всех фреймах с начала загрузки; заголовок Accept-Language не меняется.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Сбросить всё") { model.reset() }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 12))
    }
}
