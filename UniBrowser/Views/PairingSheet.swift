// Direct (Developer ID) build only: launches a system helper, which App Sandbox and App Review rule out.
#if DIRECT
import SwiftUI

/// Asks for the 6-digit code the Passwords app shows when UniBrowser pairs with it.
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var isVerifying = false
    @FocusState private var isFocused: Bool

    private var apple: ApplePasswordsProvider { model.passwords.apple }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 28))
                .foregroundStyle(Palette.accent)
            Text("Подключение к «Паролям»")
                .font(.title3.weight(.semibold))
            Text("Введите код из окна «Пароли» на этом Mac.")
                .foregroundStyle(Palette.secondaryText)
            TextField("000000", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 160)
                .focused($isFocused)
                .onChange(of: pin) {
                    pin = String(pin.filter(\.isNumber).prefix(6))
                    if pin.count == 6 { submit() }
                }
            if let error = apple.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Отмена") { apple.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
                Button("Подключить") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.count != 6 || isVerifying)
            }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard !isVerifying else { return }
        isVerifying = true
        Task {
            await apple.submitPIN(pin)
            isVerifying = false
            pin = ""
        }
    }
}
#endif
