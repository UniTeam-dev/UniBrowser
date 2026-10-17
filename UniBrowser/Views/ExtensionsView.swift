import SwiftUI
import WebKit

/// ⌘⇧E: installed extensions (on/off, remove) and installing new ones.
struct ExtensionsView: View {
    @Environment(\.dismiss) private var dismiss
    let manager: ExtensionManager
    @State private var storeInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Расширения").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            if manager.records.isEmpty {
                Text("Пока ничего не установлено. Добавьте распакованное расширение из папки или вставьте ссылку из Chrome Web Store.")
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.records) { record in
                    row(record)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error = manager.lastError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    TextField("Ссылка или ID из Chrome Web Store", text: $storeInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(installFromStore)
                    Button("Установить", action: installFromStore)
                        .disabled(storeInput.isEmpty || manager.isInstalling)
                    if manager.isInstalling { ProgressView().controlSize(.small) }
                }
                Button("Добавить из папки…", action: chooseFolder)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
    }

    private func row(_ record: ExtensionManager.Record) -> some View {
        let context = manager.contexts[record.id]
        return HStack(spacing: 10) {
            Group {
                if let icon = context?.webExtension.icon(for: CGSize(width: 32, height: 32)) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(Palette.secondaryText)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.name(of: record)).lineLimit(1)
                Text([context?.webExtension.version, record.storeID == nil ? "из папки" : "Chrome Web Store", errorText(context)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("Включено", isOn: Binding(
                get: { record.isEnabled },
                set: { isOn in Task { await manager.setEnabled(record.id, isOn) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button { manager.remove(record.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Удалить расширение")
        }
        .padding(.vertical, 2)
    }

    private func errorText(_ context: WKWebExtensionContext?) -> String? {
        guard let context else { return nil }
        let errors = context.errors + context.webExtension.errors
        return errors.isEmpty ? nil : "ошибок: \(errors.count)"
    }

    private func installFromStore() {
        let input = storeInput
        Task {
            await manager.installFromStore(input)
            if manager.lastError == nil { storeInput = "" }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Папка распакованного расширения (с manifest.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await manager.installFolder(url) }
    }
}

/// Extension buttons under the address field; a click runs the extension's action or opens its popup.
struct ExtensionBar: View {
    let manager: ExtensionManager

    var body: some View {
        let items = manager.actionContexts
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    ExtensionButton(manager: manager, id: item.id, context: item.context)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct ExtensionButton: View {
    let manager: ExtensionManager
    let id: String
    let context: WKWebExtensionContext

    var body: some View {
        let action = manager.action(for: context)
        let name = action?.label ?? context.webExtension.displayName ?? "Расширение"
        Button { manager.performAction(id) } label: {
            Group {
                if let icon = action?.icon(for: CGSize(width: 18, height: 18)) ?? context.webExtension.icon(for: CGSize(width: 18, height: 18)) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension")
                }
            }
            .frame(width: 18, height: 18)
            .frame(width: 28, height: 26)
            .overlay(alignment: .topTrailing) {
                if let badge = action?.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Color(hex: "#D93F2B"), in: Capsule())
                }
            }
            .background(Palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .background(PopupAnchor { manager.popupAnchors[context.uniqueIdentifier] = $0 })
        }
        .buttonStyle(.plain)
        .disabled(action?.isEnabled == false)
        .help(name)
        .accessibilityLabel(name)
    }
}

/// Hands the button's NSView to the manager so a popup can point at it.
private struct PopupAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
