import SwiftUI

/// The server's key is new or changed: trust it or cancel. A changed key is shown in red with the
/// old and new fingerprints, and «Заменить ключ» asks again before trusting.
struct HostKeySheet: View {
    let key: KnownHost
    let previous: KnownHost?
    let answer: (Bool) -> Void
    @State private var isConfirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let previous {
                Label("Ключ сервера \(key.hostPort) изменился", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Возможно, сервер переустановлен — или кто-то перехватывает подключение.")
                    .foregroundStyle(.red)
                fingerprint("Был", previous)
                fingerprint("Сейчас", key)
            } else {
                Text("Новый сервер \(key.hostPort)").font(.headline)
                Text("Сверьте отпечаток ключа с тем, что показывает сервер.")
                    .foregroundStyle(Palette.secondaryText)
                fingerprint("Отпечаток", key)
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { answer(false) }
                    .keyboardShortcut(.cancelAction)
                if previous == nil {
                    Button("Доверять") { answer(true) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Заменить ключ", role: .destructive) { isConfirmingReplace = true }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert("Заменить ключ сервера?", isPresented: $isConfirmingReplace) {
            Button("Заменить ключ", role: .destructive) { answer(true) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Подключайтесь, только если знаете, почему ключ \(key.hostPort) изменился.")
        }
    }

    private func fingerprint(_ title: String, _ key: KnownHost) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) · \(key.keyType)").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            Text(key.fingerprintSHA256)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(previous == nil ? Palette.text : .red)
        }
    }
}
