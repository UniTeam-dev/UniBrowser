import AppKit
import SwiftUI

/// A remote text file in a plain monospace editor. ⌘S saves; a failed save keeps the text and says why.
struct TextEditorSheet: View {
    let name: String
    let save: (String) async throws -> Void
    @State private var text: String
    @State private var saved: String
    @State private var isSaving = false
    @State private var error: String?
    @State private var isConfirmingClose = false
    @Environment(\.dismiss) private var dismiss

    init(name: String, text: String, save: @escaping (String) async throws -> Void) {
        self.name = name
        self.save = save
        _text = State(initialValue: text)
        _saved = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                if text != saved { Text("изменён").font(.caption).foregroundStyle(Palette.secondaryText) }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
            }
            PlainTextView(text: $text)
                .border(Color.primary.opacity(0.12))
            if let error {
                Text("Не удалось сохранить: \(error)").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Закрыть") { if text == saved { dismiss() } else { isConfirmingClose = true } }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") { Task { await write() } }
                    .keyboardShortcut("s")
                    .disabled(isSaving || text == saved)
            }
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .interactiveDismissDisabled(text != saved)
        .alert("Закрыть без сохранения?", isPresented: $isConfirmingClose) {
            Button("Не сохранять", role: .destructive) { dismiss() }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func write() async {
        let snapshot = text
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(snapshot)
            saved = snapshot
            error = nil
        } catch {
            self.error = SFTPBrowser.message(for: error)
        }
    }
}

/// Monospace plain text that keeps exactly what is typed: SwiftUI's `TextEditor` may turn quotes and
/// dashes into typographic ones, which breaks configs and scripts.
private struct PlainTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.string = text
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        let view = scroll.documentView as! NSTextView
        if view.string != text { view.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}
