import SwiftUI

/// «Права…»: rwx checkboxes for owner, group and others, kept in step with an octal field.
struct PermissionsSheet: View {
    let entry: SFTPEntry
    let apply: (UInt32) -> Void
    @State private var mode: UInt32
    @State private var octal: String
    @Environment(\.dismiss) private var dismiss

    init(entry: SFTPEntry, apply: @escaping (UInt32) -> Void) {
        self.entry = entry
        self.apply = apply
        let mode = entry.permissions & 0o777
        _mode = State(initialValue: mode)
        _octal = State(initialValue: String(mode, radix: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Права «\(entry.name)»").font(.headline).lineLimit(1).truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Чтение"); Text("Запись"); Text("Выполнение")
                }
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
                ForEach(Array(["Владелец", "Группа", "Остальные"].enumerated()), id: \.offset) { row, title in
                    GridRow {
                        Text(title)
                        ForEach(0..<3) { column in
                            Toggle("", isOn: bit(UInt32(0o400) >> UInt32(row * 3 + column)))
                                .labelsHidden()
                                .gridColumnAlignment(.center)
                        }
                    }
                }
            }
            HStack {
                Text("Восьмеричный вид")
                TextField("644", text: $octal)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60)
                    .onChange(of: octal) { _, text in
                        if let value = UInt32(text, radix: 8), value <= 0o777 { mode = value }
                    }
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Применить") {
                    apply(mode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(UInt32(octal, radix: 8).map { $0 > 0o777 } ?? true)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func bit(_ mask: UInt32) -> Binding<Bool> {
        Binding(
            get: { mode & mask != 0 },
            set: {
                mode = $0 ? mode | mask : mode & ~mask
                octal = String(mode, radix: 8)
            }
        )
    }
}
