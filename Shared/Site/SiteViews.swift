import SwiftUI
import WebKit

/// «О сайте»: the Mac's popover from the lock icon and the iPhone's sheet from «…».
/// Connection, permissions, ad blocking, zoom, cookies and «Очистить данные сайта».
struct SiteInfoView: View {
    let webView: WKWebView
    let settings: SiteSettingsStore
    /// The rows this platform can honour.
    let permissions: [SitePermission]
    var permissionsNote: String?
    /// Requests blocked on this page; nil where WebKit doesn't report them (iPhone).
    var blockedCount: Int?

    @State private var cookieCount: Int?
    @State private var certificate: (subject: String, issuer: String?)?
    @State private var isClearing = false
    @AppStorage(ContentBlocker.enabledKey) private var isAdBlockOn = true

    private var url: URL? { webView.url }
    private var host: String { url?.host() ?? "" }

    var body: some View {
        Form {
            Section {
                Label(connection.text, systemImage: connection.symbol)
                    .foregroundStyle(connection.isSecure ? Color.primary : Color.orange)
                if let certificate {
                    LabeledContent("Сертификат", value: certificate.subject)
                    if let issuer = certificate.issuer { LabeledContent("Выдан", value: issuer) }
                }
            } header: {
                Text(host.isEmpty ? (url?.absoluteString ?? "") : host).font(.headline).textCase(nil)
            }

            if !host.isEmpty {
                Section {
                    ForEach(permissions) { permission in
                        Picker(permission.title, selection: Binding(
                            get: { settings.decision(permission, host: host) },
                            set: { settings.set($0, for: permission, host: host) }
                        )) {
                            ForEach(SiteDecision.allCases) { Text($0.title).tag($0) }
                        }
                    }
                } header: {
                    Text("Разрешения")
                } footer: {
                    if let permissionsNote { Text(permissionsNote) }
                }

                Section {
                    if isAdBlockOn {
                        Toggle("Блокировать рекламу на этом сайте", isOn: Binding(
                            get: { !settings.allowsAds(host: host) },
                            set: {
                                settings.setAllowsAds(!$0, host: host)
                                webView.reload()
                            }
                        ))
                        if let blockedCount {
                            LabeledContent("Заблокировано на странице", value: "\(blockedCount)")
                        }
                    } else {
                        Text("Блокировка рекламы выключена в настройках").foregroundStyle(.secondary)
                    }
                    if abs(webView.pageZoom - 1) > 0.001 {
                        LabeledContent("Масштаб", value: "\(Int((webView.pageZoom * 100).rounded())) %")
                    }
                }

                Section {
                    LabeledContent("Файлы cookie", value: cookieCount.map(String.init) ?? "…")
                    Button("Очистить данные сайта", role: .destructive) {
                        Task { await clearSiteData() }
                    }
                    .disabled(isClearing)
                } footer: {
                    Text("Удаляет cookie, кэш и хранилища \(host) и перезагружает страницу.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            readCertificate()
            await countCookies()
        }
    }

    private var connection: (text: String, symbol: String, isSecure: Bool) {
        switch url?.scheme {
        case "https" where webView.hasOnlySecureContent: ("Соединение защищено", "lock.fill", true)
        case "https": ("Часть содержимого загружена без защиты", "lock.trianglebadge.exclamationmark", false)
        case "http": ("Соединение не защищено", "exclamationmark.triangle", false)
        default: ("Локальная страница", "doc", true)
        }
    }

    private func readCertificate() {
        guard let trust = webView.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? host
        let issuer = chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? : nil
        certificate = (subject, issuer)
    }

    /// The host itself or a parent domain the cookie or data record belongs to.
    private func belongs(_ domain: String) -> Bool {
        let domain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    private func countCookies() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        cookieCount = cookies.filter { belongs($0.domain) }.count
    }

    private func clearSiteData() async {
        isClearing = true
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter { belongs($0.displayName) }
        await store.removeData(ofTypes: types, for: records)
        // Cookies set for a parent domain WebKit groups under another record.
        for cookie in await store.httpCookieStore.allCookies() where belongs(cookie.domain) {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        await countCookies()
        isClearing = false
        webView.reload()
    }
}

/// «Сайт хочет использовать камеру — Разрешить / Запретить, запомнить», above the page
/// while the page waits for the answer.
struct PermissionBar: View {
    @Bindable var request: PermissionRequest

    var body: some View {
        // One row where it fits (the Mac), the question above the buttons on a phone.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                question
                Spacer(minLength: 4)
                controls
            }
            VStack(alignment: .leading, spacing: 6) {
                question
                HStack(spacing: 10) { controls }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var question: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(request.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var controls: some View {
        #if os(macOS)
        Toggle("Запомнить", isOn: $request.remember)
            .toggleStyle(.checkbox)
        #else
        Toggle("Запомнить", isOn: $request.remember)
            .fixedSize()
        Spacer(minLength: 0)
        #endif
        Button("Запретить") { request.answer(false) }
            .fixedSize()
        Button("Разрешить") { request.answer(true) }
            .buttonStyle(.borderedProminent)
            .fixedSize()
    }

    private var symbol: String {
        switch request.permissions.first {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .geolocation: "location.fill"
        default: "bell.fill"
        }
    }
}
