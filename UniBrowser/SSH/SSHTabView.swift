import SwiftUI

/// An `unibrowser-ssh` tab: the terminal, with the login state over it.
struct SSHTabView: View {
    @Environment(AppModel.self) private var model
    let tab: BrowserTab
    let hostID: UUID

    var body: some View {
        if let host = model.sshHosts.host(hostID) {
            ZStack {
                if let session = tab.sshSession, let terminal = tab.sshTerminal {
                    TerminalHost(terminal: terminal)
                    status(session, host: host)
                }
            }
            // Wakes on appear, and again if the tab is put to sleep while on screen.
            .task(id: tab.sshSession == nil) {
                guard tab.sshSession == nil else { return }
                tab.wakeSSH(host: host, secret: model.sshHosts.secret(for: hostID), knownHosts: model.knownHosts)
                tab.sshTerminal?.connect()
            }
            .onChange(of: host.displayName, initial: true) { tab.title = host.displayName }
            .sheet(item: hostKeyPrompt) { prompt in
                HostKeySheet(key: prompt.key, previous: prompt.previous) { tab.sshSession?.answerHostKey(trust: $0) }
            }
        } else {
            card {
                Text("Сервер удалён из хранилища").font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { tab.sleep() }
        }
    }

    @ViewBuilder
    private func status(_ session: SSHSession, host: SSHHost) -> some View {
        switch session.state {
        case .idle, .connecting:
            card {
                ProgressView().controlSize(.small)
                Text("Подключение к \(host.displayName)…")
            }
        case .failed(let message):
            failure(message)
        case .closed:
            failure("Сессия завершена")
        case .hostKeyPrompt, .connected:
            EmptyView()
        }
    }

    private func failure(_ message: String) -> some View {
        card {
            Text(message).font(.headline).multilineTextAlignment(.center)
            HStack {
                Button("Изменить сервер") { model.passwordsSSHHost = hostID; model.isPasswordsVisible = true }
                Button("Переподключиться  ⌘R") { tab.sshTerminal?.connect() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 12, content: content)
            .padding(20)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private struct Prompt: Identifiable {
        let key: KnownHost
        let previous: KnownHost?
        var id: String { key.fingerprintSHA256 }
    }

    /// Dismissing the sheet any other way than its buttons counts as «Отмена».
    private var hostKeyPrompt: Binding<Prompt?> {
        Binding(
            get: {
                guard case .hostKeyPrompt(let key, let previous) = tab.sshSession?.state else { return nil }
                return Prompt(key: key, previous: previous)
            },
            set: { if $0 == nil { tab.sshSession?.answerHostKey(trust: false) } }
        )
    }
}
