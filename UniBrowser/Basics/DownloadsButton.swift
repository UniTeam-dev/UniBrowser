import SwiftUI

/// The sidebar's «Загрузки»: a badge while files download, the list in a popover.
struct DownloadsButton: View {
    @State private var downloads = Downloads.shared
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "arrow.down.to.line")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if downloads.activeCount > 0 {
                        Text("\(downloads.activeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Palette.accent, in: Capsule())
                            .offset(x: 5, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(downloads.activeCount > 0 ? Palette.accent : Palette.secondaryText)
        .help("Загрузки")
        .accessibilityLabel(downloads.activeCount > 0 ? "Загрузки, идёт: \(downloads.activeCount)" : "Загрузки")
        .popover(isPresented: $isShown, arrowEdge: .top) { DownloadsList(downloads: downloads) }
    }
}

private struct DownloadsList: View {
    let downloads: Downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Загрузки").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Очистить") { downloads.clear() }
                    .disabled(downloads.items.allSatisfy { $0.state == .running })
            }
            .padding(12)
            Divider()
            if downloads.items.isEmpty {
                Text("Скачанные файлы появятся здесь.")
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.items) { DownloadRow(item: $0, downloads: downloads) }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .font(.system(size: 12))
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let downloads: Downloads

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let file = item.file, item.state == .finished {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path(percentEncoded: false)))
                        .resizable()
                } else {
                    Image(systemName: "doc").font(.system(size: 20)).foregroundStyle(Palette.secondaryText)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.state == .running {
                    ProgressView(value: item.progress).progressViewStyle(.linear).tint(Palette.accent)
                }
                Text(item.detail).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.state == .running {
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Отменить")
                    .accessibilityLabel("Отменить загрузку")
            } else if item.state == .finished, let file = item.file {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Показать в Finder")
                    .accessibilityLabel("Показать в Finder")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            if item.state == .finished, let file = item.file {
                Button("Открыть") { open() }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            if item.state == .running { Button("Отменить") { downloads.cancel(item) } }
            if let source = item.source, !["blob", "data"].contains(source.scheme) {
                Button("Скопировать адрес") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
            Button("Убрать из списка") { downloads.remove(item) }
        }
    }

    /// Double-click or «Открыть»: the file in its app (a quarantined app still meets Gatekeeper).
    private func open() {
        if item.state == .finished, let file = item.file { NSWorkspace.shared.open(file) }
    }
}
