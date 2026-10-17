import CryptoKit
import Network
import Security
import SwiftUI
import WebKit

/// Panel «Безопасность» (spec «Безопасность»): the main origin's state, its certificate
/// chain from `serverTrust`, TLS parameters, and every origin seen in «Сеть».
@MainActor
@Observable
final class SecurityModel {
    struct Certificate: Identifiable {
        let id = UUID()
        var subject = ""
        var issuer = ""
        var notBefore: Date?
        var notAfter: Date?
        var names: [String] = []
        var sha256 = ""
        var serial = ""
        var publicKey = ""
        var signature = ""
    }

    struct TLS {
        var version = ""
        var cipher = ""
        var httpProtocol = ""
        var remoteAddress = ""
    }

    enum State { case secure, mixed, insecure, invalid, unknown }

    private(set) var url: URL?
    private(set) var hasOnlySecureContent = false
    private(set) var certificates: [Certificate] = []
    private(set) var trustError: String?
    private(set) var isTrusted: Bool?
    private(set) var extendedValidation: String?
    private(set) var tls: TLS?
    private(set) var tlsError: String?
    private(set) var isLoading = false

    @ObservationIgnored private weak var session: DevToolsSession?

    func bind(_ session: DevToolsSession) {
        self.session = session
    }

    var state: State {
        guard let url else { return .unknown }
        guard url.scheme == "https" else { return url.scheme == "http" ? .insecure : .unknown }
        if isTrusted == false { return .invalid }
        return hasOnlySecureContent ? .secure : .mixed
    }

    /// Cheap: the URL and mixed-content flag, re-read whenever «Сеть» gets a request.
    func refreshState() {
        url = session?.webView?.url
        hasOnlySecureContent = session?.webView?.hasOnlySecureContent ?? false
    }

    /// `refresh()` once per page: showing the panel again does not repeat the HEAD request.
    func refreshIfNeeded() async {
        guard session?.webView?.url != refreshedURL else { return refreshState() }
        await refresh()
    }

    @ObservationIgnored private var refreshedURL: URL?

    /// The certificate chain and trust (SecTrust), and TLS parameters from one HEAD request.
    func refresh() async {
        guard let webView = session?.webView else { return }
        refreshState()
        refreshedURL = url
        isLoading = true
        defer { isLoading = false }
        certificates = []
        isTrusted = nil
        trustError = nil
        extendedValidation = nil
        tls = nil
        tlsError = nil
        guard let url, url.scheme == "https" else { return }
        if let trust = webView.serverTrust {
            certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).map(Self.describe)
            let (ok, error) = await Self.evaluate(trust)
            isTrusted = ok
            trustError = error
            if let result = SecTrustCopyResult(trust) as? [String: Any] {
                if result[kSecTrustExtendedValidation as String] as? Bool == true {
                    extendedValidation = result[kSecTrustOrganizationName as String] as? String ?? "да"
                }
            }
        }
        do { tls = try await Self.tls(for: url) } catch { tlsError = error.localizedDescription }
    }

    /// SecTrustEvaluateAsyncWithError on the main queue; the work itself runs off it.
    private static func evaluate(_ trust: SecTrust) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            let status = SecTrustEvaluateAsyncWithError(trust, .main) { _, ok, error in
                continuation.resume(returning: (ok, error.map { ($0 as Error).localizedDescription }))
            }
            if status != errSecSuccess { continuation.resume(returning: (false, "SecTrust: \(status)")) }
        }
    }

    private static func describe(_ certificate: SecCertificate) -> Certificate {
        var result = Certificate()
        result.subject = SecCertificateCopySubjectSummary(certificate) as String? ?? ""
        let data = SecCertificateCopyData(certificate) as Data
        result.sha256 = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: " ")
        if let serial = SecCertificateCopySerialNumberData(certificate, nil) as Data? {
            result.serial = serial.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        if let key = SecCertificateCopyKey(certificate), let attributes = SecKeyCopyAttributes(key) as? [String: Any] {
            let type = attributes[kSecAttrKeyType as String] as? String
            let name = type == (kSecAttrKeyTypeRSA as String) ? "RSA" : type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "ECDSA" : "ключ"
            let bits = (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue ?? 0
            result.publicKey = "\(name) \(bits) бит"
        }
        guard let values = SecCertificateCopyValues(certificate, nil, nil) as? [String: Any] else { return result }
        func value(_ oid: CFString) -> Any? { (values[oid as String] as? [String: Any])?[kSecPropertyKeyValue as String] }
        func names(_ oid: CFString) -> [(label: String, value: String)] {
            (value(oid) as? [[String: Any]] ?? []).compactMap { item in
                guard let text = item[kSecPropertyKeyValue as String] as? String else { return nil }
                return (item[kSecPropertyKeyLabel as String] as? String ?? "", text)
            }
        }
        func date(_ oid: CFString) -> Date? {
            (value(oid) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        }
        let issuer = names(kSecOIDX509V1IssuerName)
        // 2.5.4.3 commonName, 2.5.4.10 organizationName
        result.issuer = [issuer.first { $0.label == "2.5.4.3" }?.value, issuer.first { $0.label == "2.5.4.10" }?.value]
            .compactMap { $0 }.joined(separator: ", ")
        result.notBefore = date(kSecOIDX509V1ValidityNotBefore)
        result.notAfter = date(kSecOIDX509V1ValidityNotAfter)
        result.names = names(kSecOIDSubjectAltName).filter { $0.label != "Critical" }.map(\.value)
        if let algorithm = names(kSecOIDX509V1SignatureAlgorithm).first?.value {
            result.signature = [
                "1.2.840.113549.1.1.11": "SHA-256 с RSA", "1.2.840.113549.1.1.12": "SHA-384 с RSA",
                "1.2.840.113549.1.1.13": "SHA-512 с RSA", "1.2.840.10045.4.3.2": "ECDSA с SHA-256",
                "1.2.840.10045.4.3.3": "ECDSA с SHA-384", "1.2.840.10045.4.3.4": "ECDSA с SHA-512",
                "1.2.840.113549.1.1.10": "RSA-PSS",
            ][algorithm] ?? algorithm
        }
        return result
    }

    /// WebKit does not expose the page's TLS session, so one HEAD request without cookies
    /// reports what the server negotiates.
    private static func tls(for url: URL) async throws -> TLS {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let collector = MetricsCollector()
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        _ = try await session.data(for: request, delegate: collector)
        guard let transaction = collector.metrics?.transactionMetrics.last else { return TLS() }
        var tls = TLS()
        if let version = transaction.negotiatedTLSProtocolVersion {
            tls.version = [0x0304: "TLS 1.3", 0x0303: "TLS 1.2", 0x0302: "TLS 1.1", 0x0301: "TLS 1.0"][version.rawValue]
                ?? String(format: "0x%04X", version.rawValue)
        }
        if let suite = transaction.negotiatedTLSCipherSuite {
            tls.cipher = cipherNames[suite.rawValue] ?? String(format: "0x%04X", suite.rawValue)
        }
        tls.httpProtocol = transaction.networkProtocolName ?? ""
        if let address = transaction.remoteAddress { tls.remoteAddress = address + (transaction.remotePort.map { ":\($0)" } ?? "") }
        return tls
    }

    private static let cipherNames: [UInt16: String] = [
        0x1301: "TLS_AES_128_GCM_SHA256", 0x1302: "TLS_AES_256_GCM_SHA384", 0x1303: "TLS_CHACHA20_POLY1305_SHA256",
        0xC02B: "ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", 0xC02C: "ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
        0xC02F: "ECDHE_RSA_WITH_AES_128_GCM_SHA256", 0xC030: "ECDHE_RSA_WITH_AES_256_GCM_SHA384",
        0xCCA8: "ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256", 0xCCA9: "ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    ]

    private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var collected: URLSessionTaskMetrics?
        var metrics: URLSessionTaskMetrics? { lock.withLock { collected } }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.withLock { collected = metrics }
        }
    }

    // MARK: - Origins seen in «Сеть»

    struct Origin: Identifiable {
        let id: String
        let scheme: String
        var count: Int
        var isSecure: Bool { ["https", "wss", "data", "blob", "about"].contains(scheme) }
        /// Insecure on a secure page.
        var isMixed: Bool
    }

    func origins(_ entries: [NetworkEntry]) -> [Origin] {
        let pageSecure = url?.scheme == "https"
        var result: [String: Origin] = [:]
        for entry in entries where !entry.imported {
            let scheme = entry.scheme
            let id: String
            if let components = URLComponents(string: entry.url), let host = components.host {
                id = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
            } else {
                id = scheme + ":"
            }
            result[id, default: Origin(id: id, scheme: scheme, count: 0, isMixed: pageSecure && (scheme == "http" || scheme == "ws"))].count += 1
        }
        return result.values.sorted { ($0.isMixed ? 0 : $0.isSecure ? 2 : 1, $0.id) < ($1.isMixed ? 0 : $1.isSecure ? 2 : 1, $1.id) }
    }
}

struct SecurityPanel: View {
    let session: DevToolsSession

    private var model: SecurityModel { session.security }

    var body: some View {
        let origins = model.origins(session.network.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary
                if model.url?.scheme == "https" {
                    connection
                    certificates
                }
                originsList(origins)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .task(id: session.topFrame) { await model.refreshIfNeeded() }
        .onChange(of: session.network.entries.count) { model.refreshState() }
    }

    private var summary: some View {
        let (symbol, color, title, text): (String, Color, String, String) = switch model.state {
        case .secure: ("lock.fill", .green, "Страница защищена", "Соединение с сервером зашифровано, сертификат действителен, всё содержимое загружено по HTTPS.")
        case .mixed: ("lock.trianglebadge.exclamationmark.fill", .orange, "Смешанное содержимое", "Соединение зашифровано, но часть ресурсов загружена без шифрования.")
        case .insecure: ("lock.open.fill", .red, "Страница не защищена", "Соединение не зашифровано: данные видны и могут быть изменены по пути.")
        case .invalid: ("xmark.shield.fill", .red, "Сертификат недействителен", model.trustError ?? "Цепочка сертификатов не прошла проверку.")
        case .unknown: ("questionmark.circle", .secondary, "Нет данных", "Для этой страницы нет сведений о соединении.")
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(Palette.secondaryText).fixedSize(horizontal: false, vertical: true)
                if let url = model.url {
                    Text(url.absoluteString).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
            }
            Spacer()
            Button { Task { await model.refresh() } } label: {
                if model.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Обновить")
            .accessibilityLabel("Обновить")
        }
    }

    private var connection: some View {
        var rows: [(String, String)] = [
            ("Только защищённое содержимое", model.hasOnlySecureContent ? "да" : "нет (hasOnlySecureContent = false)"),
            ("Проверка доверия (SecTrust)", model.isTrusted.map { $0 ? "пройдена" : "не пройдена" + (model.trustError.map { ": " + $0 } ?? "") } ?? "—"),
        ]
        if let ev = model.extendedValidation { rows.append(("Расширенная проверка (EV)", ev)) }
        if let tls = model.tls {
            if !tls.version.isEmpty { rows.append(("Протокол", tls.version)) }
            if !tls.cipher.isEmpty { rows.append(("Набор шифров", tls.cipher)) }
            if !tls.httpProtocol.isEmpty { rows.append(("HTTP", tls.httpProtocol)) }
            if !tls.remoteAddress.isEmpty { rows.append(("Адрес сервера", tls.remoteAddress)) }
        }
        if let error = model.tlsError { rows.append(("Параметры TLS", "не получены: " + error)) }
        return VStack(alignment: .leading, spacing: 4) {
            NetworkKeyValueSection(title: "Соединение", rows: rows)
            Text("Параметры TLS получены отдельным запросом HEAD без cookie.")
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var certificates: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Цепочка сертификатов").bold()
            if model.certificates.isEmpty {
                Text(model.isLoading ? "Загрузка…" : "WebKit не передал сертификат (serverTrust пуст).").foregroundStyle(Palette.secondaryText)
            }
            ForEach(Array(model.certificates.enumerated()), id: \.element.id) { index, certificate in
                NetworkKeyValueSection(title: (index == 0 ? "Сертификат сайта: " : index == model.certificates.count - 1 ? "Корневой: " : "Промежуточный: ") + certificate.subject,
                                       rows: rows(certificate))
            }
        }
    }

    private func rows(_ certificate: SecurityModel.Certificate) -> [(String, String)] {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        var rows = [("Субъект", certificate.subject), ("Издатель", certificate.issuer)]
        if let from = certificate.notBefore { rows.append(("Действителен с", from.formatted(format))) }
        if let until = certificate.notAfter {
            rows.append(("Действителен до", until.formatted(format) + (until < .now ? " — истёк" : "")))
        }
        if !certificate.names.isEmpty { rows.append(("Альтернативные имена", certificate.names.joined(separator: ", "))) }
        if !certificate.publicKey.isEmpty { rows.append(("Открытый ключ", certificate.publicKey)) }
        if !certificate.signature.isEmpty { rows.append(("Подпись", certificate.signature)) }
        if !certificate.serial.isEmpty { rows.append(("Серийный номер", certificate.serial)) }
        rows.append(("SHA-256", certificate.sha256))
        return rows
    }

    private func originsList(_ origins: [SecurityModel.Origin]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Источники запросов").bold()
            if origins.isEmpty {
                Text("Запросов пока нет: они берутся из панели «Сеть».").foregroundStyle(Palette.secondaryText)
            }
            ForEach(origins) { origin in
                HStack(spacing: 8) {
                    Image(systemName: origin.isMixed ? "exclamationmark.triangle.fill" : origin.isSecure ? "lock.fill" : "lock.open")
                        .foregroundStyle(origin.isMixed ? Color.orange : origin.isSecure ? Color.green : Color.red)
                        .frame(width: 16)
                    Text(origin.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text(origin.isMixed ? "смешанное содержимое" : origin.isSecure ? "защищено" : "не защищено")
                        .foregroundStyle(Palette.secondaryText)
                    Text("\(origin.count)").foregroundStyle(Palette.secondaryText).frame(minWidth: 30, alignment: .trailing)
                }
            }
        }
    }
}
