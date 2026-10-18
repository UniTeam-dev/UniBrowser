import SwiftUI

/// A thin bar above the page: "Войти как …" when saved logins exist for the
/// site, "Сохранить пароль?" after the user signs in with a new one.
struct PasswordBar: View {
    @Environment(AppModel.self) private var model
    let tab: BrowserTab
    @State private var error: String?

    var body: some View {
        if let pending = tab.pendingSave {
            bar {
                Image(systemName: "key.fill").foregroundStyle(Palette.accent)
                Text(pending.username.isEmpty
                     ? "Сохранить пароль для **\(pending.host)** в «\(model.passwords.displayName)»?"
                     : "Сохранить пароль **\(pending.username)** для \(pending.host) в «\(model.passwords.displayName)»?")
                Spacer()
                Button("Не сейчас") { tab.pendingSave = nil; error = nil }
                Button("Сохранить") {
                    Task {
                        do {
                            try await model.passwords.save(pending)
                            tab.pendingSave = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
            }
        } else if tab.hasLoginForm && canPairApplePasswords {
            bar {
                Image(systemName: "key.fill").foregroundStyle(Palette.accent)
                Text("Подключите «Пароли», чтобы подставлять и сохранять пароли из iCloud")
                Spacer()
                Button("Подключить") { pairApplePasswords() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        } else if !tab.loginOffers.isEmpty {
            bar {
                Image(systemName: "key.fill").foregroundStyle(Palette.accent)
                Text("Войти как")
                ForEach(tab.loginOffers) { credential in
                    Button(credential.username.isEmpty ? "без имени" : credential.username) {
                        tab.fill(credential)
                    }
                }
                Spacer()
                Text(model.passwords.displayName).foregroundStyle(Palette.secondaryText)
                Button { tab.loginOffers = [] } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Скрыть")
            }
        }
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .onTapGesture { self.error = nil }
        }
    }

    private var canPairApplePasswords: Bool {
        model.passwords.storage == .apple && model.passwords.apple.state == .readyToPair
    }

    private func pairApplePasswords() {
        Task { await model.passwords.apple.beginPairing() }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Palette.surfaceAlt)
            .overlay(alignment: .bottom) { Divider() }
    }
}
