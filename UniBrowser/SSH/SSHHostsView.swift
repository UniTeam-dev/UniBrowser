import SwiftUI

/// The «SSH» section of the passwords window: saved servers, add / edit / delete / open in a tab.
struct SSHHostsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    @Binding var editing: SSHHost?
    @State private var isAdding = false
    @State private var deleting: SSHHost?

    var body: some View {
        let hosts = model.sshHosts.live
        VStack(spacing: 0) {
            if hosts.isEmpty {
                Text("Пока нет серверов. Добавьте сервер, чтобы открывать его во вкладке.")
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(hosts) { host in
                    HStack(spacing: 10) {
                        Image(systemName: "terminal").foregroundStyle(Palette.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.displayName).font(.system(size: 14))
                            Text(verbatim: "\(host.username)@\(host.address)" + (host.port == 22 ? "" : ":\(host.port)"))
                                .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                        }
                        Spacer()
                        Menu {
                            actions(host)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Действия")
                    }
                    .padding(.vertical, 2)
                    .contextMenu { actions(host) }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Добавить…") { isAdding = true }
            }
            .padding(16)
        }
        .sheet(item: $editing) { SSHHostForm(original: $0) }
        .sheet(isPresented: $isAdding) { SSHHostForm(original: nil) }
        .confirmationDialog("Удалить сервер «\(deleting?.displayName ?? "")»?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { host in
            Button("Удалить", role: .destructive) { model.sshHosts.delete(host.id) }
            Button("Отмена", role: .cancel) {}
        } message: { host in
            let count = model.store.tabs.values.filter { $0.url?.sshHostID == host.id && $0.sshSession != nil }.count
            Text((count == 0 ? "" : "Открытые вкладки этого сервера будут отключены: \(count). ") + "Пароль или ключ тоже будут удалены.")
        }
    }

    @ViewBuilder
    private func actions(_ host: SSHHost) -> some View {
        Button("Открыть во вкладке") { model.store.openSSH(host.id); dismiss() }
        Button("Изменить") { editing = host }
        Button("Удалить…") { deleting = host }
    }
}
