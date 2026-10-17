import SwiftUI
import WebKit

/// ⌥+click: the link opens in a card over the window. Esc or a click outside closes it
/// without creating a tab.
struct PeekView: View {
    @Environment(AppModel.self) private var model
    let page: PeekPage

    var body: some View {
        ZStack {
            Button { model.closePeek() } label: {
                Color(red: 20 / 255, green: 20 / 255, blue: 28 / 255).opacity(0.28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть Peek")

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Favicon(url: page.url, size: 22)
                    Text(page.url?.absoluteString ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("В Split View") { model.peekToSplit() }
                    Button("Сделать вкладкой") { model.peekToTab() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                    Button { model.closePeek() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityLabel("Закрыть")
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                Divider()
                PeekWebView(webView: page.webView)
            }
            .frame(maxWidth: 760, maxHeight: 640)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 32, y: 24)
            .padding(EdgeInsets(top: 40, leading: 40, bottom: 72, trailing: 40))

            VStack {
                Spacer()
                Text("⌥+клик по ссылке: открыть поверх · Esc: закрыть, вкладка не создаётся")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color(hex: "#1D1D1F").opacity(0.8), in: Capsule())
                    .padding(.bottom, 24)
            }
        }
    }
}

struct PeekWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        container.window?.makeFirstResponder(webView)
    }
}
