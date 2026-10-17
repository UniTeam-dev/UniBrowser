import SwiftUI

/// Panel «Элементы» (spec «Элементы»): toolbar with the picker and search, the DOM tree,
/// and the side panes. The model is `ElementsModel`.
struct ElementsPanel: View {
    let session: DevToolsSession

    var body: some View {
        let model = session.elements
        GeometryReader { geometry in
            Group {
                if geometry.size.width < 640 {
                    VSplitView {
                        tree(model).frame(minHeight: 120)
                        ElementsSidebar(model: model).frame(minHeight: 120)
                    }
                } else {
                    HSplitView {
                        tree(model).frame(minWidth: 260)
                        ElementsSidebar(model: model).frame(minWidth: 240, idealWidth: 340)
                    }
                }
            }
        }
        .task(id: session.topFrame) { await model.load() }
        .sheet(item: Binding(get: { model.htmlEdit }, set: { model.htmlEdit = $0 })) { _ in
            HTMLEditSheet(model: model)
        }
        .alert("Не получилось", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func tree(_ model: ElementsModel) -> some View {
        VStack(spacing: 0) {
            ElementsToolbar(model: model)
            Divider()
            DOMTreeView(model: model)
        }
    }
}

private struct ElementsToolbar: View {
    @Bindable var model: ElementsModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { model.pick() } label: {
                Image(systemName: "cursorarrow.rays")
                    .foregroundStyle(model.isPicking ? Palette.accent : Palette.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Выбрать элемент на странице (⇧⌘C)")
            .accessibilityLabel("Выбрать элемент на странице")
            TextField("Поиск: текст, селектор или XPath", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($isSearchFocused)
                .onSubmit { Task { await model.search() } }
            if !model.searchResults.isEmpty {
                Text("\(model.searchIndex + 1) из \(model.searchResults.count)")
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
                Button { Task { await model.nextResult(-1) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Предыдущее совпадение")
                Button { Task { await model.nextResult(1) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Следующее совпадение")
            } else if !model.searchQuery.isEmpty {
                Text("Нет совпадений").foregroundStyle(Palette.secondaryText)
            }
            // ⌘F focuses the search field while this panel is shown.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f")
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
        .frame(height: 28)
        .onChange(of: model.searchQuery) { _, query in
            if query.isEmpty { Task { await model.search() } }
        }
    }
}

// MARK: - Tree

private struct DOMTreeView: View {
    let model: ElementsModel
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        DOMRowView(model: model, row: row)
                            .id(row.id)
                            .onTapGesture { isFocused = true }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.scrollRequest) {
                if let key = model.selected { proxy.scrollTo(DOMRow(key: key, depth: 0, isClosing: false).id) }
            }
        }
        .background(Palette.surface)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onHover { if !$0 { model.hover(nil) } }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .delete, .deleteForward]) { press in
            guard model.editing == nil else { return .ignored }
            switch press.key {
            case .upArrow: model.moveSelection(-1)
            case .downArrow: model.moveSelection(1)
            case .leftArrow: model.stepOut()
            case .rightArrow: model.stepIn()
            default: if let key = model.selected { model.delete(key) }
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "hHрР")) { press in
            guard model.editing == nil, press.modifiers.isEmpty || press.modifiers == .shift, let key = model.selected else { return .ignored }
            model.toggleHidden(key)
            return .handled
        }
    }
}

/// Chrome-like colours for markup.
enum MarkupColor {
    static let tag = Color(light: "#881280", dark: "#5DB0D7")
    static let attribute = Color(light: "#994500", dark: "#9BBBDC")
    static let value = Color(light: "#1A1AA6", dark: "#F29766")
    static let comment = Color(light: "#236E25", dark: "#898989")
    static let flash = Color(light: "#E4CCFF", dark: "#5A3D80")
    static let selection = Color(light: "#CFE3FF", dark: "#2B4A75")
    static let hover = Color(light: "#EEF4FF", dark: "#2F3540")
}

private struct DOMRowView: View {
    let model: ElementsModel
    let row: DOMRow
    @State private var isHovered = false
    @State private var isDropTarget = false

    private var font: Font { .system(size: 11, design: .monospaced) }

    var body: some View {
        let node = model.nodes[row.key]
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * 14 + 4, height: 1)
            disclosure
            if let node { content(node) }
            Spacer(minLength: 12)
        }
        .font(font)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 18)
        .opacity(node?.hid == true ? 0.5 : 1)
        .background(background)
        .overlay(alignment: .top) {
            if isDropTarget { Rectangle().fill(Palette.accent).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.select(row.key) })
        .onHover { inside in
            isHovered = inside
            if inside { model.hover(row.key) }
        }
        .contextMenu { if let node { ElementsContextMenu(model: model, key: row.key, node: node) } }
        .draggable(draggedID) { Text(node.map { "<\($0.n)>" } ?? "").font(font).padding(4) }
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, let key = Self.key(from: item) else { return false }
            model.move(key, to: row)
            return true
        } isTargeted: { isDropTarget = $0 }
    }

    private var draggedID: String { "ubnode:\(row.key.frame):\(row.key.handle)" }

    static func key(from item: String) -> DOMKey? {
        let parts = item.split(separator: ":")
        guard parts.count == 3, parts[0] == "ubnode", let handle = Int(parts[2]) else { return nil }
        return DOMKey(frame: String(parts[1]), handle: handle)
    }

    private var background: Color {
        if model.selected == row.key { return MarkupColor.selection }
        if model.flashing.contains(row.key) { return MarkupColor.flash }
        return isHovered ? MarkupColor.hover : .clear
    }

    @ViewBuilder private var disclosure: some View {
        if !row.isClosing && model.isExpandable(row.key) {
            Image(systemName: model.expanded.contains(row.key) ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 7))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 12, height: 18)
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.option) {
                        if model.expanded.contains(row.key) { model.collapseAll(row.key) } else { Task { await model.expandAll(row.key) } }
                    } else {
                        model.toggle(row.key)
                    }
                }
                .accessibilityLabel(model.expanded.contains(row.key) ? "Свернуть" : "Развернуть")
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    @ViewBuilder private func content(_ node: DOMNode) -> some View {
        if row.isClosing {
            Text("</\(node.n)>").foregroundStyle(MarkupColor.tag)
        } else {
            switch node.t {
            case 1: element(node)
            case 3: text(node)
            case 8: Text("<!--\(node.v ?? "")-->").foregroundStyle(MarkupColor.comment)
            case 10: Text("<!DOCTYPE \(node.n)>").foregroundStyle(Palette.secondaryText)
            case 9: Text("#document").foregroundStyle(Palette.secondaryText) + Text(node.v.map { "  \($0)" } ?? "").foregroundStyle(Palette.secondaryText.opacity(0.7))
            default: Text(node.n).foregroundStyle(Palette.secondaryText)
            }
        }
    }

    @ViewBuilder private func element(_ node: DOMNode) -> some View {
        Text("<\(node.n)").foregroundStyle(MarkupColor.tag)
        ForEach(Array(node.attributes.enumerated()), id: \.offset) { _, attribute in
            if model.editing == .attribute(row.key, attribute.name) {
                Text(" ")
                InlineEditor(text: "\(attribute.name)=\"\(attribute.value)\"") { model.editAttribute(row.key, name: attribute.name, text: $0) } cancel: { model.editing = nil }
            } else {
                (Text(" ") + Text(attribute.name).foregroundStyle(MarkupColor.attribute)
                    + Text(attribute.value.isEmpty ? "" : "=\"").foregroundStyle(MarkupColor.tag)
                    + Text(clip(attribute.value, 200)).foregroundStyle(MarkupColor.value)
                    + Text(attribute.value.isEmpty ? "" : "\"").foregroundStyle(MarkupColor.tag))
                    .onTapGesture(count: 2) { model.select(row.key); model.editing = .attribute(row.key, attribute.name) }
            }
        }
        if model.editing == .attribute(row.key, nil) {
            Text(" ")
            InlineEditor(text: "") { model.editAttribute(row.key, name: nil, text: $0) } cancel: { model.editing = nil }
        }
        Text(">").foregroundStyle(MarkupColor.tag)
            .onTapGesture(count: 2) { model.select(row.key); model.editing = .attribute(row.key, nil) }
        if let inline = node.it, let textHandle = node.ith {
            let textKey = DOMKey(frame: row.key.frame, handle: textHandle)
            if model.editing == .text(textKey) {
                InlineEditor(text: inline) { model.setText(textKey, $0) } cancel: { model.editing = nil }
            } else {
                Text(inline).foregroundStyle(Palette.text)
                    .onTapGesture(count: 2) { model.select(row.key); model.editing = .text(textKey) }
            }
            Text("</\(node.n)>").foregroundStyle(MarkupColor.tag)
        } else if node.f == true || node.hasChildren {
            if !model.expanded.contains(row.key) {
                Text("…").foregroundStyle(Palette.secondaryText)
                Text("</\(node.n)>").foregroundStyle(MarkupColor.tag)
            }
        } else if !node.isVoid {
            Text("</\(node.n)>").foregroundStyle(MarkupColor.tag)
        }
    }

    @ViewBuilder private func text(_ node: DOMNode) -> some View {
        let value = (node.v ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if model.editing == .text(row.key) {
            InlineEditor(text: node.v ?? "") { model.setText(row.key, $0) } cancel: { model.editing = nil }
        } else {
            Text("\"\(clip(value, 300))\"").foregroundStyle(Palette.text)
                .onTapGesture(count: 2) { model.editing = .text(row.key) }
        }
    }
}

private func clip(_ text: String, _ limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
}

/// A one-line field that commits on Return or losing focus and cancels on Esc.
struct InlineEditor: View {
    @State var text: String
    var placeholder = ""
    let commit: (String) -> Void
    let cancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isDone = false

    init(text: String, placeholder: String = "", commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _text = State(initialValue: text)
        self.placeholder = placeholder
        self.commit = commit
        self.cancel = cancel
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .frame(minWidth: 120)
            .fixedSize()
            .padding(.horizontal, 2)
            .background(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Palette.accent))
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: isFocused) { _, focused in if !focused { finish(commit: true) } }
    }

    private func finish(commit shouldCommit: Bool) {
        guard !isDone else { return }
        isDone = true
        if shouldCommit { commit(text) } else { cancel() }
    }
}

private struct ElementsContextMenu: View {
    let model: ElementsModel
    let key: DOMKey
    let node: DOMNode

    var body: some View {
        if node.isElement {
            Button("Добавить атрибут") { model.select(key); model.editing = .attribute(key, nil) }
            Button("Редактировать как HTML") { model.beginHTMLEdit(key) }
        }
        if node.t == 3 { Button("Редактировать текст") { model.editing = .text(key) } }
        if node.isElement || node.t == 3 || node.t == 8 {
            Button("Удалить элемент") { model.delete(key) }
        }
        Divider()
        Menu("Копировать") {
            if node.isElement { Button("Селектор") { model.copy(key, "selector") } }
            Button("outerHTML") { model.copy(key, "outerHTML") }
        }
        if node.isElement {
            Button(node.hid == true ? "Показать элемент" : "Скрыть элемент") { model.toggleHidden(key) }
            Menu("Принудительное состояние") {
                ForEach(ForcedState.allCases) { state in
                    Button(":\(state.rawValue)") { Task { await toggleForced(state) } }
                }
            }
            Divider()
            Button("Прокрутить к элементу") { model.scrollIntoView(key) }
            Button("Снимок узла…") { model.snapshot(key) }
        }
        Button("Сохранить как глобальную переменную") { model.storeAsGlobal(key) }
        if node.isElement, key.frame == model.session?.topFrame, DOMBreakpoints.isAvailable(model.session?.webView) {
            Menu("Остановиться при") {
                ForEach(DOMBreakpoints.Kind.allCases) { kind in
                    Button(kind.title) { DOMBreakpoints.set(kind, on: key, model: model) }
                }
            }
        }
        Divider()
        Button("Развернуть всё") { Task { await model.expandAll(key) } }
        Button("Свернуть всё") { model.collapseAll(key) }
    }

    private func toggleForced(_ state: ForcedState) async {
        var states = Set(await model.styles(key)?.forced ?? [])
        if states.contains(state.rawValue) { states.remove(state.rawValue) } else { states.insert(state.rawValue) }
        model.forceState(key, Array(states))
    }
}

enum ForcedState: String, CaseIterable, Identifiable {
    case hover, active, focus, focusVisible = "focus-visible", focusWithin = "focus-within", visited
    var id: Self { self }
}

private struct HTMLEditSheet: View {
    let model: ElementsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Редактировать как HTML").font(.headline)
            TextEditor(text: Binding(get: { model.htmlEdit?.text ?? "" }, set: { model.htmlEdit?.text = $0 }))
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 560, minHeight: 300)
                .border(Palette.dimmed)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { model.htmlEdit = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") { model.commitHTMLEdit() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
    }
}
