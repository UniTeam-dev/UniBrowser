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
        if host.syncingDeviceIDs.contains(device.id) { return "Подключён, вкладки синхронизируются" }
        if host.connectedDeviceIDs.contains(device.id) { return "Подключён" }
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
