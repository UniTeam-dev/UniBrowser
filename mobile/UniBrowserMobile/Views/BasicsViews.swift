import SwiftUI
import WebKit

// MARK: - Page zoom («aA» in «…»)

extension MobileTab {
    /// `WKWebView.pageZoom` has no visible effect on iPhone pages that fit the screen
    /// (checked in the simulator), so this scales text like Safari's «aA»: `-webkit-text-size-adjust`.
    func applyZoom(_ level: Double) {
        pageZoom = level
        let value = abs(level - 1) < 0.001 ? "" : "\(Int((level * 100).rounded()))%"
        webView?.evaluateJavaScript("document.documentElement && (document.documentElement.style.webkitTextSizeAdjust = '\(value)')", in: nil, in: .defaultClient)
    }
}

extension MobileStore {
    /// − / + (`up`) or back to 100 % (nil) for the selected tab's site, remembered per host.
    func zoomSelectedTab(up: Bool?) {
        guard let tab = selectedTab, let host = tab.url?.host() else { return }
        let level = up.map { PageZoom.step(from: tab.pageZoom, up: $0) } ?? 1
        PageZoom.setLevel(level, for: host)
        for other in tabs.values where other.url?.host() == host { other.applyZoom(level) }
    }
}

/// «aA»: − / 100 % / + in one row of the «…» menu; it stays open while tapping.
struct ZoomMenuRow: View {
    let store: MobileStore
    let tab: MobileTab

    var body: some View {
        ControlGroup {
            Button { store.zoomSelectedTab(up: false) } label: { Image(systemName: "textformat.size.smaller") }
                .accessibilityLabel("Уменьшить")
            Button(PageZoom.label(tab.pageZoom)) { store.zoomSelectedTab(up: nil) }
                .accessibilityLabel("Масштаб \(PageZoom.label(tab.pageZoom)), сбросить")
            Button { store.zoomSelectedTab(up: true) } label: { Image(systemName: "textformat.size.larger") }
                .accessibilityLabel("Увеличить")
        } label: {
            Label("Масштаб", systemImage: "textformat.size")
        }
        .menuActionDismissBehavior(.disabled)
    }
}

// MARK: - Find in page

extension MobileTab {
    /// «Найти на странице»: the system find bar over the keyboard (UIFindInteraction).
    func showFind() {
        guard let webView else { return }
        webView.isFindInteractionEnabled = true
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }
}

// MARK: - Downloads

/// «Загрузки» in «…»: this run's downloads; the files themselves stay in «Файлы → На iPhone → UniBrowser».
struct DownloadsSheet: View {
    @State private var downloads = Downloads.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if downloads.items.isEmpty {
                    Text("Скачанные файлы появятся здесь и в приложении «Файлы».")
                        .foregroundStyle(.secondary)
                }
                ForEach(downloads.items) { item in
                    row(item)
                        .swipeActions {
                            Button(item.state == .running ? "Отменить" : "Убрать", role: .destructive) { downloads.remove(item) }
                        }
                }
            }
            .navigationTitle("Загрузки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Очистить") { downloads.clear() }
                        .disabled(downloads.items.allSatisfy { $0.state == .running })
                }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.state == .finished ? "doc.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.state == .running { ProgressView(value: item.progress) }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.state == .running {
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Отменить загрузку")
            } else if item.state == .finished, let file = item.file {
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Поделиться")
            }
        }
    }
}
