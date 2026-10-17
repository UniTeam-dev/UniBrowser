import AppKit
import SwiftUI
import WebKit

/// The side panes of «Элементы» for the selected node (spec «Элементы», side panes).
enum ElementsPane: String, CaseIterable, Identifiable {
    case styles, computed, layout, listeners, properties, accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .styles: "Стили"
        case .computed: "Вычисленные"
        case .layout: "Макет"
        case .listeners: "Обработчики событий"
        case .properties: "Свойства"
        case .accessibility: "Доступность"
        }
    }
}

/// What `elements.styles` returns.
struct StylesData: Decodable {
    struct Section: Decodable {
        let title: String?
        let handle: Int?
        let rules: [Rule]
    }

    struct Rule: Decodable {
        let h: Int
        let selector: String
        let inline: Bool?
        let media: String
        let source: String
        let resource: String?
        let props: [Property]
    }

    struct Property: Decodable {
        let name: String
        let value: String
        let important: Bool
        let disabled: Bool?
        let overridden: Bool?
        let inactive: Bool?
        let colors: [ColorToken]
    }

    struct ColorToken: Decodable {
        let text: String
        let rgba: [Double]
    }

    let sections: [Section]
    let unavailable: [String]
    let classes: [ClassItem]
    let forced: [String]

    struct ClassItem: Decodable {
        let name: String
        let on: Bool
    }
}

struct ElementsSidebar: View {
    let model: ElementsModel
    @AppStorage("devToolsElementsPane") private var pane = ElementsPane.styles

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(ElementsPane.allCases) { item in
                        Button { pane = item } label: {
                            Text(item.title)
                                .padding(.horizontal, 7)
                                .frame(maxHeight: .infinity)
                                .overlay(alignment: .bottom) {
                                    if pane == item { Rectangle().fill(Palette.accent).frame(height: 2) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(pane == item ? Palette.text : Palette.secondaryText)
                    }
                }
            }
            .font(.system(size: 11))
            .frame(height: 28)
            Divider()
            if let key = model.selected {
                Group {
                    switch pane {
                    case .styles: StylesPane(model: model, key: key)
                    case .computed: ComputedPane(model: model, key: key)
                    case .layout: LayoutPane(model: model)
                    case .listeners: ListenersPane(model: model, key: key)
                    case .properties: PropertiesPane(model: model, key: key)
                    case .accessibility: AccessibilityPane(model: model, key: key)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Выберите узел в дереве")
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
    }
}

/// Reload trigger for a pane: the node and the model's revision.
private struct Reload: Hashable {
    let key: DOMKey
    let revision: Int
}

private let mono = Font.system(size: 11, design: .monospaced)

// MARK: - Стили

private struct StylesPane: View {
    let model: ElementsModel
    let key: DOMKey
    @State private var data: StylesData?
    @State private var filter = ""
    @State private var isStatesVisible = false
    @State private var isClassesVisible = false
    @State private var newClass = ""
    @State private var editing: Field?

    /// What is being edited inline: a rule's selector, a property's name or value, or a new property.
    enum Field: Equatable {
        case selector(Int)
        case name(Int, String)
        case value(Int, String)
        case add(Int)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if isStatesVisible { states }
            if isClassesVisible { classes }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((data?.sections ?? []).enumerated()), id: \.offset) { _, section in
                        if let title = section.title {
                            HStack(spacing: 4) {
                                Text("Унаследовано от")
                                Button(title) { if let handle = section.handle { Task { await model.reveal(DOMKey(frame: key.frame, handle: handle)) } } }
                                    .buttonStyle(.link)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.surfaceAlt)
                        }
                        ForEach(Array(section.rules.enumerated()), id: \.offset) { _, rule in
                            if filter.isEmpty || rule.props.contains(where: matches) || rule.selector.localizedCaseInsensitiveContains(filter) {
                                ruleView(rule)
                                Divider()
                            }
                        }
                    }
                    ForEach(data?.unavailable ?? [], id: \.self) { href in
                        Text("Правила из \(href) недоступны: таблица стилей с другого источника")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondaryText)
                            .padding(8)
                    }
                }
            }
        }
        .task(id: Reload(key: key, revision: model.revision)) { data = await model.styles(key) }
    }

    private func matches(_ property: StylesData.Property) -> Bool {
        property.name.localizedCaseInsensitiveContains(filter) || property.value.localizedCaseInsensitiveContains(filter)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            TextField("Фильтр", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Toggle(":hov", isOn: $isStatesVisible)
                .toggleStyle(.button)
                .help("Принудительное состояние элемента")
            Toggle(".cls", isOn: $isClassesVisible)
                .toggleStyle(.button)
                .help("Классы элемента")
            Button { model.frameCall(key.frame, "addRule", ["handle": key.handle]) } label: { Image(systemName: "plus") }
                .help("Новое правило для этого элемента")
                .accessibilityLabel("Новое правило")
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .padding(6)
    }

    private var states: some View {
        let forced = Set(data?.forced ?? [])
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 2) {
            ForEach(ForcedState.allCases) { state in
                Toggle(":\(state.rawValue)", isOn: Binding(
                    get: { forced.contains(state.rawValue) },
                    set: { on in model.forceState(key, Array(on ? forced.union([state.rawValue]) : forced.subtracting([state.rawValue]))) }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .font(mono)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var classes: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Добавить новый класс", text: $newClass)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    for name in newClass.split(separator: " ") { model.setClass(key, String(name), on: true) }
                    newClass = ""
                }
            FlowLayout(spacing: 8) {
                ForEach(data?.classes ?? [], id: \.name) { item in
                    Toggle(item.name, isOn: Binding(get: { item.on }, set: { model.setClass(key, item.name, on: $0) }))
                        .toggleStyle(.checkbox)
                }
            }
            .font(mono)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder private func ruleView(_ rule: StylesData.Rule) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !rule.media.isEmpty {
                Text(rule.media).font(.system(size: 10)).foregroundStyle(Palette.secondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if editing == .selector(rule.h) {
                    InlineEditor(text: rule.selector) { text in
                        editing = nil
                        model.frameCall(key.frame, "setSelector", ["rule": rule.h, "text": text])
                    } cancel: { editing = nil }
                } else {
                    Text(rule.selector)
                        .foregroundStyle(rule.inline == true ? Palette.text : MarkupColor.tag)
                        .onTapGesture(count: 2) { if rule.inline != true { editing = .selector(rule.h) } }
                }
                Text(" {")
                Spacer(minLength: 8)
                if !rule.source.isEmpty {
                    Text(rule.source)
                        .foregroundStyle(Palette.secondaryText)
                        .underline()
                        .lineLimit(1)
                        .help(rule.resource ?? rule.source)
                        .textSelection(.enabled)
                }
            }
            ForEach(Array(rule.props.enumerated()), id: \.offset) { _, property in
                if filter.isEmpty || matches(property) { propertyLine(rule, property) }
            }
            if editing == .add(rule.h) {
                InlineEditor(text: "", placeholder: "свойство: значение") { text in
                    editing = nil
                    model.frameCall(key.frame, "addProperties", ["rule": rule.h, "text": text])
                } cancel: { editing = nil }
                .padding(.leading, 18)
            }
            Text("}")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { editing = .add(rule.h) }
                .help("Щёлкните, чтобы добавить свойство")
        }
        .font(mono)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder private func propertyLine(_ rule: StylesData.Rule, _ property: StylesData.Property) -> some View {
        let struck = property.overridden == true || property.disabled == true
        let important = property.important ? " !important" : ""
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Toggle("", isOn: Binding(
                get: { property.disabled != true },
                set: { model.frameCall(key.frame, "toggleProperty", ["rule": rule.h, "name": property.name, "on": $0]) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .labelsHidden()
            .padding(.trailing, 4)
            if editing == .name(rule.h, property.name) {
                InlineEditor(text: property.name) { name in
                    editing = nil
                    model.frameCall(key.frame, "setProperty", ["rule": rule.h, "name": name, "value": property.value + important, "oldName": property.name])
                } cancel: { editing = nil }
            } else {
                Text(property.name)
                    .foregroundStyle(MarkupColor.attribute)
                    .strikethrough(struck)
                    .onTapGesture(count: 2) { editing = .name(rule.h, property.name) }
            }
            Text(": ")
            if let color = property.colors.first {
                ColorSwatch(token: color) { css in
                    // The value as it is now, with this colour token replaced.
                    var value = property.value
                    if let range = value.range(of: color.text) { value.replaceSubrange(range, with: css) }
                    model.frameCall(key.frame, "setProperty", ["rule": rule.h, "name": property.name, "value": value + important, "oldName": ""])
                }
                .padding(.trailing, 3)
            }
            if editing == .value(rule.h, property.name) {
                InlineEditor(text: property.value + important) { value in
                    editing = nil
                    model.frameCall(key.frame, "setProperty", ["rule": rule.h, "name": property.name, "value": value, "oldName": ""])
                } cancel: { editing = nil }
            } else {
                Text(property.value + important)
                    .foregroundStyle(Palette.text)
                    .strikethrough(struck)
                    .onTapGesture(count: 2) { editing = .value(rule.h, property.name) }
            }
            Text(";")
        }
        .opacity(property.inactive == true ? 0.45 : 1)
        .padding(.leading, 4)
    }
}

/// A colour square; click opens the system colour panel (with its eyedropper).
private struct ColorSwatch: View {
    let token: StylesData.ColorToken
    let change: (String) -> Void
    @State private var current: String?

    var body: some View {
        let rgba = token.rgba + [1, 1, 1, 1]
        let color = NSColor(srgbRed: rgba[0] / 255, green: rgba[1] / 255, blue: rgba[2] / 255, alpha: rgba[3])
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(nsColor: color))
            .frame(width: 10, height: 10)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.3), lineWidth: 0.5))
            .onTapGesture {
                ColorPanelBridge.shared.open(color) { picked in change(ColorPanelBridge.css(picked)) }
            }
            .help("Выбрать цвет")
            .accessibilityLabel("Цвет \(token.text)")
            .accessibilityAddTraits(.isButton)
    }
}

/// Target-action glue for `NSColorPanel.shared`; one edit at a time.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(_ color: NSColor, onChange: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        self.onChange = nil
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) { onChange?(panel.color) }

    static func css(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((srgb.redComponent * 255).rounded()), g = Int((srgb.greenComponent * 255).rounded()), b = Int((srgb.blueComponent * 255).rounded())
        if srgb.alphaComponent >= 0.999 { return String(format: "#%02x%02x%02x", r, g, b) }
        return "rgba(\(r), \(g), \(b), \(String(format: "%.2f", srgb.alphaComponent)))"
    }
}

/// Wraps children into rows, for the class toggles.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(width: bounds.width, subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 2; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x)
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - Вычисленные

private struct ComputedData: Decodable {
    struct Box: Decodable {
        let margin, border, padding: [Double]
        let width, height: Double
        let position: [String]?
        let kind: String
    }

    let props: [[String]]
    let box: Box
}

private struct ComputedPane: View {
    let model: ElementsModel
    let key: DOMKey
    @State private var data: ComputedData?
    @State private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let box = data?.box { BoxModelView(box: box).padding(.top, 8).frame(maxWidth: .infinity) }
                TextField("Фильтр", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(data?.props ?? [], id: \.self) { pair in
                        if pair.count == 2, filter.isEmpty || pair[0].localizedCaseInsensitiveContains(filter) || pair[1].localizedCaseInsensitiveContains(filter) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(pair[0]).foregroundStyle(MarkupColor.attribute)
                                Text(": ")
                                Text(pair[1]).foregroundStyle(Palette.text).textSelection(.enabled)
                            }
                            .font(mono)
                            .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .task(id: Reload(key: key, revision: model.revision)) {
            data = DevToolsJSON.decode(ComputedData.self, from: await model.call(key, "computed"))
        }
    }
}

/// Chrome's box model diagram: position, margin, border, padding, content.
private struct BoxModelView: View {
    let box: ComputedData.Box

    var body: some View {
        let content = Text("\(number(box.width)) × \(number(box.height))")
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(red: 111 / 255, green: 168 / 255, blue: 220 / 255).opacity(0.66))
        let padded = layer("padding", box.padding, Color(red: 147 / 255, green: 196 / 255, blue: 125 / 255).opacity(0.55), content)
        let bordered = layer("border", box.border, Color(red: 1, green: 229 / 255, blue: 153 / 255).opacity(0.66), padded)
        let margined = layer("margin", box.margin, Color(red: 246 / 255, green: 178 / 255, blue: 107 / 255).opacity(0.66), bordered)
        Group {
            if let position = box.position {
                layer(box.kind, position.map { Double($0.replacingOccurrences(of: "px", with: "")) ?? 0 }, .clear, margined, dashed: true)
            } else {
                margined
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.black.opacity(0.8))
    }

    private func number(_ value: Double) -> String {
        value == 0 ? "–" : value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func layer(_ label: String, _ values: [Double], _ color: Color, _ inner: some View, dashed: Bool = false) -> some View {
        let v = values + [0, 0, 0, 0]
        return VStack(spacing: 2) {
            HStack {
                Text(label).foregroundStyle(dashed ? Palette.secondaryText : Color.black.opacity(0.6))
                Spacer()
            }
            Text(number(v[0]))
            HStack(spacing: 6) {
                Text(number(v[3]))
                inner
                Text(number(v[1]))
            }
            Text(number(v[2]))
        }
        .padding(4)
        .background(color)
        .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: dashed ? [3] : [])).foregroundStyle(Color.primary.opacity(0.35)))
    }
}

// MARK: - Макет

private struct LayoutItem: Decodable {
    let h: Int
    let label: String
    let kind: String
    let on: Bool
}

private struct LayoutPane: View {
    let model: ElementsModel
    @State private var items: [(frame: String, item: LayoutItem)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                section("Grid", kind: "grid")
                section("Flexbox", kind: "flex")
            }
            .padding(8)
        }
        .task(id: model.revision) { await load() }
    }

    private func load() async {
        guard let session = model.session else { return }
        var result: [(String, LayoutItem)] = []
        for (frame, value) in await session.callAll("elements.layout") {
            for item in DevToolsJSON.decode([LayoutItem].self, from: value ?? nil) ?? [] { result.append((frame, item)) }
        }
        items = result.sorted { ($0.0 == session.topFrame ? 0 : 1, $0.0) < ($1.0 == session.topFrame ? 0 : 1, $1.0) }
    }

    @ViewBuilder private func section(_ title: String, kind: String) -> some View {
        let list = items.filter { $0.item.kind == kind }
        Text(title).font(.system(size: 11, weight: .semibold)).padding(.top, 4)
        if list.isEmpty {
            Text("Нет контейнеров").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
        }
        ForEach(list, id: \.item.h) { entry in
            let key = DOMKey(frame: entry.frame, handle: entry.item.h)
            HStack(spacing: 4) {
                Toggle("", isOn: Binding(get: { entry.item.on }, set: { on in
                    Task {
                        await model.call(key, "layoutOverlay", ["on": on])
                        await load()
                    }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                Button(entry.item.label) { Task { await model.reveal(key) } }
                    .buttonStyle(.link)
                    .font(mono)
                    .lineLimit(1)
            }
            .onHover { model.hover($0 ? key : nil) }
        }
    }
}

// MARK: - Обработчики событий

private struct ListenerItem: Decodable {
    let type: String
    let target: String
    let th: Int
    let fh: Int
    let capture: Bool?
    let once: Bool?
    let passive: Bool?
    let property: Bool?
    let source: String
}

private struct ListenersPane: View {
    let model: ElementsModel
    let key: DOMKey
    @AppStorage("devToolsListenersAncestors") private var ancestors = true
    @State private var items: [ListenerItem] = []
    @State private var reload = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Предки", isOn: $ancestors).toggleStyle(.checkbox)
                Spacer()
                Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Обновить")
            }
            .font(.system(size: 11))
            .padding(6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if items.isEmpty {
                        Text("Нет обработчиков").foregroundStyle(Palette.secondaryText).padding(8)
                    }
                    ForEach(Dictionary(grouping: items, by: \.type).sorted { $0.key < $1.key }, id: \.key) { type, list in
                        DisclosureGroup {
                            ForEach(Array(list.enumerated()), id: \.offset) { _, item in row(item) }
                        } label: {
                            Text(type).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .task(id: [AnyHashable(Reload(key: key, revision: model.revision)), ancestors, reload]) {
            items = DevToolsJSON.decode([ListenerItem].self, from: await model.call(key, "listeners", ["ancestors": ancestors])) ?? []
        }
    }

    private func row(_ item: ListenerItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.target).foregroundStyle(MarkupColor.tag)
                if item.property == true { Text("on\(item.type)").foregroundStyle(Palette.secondaryText) }
                if item.capture == true { Text("capture").foregroundStyle(Palette.secondaryText) }
                if item.passive == true { Text("passive").foregroundStyle(Palette.secondaryText) }
                if item.once == true { Text("once").foregroundStyle(Palette.secondaryText) }
                Spacer()
                Button("Удалить") {
                    model.frameCall(key.frame, "removeListener", ["target": item.th, "fn": item.fh, "type": item.type, "capture": item.capture ?? false, "property": item.property ?? false])
                }
                .buttonStyle(.link)
            }
            Text(item.source)
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(mono)
        .padding(.leading, 12)
        .padding(.vertical, 3)
    }
}

// MARK: - Свойства

/// `ub.preview` at depth 0.
struct DevToolsPreview: Decodable {
    let type: String
    let text: String
    let handle: Int?
}

private struct PropertyEntry: Decodable {
    let key: String
    let value: DevToolsPreview
}

private struct PropertiesPane: View {
    let model: ElementsModel
    let key: DOMKey

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            PropertyChildren(model: model, frame: key.frame, handle: key.handle)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(Reload(key: key, revision: model.revision))
    }
}

private struct PropertyChildren: View {
    let model: ElementsModel
    let frame: String
    let handle: Int
    @State private var entries: [PropertyEntry]?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            if let entries {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    PropertyRow(model: model, frame: frame, entry: entry)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            entries = DevToolsJSON.decode([PropertyEntry].self, from: await model.call(DOMKey(frame: frame, handle: handle), "properties")) ?? []
        }
    }
}

private struct PropertyRow: View {
    let model: ElementsModel
    let frame: String
    let entry: PropertyEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                if let handle = entry.value.handle, entry.value.type != "function" || isExpanded {
                    Image(systemName: isExpanded ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(width: 10)
                        .onTapGesture { isExpanded.toggle() }
                        .accessibilityLabel(isExpanded ? "Свернуть" : "Развернуть")
                        .id(handle)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Text(entry.key).foregroundStyle(MarkupColor.attribute)
                Text(": ")
                Text(clipped(entry.value.text)).foregroundStyle(color(entry.value.type)).textSelection(.enabled)
            }
            .font(mono)
            .lineLimit(1)
            if isExpanded, let handle = entry.value.handle {
                PropertyChildren(model: model, frame: frame, handle: handle).padding(.leading, 14)
            }
        }
    }

    private func clipped(_ text: String) -> String {
        let shown = entry.value.type == "string" ? "\"\(text)\"" : text
        return shown.count > 200 ? String(shown.prefix(200)) + "…" : shown
    }

    private func color(_ type: String) -> Color {
        switch type {
        case "string": MarkupColor.value
        case "number", "boolean", "bigint": Color(light: "#1C00CF", dark: "#9980FF")
        case "null", "undefined": Palette.secondaryText
        case "node": MarkupColor.tag
        default: Palette.text
        }
    }
}

// MARK: - Доступность

private struct AccessibilityData: Decodable {
    struct Ancestor: Decodable {
        let h: Int
        let role: String
        let name: String
    }

    let role: String
    let name: String
    let source: String
    let description: String
    let properties: [[String]]
    let chain: [Ancestor]
}

private struct AccessibilityPane: View {
    let model: ElementsModel
    let key: DOMKey
    @State private var data: AccessibilityData?

    var body: some View {
        ScrollView {
            if let data {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        line("Роль", data.role)
                        line("Имя", data.name.isEmpty ? "—" : "\"\(data.name)\"" + (data.source.isEmpty ? "" : "  (из \(data.source))"))
                        line("Описание", data.description.isEmpty ? "—" : data.description)
                        ForEach(data.properties, id: \.self) { pair in
                            if pair.count == 2 { line(pair[0], pair[1]) }
                        }
                    }
                    Text("Дерево доступности").font(.system(size: 11, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(data.chain.enumerated()), id: \.offset) { index, ancestor in
                            Button {
                                Task { await model.reveal(DOMKey(frame: key.frame, handle: ancestor.h)) }
                            } label: {
                                Text(ancestor.role).foregroundStyle(MarkupColor.tag) + Text(ancestor.name.isEmpty ? "" : " \"\(ancestor.name)\"").foregroundStyle(Palette.text)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, CGFloat(index) * 10)
                        }
                        (Text(data.role).foregroundStyle(MarkupColor.tag).bold() + Text(data.name.isEmpty ? "" : " \"\(data.name)\""))
                            .padding(.leading, CGFloat(data.chain.count) * 10)
                    }
                    .font(mono)
                    .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Нет данных для этого узла").foregroundStyle(Palette.secondaryText).padding(8)
            }
        }
        .task(id: Reload(key: key, revision: model.revision)) {
            data = DevToolsJSON.decode(AccessibilityData.self, from: await model.call(key, "accessibility"))
        }
    }

    private func line(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(Palette.secondaryText)
            Text(value).foregroundStyle(Palette.text).textSelection(.enabled)
        }
        .font(.system(size: 11))
    }
}

// MARK: - DOM breakpoints through Web Inspector

/// «Остановиться при …»: sets the DOM breakpoint in WebKit's Web Inspector, which is
/// what can pause the page. Works for nodes of the main frame (the inspector frontend
/// finds the node by a temporary attribute); for other frames the menu is not shown.
@MainActor
enum DOMBreakpoints {
    enum Kind: String, CaseIterable, Identifiable {
        case subtree = "subtree-modified", attribute = "attribute-modified", removal = "node-removed"

        var id: Self { self }

        var title: String {
            switch self {
            case .subtree: "Изменении поддерева"
            case .attribute: "Изменении атрибутов"
            case .removal: "Удалении узла"
            }
        }
    }

    private static func inspector(_ webView: WKWebView?) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard let webView, webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    static func isAvailable(_ webView: WKWebView?) -> Bool {
        inspector(webView)?.responds(to: NSSelectorFromString("inspectorWebView")) == true
    }

    static func set(_ kind: Kind, on key: DOMKey, model: ElementsModel) {
        guard let session = model.session, key.frame == session.topFrame, let webView = session.webView else {
            model.error = "Точки останова на узлах работают только для основного фрейма"
            return
        }
        Task {
            let token = UUID().uuidString
            await model.call(key, "mark", ["token": token])
            WebInspector.show(webView)
            do {
                guard let frontend = await frontend(of: webView) else { throw BreakpointError.noFrontend }
                // Find the node first, then drop the marker, so removing it does not trip
                // an attribute breakpoint.
                _ = try await frontend.callAsyncJavaScript(findNode, arguments: ["selector": "[data-ub-break=\"\(token)\"]"], contentWorld: .page)
                await model.call(key, "mark", ["token": ""])
                _ = try await frontend.callAsyncJavaScript(addBreakpoint, arguments: ["type": kind.rawValue], contentWorld: .page)
            } catch {
                await model.call(key, "mark", ["token": ""])
                model.error = "Web Inspector не принял точку останова: \(error.localizedDescription)"
            }
        }
    }

    private enum BreakpointError: LocalizedError {
        case noFrontend
        var errorDescription: String? { "Web Inspector не открылся" }
    }

    /// The inspector's own web view once its frontend (`WI`) has loaded.
    private static func frontend(of webView: WKWebView) async -> WKWebView? {
        for _ in 0..<50 {
            if let view = inspector(webView)?.value(forKey: "inspectorWebView") as? WKWebView,
               (try? await view.callAsyncJavaScript("return typeof WI !== 'undefined' && !!WI.domManager && !!WI.domDebuggerManager && !!WI.DOMBreakpoint", contentWorld: .page)) as? Bool == true {
                return view
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static let findNode = """
        const doc = await new Promise((resolve) => WI.domManager.requestDocument(resolve));
        const target = WI.assumingMainTarget ? WI.assumingMainTarget() : WI.mainTarget;
        const { nodeId } = await target.DOMAgent.querySelector(doc.id, selector);
        if (!nodeId) throw new Error('node not found');
        window.__ubBreakNodeId = nodeId;
        """

    private static let addBreakpoint = """
        const node = WI.domManager.nodeForId(window.__ubBreakNodeId);
        if (!node) throw new Error('node not loaded');
        WI.domDebuggerManager.addDOMBreakpoint(new WI.DOMBreakpoint(node, type));
        if (WI.domManager.inspectElement) WI.domManager.inspectElement(node.id);
        return true;
        """
}
