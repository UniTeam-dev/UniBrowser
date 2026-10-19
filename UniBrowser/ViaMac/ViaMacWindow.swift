import CoreImage.CIFilterBuiltins
import SwiftUI

/// "iPhone" window: turn the link on, pair a phone by QR, see and remove paired phones.
struct ViaMacWindow: View {
    @Environment(ViaMacHost.self) private var host

    var body: some View {
        @Bindable var host = host
        Form {
            Section {
                Toggle("Связь с iPhone", isOn: $host.isEnabled)
                LabeledContent("Состояние", value: statusText)
            } footer: {
                Text("iPhone в режиме «Через Mac» видит и меняет вкладки, группы и пространства этого Mac, получает сохранённые пароли UniBrowser и открывает выбранные сайты через сеть Mac: домашний NAS, сервер, роутер. Работает из любой сети. Пока связь включена и есть сопряжённый iPhone, Mac не уходит в сон по бездействию. Подключайте только свои устройства и сети, к которым у вас есть доступ.")
                    .foregroundStyle(.secondary)
            }

            if host.status == .ready {
                Section("Подключить iPhone") {
                    if let pairing = host.pairing {
                        PairingCode(pairing: pairing)
                        Button("Отмена") { host.cancelPairing() }
                    } else {
                        Button("Показать QR-код") { Task { await host.beginPairing() } }
                    }
                }
            }

            ViaMacConnectionSection()

            Section("Сопряжённые iPhone") {
                if host.pairedDevices.isEmpty {
                    Text("Пока нет").foregroundStyle(.secondary)
                }
                ForEach(host.pairedDevices) { device in
                    HStack {
                        Circle()
                            .fill(host.connectedDeviceIDs.contains(device.id) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(deviceState(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Отключить", role: .destructive) { host.remove(device) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420)
    }

    private func deviceState(_ device: ViaMacHost.PairedDevice) -> String {
        let path = host.linkPaths[device.id].map { " · \($0.title.lowercased())" } ?? ""
        if host.syncingDeviceIDs.contains(device.id) { return "Подключён, вкладки синхронизируются" + path }
        if host.connectedDeviceIDs.contains(device.id) { return "Подключён" + path }
        return "Не в сети"
    }

    private var statusText: String {
        switch host.status {
        case .off: "Выключен"
        case .starting: "Запускается…"
        case .ready: host.connectedDeviceIDs.isEmpty ? "Готов, iPhone не подключён" : "iPhone подключён"
        case .failed(let message): "Ошибка: \(message)"
        }
    }
}

/// How a phone outside the home network reaches this Mac: the port to forward on the
/// router, the external address and the user's own relay. In the iPhone window and in
/// Settings → iPhone. Fields apply on Return or when the view goes away.
struct ViaMacConnectionSection: View {
    @Environment(ViaMacHost.self) private var host
    @State private var port = ""
    @State private var external = ""
    @State private var relay = ""

    var body: some View {
        Section {
            LabeledContent("Адрес Mac в локальной сети", value: host.lanAddress ?? "—")
            LabeledContent("Порт для проброса") {
                HStack {
                    TextField("", text: $port, prompt: Text(String(ViaMacAddress.defaultPort)))
                        .frame(width: 70)
                        .onSubmit(apply)
                    Text("UDP").foregroundStyle(.secondary)
                }
            }
            if let bound = host.boundPort, bound != UInt16(clamping: host.port) {
                Text("Порт \(String(host.port)) занят, связь работает на случайном порту \(String(bound)): проброс на роутере не сработает. Выберите другой порт.")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField("Внешний адрес", text: $external, prompt: Text("IP или имя, например home.example.net"))
                .onSubmit(apply)
            if !external.isEmpty, ViaMacAddress.parse(external, defaultPort: 1) == nil {
                Text("Нужен IP-адрес или имя, при желании с портом: 203.0.113.7:47802").font(.caption).foregroundStyle(.red)
            }
            TextField("Свой сервер связи", text: $relay, prompt: Text("https://relay.example.ru — пусто: серверы iroh"))
                .onSubmit(apply)
            if !relay.isEmpty, !ViaMacAddress.isValidRelay(relay) {
                Text("Нужен адрес вида https://relay.example.ru").font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Подключение из других сетей")
        } footer: {
            Text("Чтобы iPhone из мобильного интернета подключался к Mac напрямую, пробросьте на роутере UDP-порт на адрес Mac и укажите внешний адрес дома: белый IP или имя DDNS. Свой сервер связи нужен, когда прямой путь недоступен. Подробности — docs/via-mac-direct.md и docs/via-mac-relay.md. Изменения применяются по Return.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            port = String(host.port)
            external = host.externalAddress
            relay = host.relayServer
        }
        // The same fields may be open in the other window too.
        .onChange(of: host.port) { port = String(host.port) }
        .onChange(of: host.externalAddress) { external = host.externalAddress }
        .onChange(of: host.relayServer) { relay = host.relayServer }
        .onDisappear(perform: apply)
    }

    private func apply() {
        if let value = Int(port), (1...65535).contains(value) { host.port = value } else { port = String(host.port) }
        host.externalAddress = external.trimmingCharacters(in: .whitespaces)
        host.relayServer = relay.trimmingCharacters(in: .whitespaces)
    }
}

private struct PairingCode: View {
    let pairing: PairingPayload

    var body: some View {
        VStack(spacing: 12) {
            if let image = Self.qrImage(pairing.link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
            }
            Text("Наведите камеру iPhone на код и откройте ссылку в UniBrowser. Код действует 10 минут и только один раз.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Скопировать код") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pairing.link, forType: .string)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
