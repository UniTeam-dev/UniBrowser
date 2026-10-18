import AppKit
import UniformTypeIdentifiers
import WebKit

/// «Файл → Печать…» (⌘P) and «Сохранить как PDF…» for the selected tab.
@MainActor
enum PagePrinting {
    static func print(_ webView: WKWebView) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        // WebKit's print view starts with a zero frame and prints blank pages without one.
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    static func savePDF(_ webView: WKWebView, title: String) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName(title)
        let response = if let window = webView.window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        do {
            try await webView.pdf().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The page title without characters Finder doesn't allow, or «Страница».
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Страница" : String(cleaned.prefix(120))) + ".pdf"
    }
}
