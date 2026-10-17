// Self-check for UniBrowser/Web/LoginFormScript.swift: loads login pages of the kinds sites use
// into a real WKWebView, signs in, and checks the script reports the login from the right frame.
//   swiftc -parse-as-library UniBrowser/Web/LoginFormScript.swift scripts/login_capture_check.swift -o /tmp/login_capture_check && /tmp/login_capture_check
import AppKit
import WebKit

@MainActor
final class Probe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var submitted: [(host: String, username: String, password: String)] = []
    var loaded = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["action"] as? String == "submitted" else { return }
        submitted.append((message.frameInfo.securityOrigin.host,
                          body["username"] as? String ?? "", body["password"] as? String ?? ""))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
}

@main
@MainActor
enum LoginCaptureCheck {
    static var failed = false
    static let port = 8000 + Int.random(in: 700...999)

    static let pages: [String: String] = [
        "form.html": #"<form action="/done.html"><input name=u autocomplete=username><input type=password name=p><button>Войти</button></form>"#,
        "iframe.html": #"<iframe src="/form.html"></iframe>"#,
        "shadow.html": #"<div id=h></div><script>h.attachShadow({mode:'open'}).innerHTML='<input id=u><input id=p type=password><button id=go>Войти</button>'</script>"#,
        "div.html": #"<input id=u><input id=p type=password><div id=go style="cursor:pointer">Войти</div><script>go.onclick=()=>fetch('/done.html').then(()=>location.href='/done.html')</script>"#,
        "script.html": #"<input id=u><input id=p type=password><script>window.leave=()=>location.href='/done.html'</script>"#,
        "done.html": "ok",
    ]

    // Fills the login and password the way typing does, then signs in.
    static let fill = """
    const fill = (root) => {
      const set = (el, v) => { el.value = v; el.dispatchEvent(new Event('input', {bubbles: true})); };
      set(root.querySelector('input:not([type=password])'), 'ilja');
      set(root.querySelector('input[type=password]'), 'secret');
    };
    """

    static func check(_ name: String, page: String, expectHost: String = "localhost", _ signIn: String) async {
        let probe = Probe()
        let configuration = WKWebViewConfiguration()
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: LoginFormScript.source, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: false, in: LoginFormScript.world))
        content.add(probe, contentWorld: LoginFormScript.world, name: LoginFormScript.handlerName)
        configuration.userContentController = content
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        webView.navigationDelegate = probe
        webView.load(URLRequest(url: URL(string: "http://localhost:\(port)/\(page)")!))
        while !probe.loaded { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(300))
        _ = try? await webView.evaluateJavaScript(fill + signIn + ";1")
        try? await Task.sleep(for: .seconds(1.5))
        let ok = probe.submitted.contains { $0 == (expectHost, "ilja", "secret") }
        print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — got \(probe.submitted)")")
        if !ok { failed = true }
        _ = window
    }

    static func main() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "login-capture-\(port)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, html) in pages { try? Data(html.utf8).write(to: dir.appending(path: name)) }
        let server = Process()
        server.executableURL = URL(filePath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", dir.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try? server.run()
        try? await Task.sleep(for: .seconds(1))
        NSApplication.shared.setActivationPolicy(.prohibited)

        await check("form submit", page: "form.html", "fill(document); document.querySelector('form').requestSubmit()")
        await check("form in an iframe", page: "iframe.html",
                    "const d = frames[0].document; fill(d); d.querySelector('form').requestSubmit()")
        await check("fields in a shadow root, button click", page: "shadow.html",
                    "const r = h.shadowRoot; fill(r); r.getElementById('go').click()")
        await check("div acting as a button", page: "div.html", "fill(document); go.click()")
        await check("script navigates away without a click", page: "script.html", "fill(document); leave()")

        server.terminate()
        exit(failed ? 1 : 0)
    }
}
