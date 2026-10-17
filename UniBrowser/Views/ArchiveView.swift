import SwiftUI

/// The sidebar's "Архив": tabs removed by cleanup, newest first.
struct ArchiveView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Архив").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if store.archive.isEmpty {
                Text("Здесь появятся вкладки, убранные в архив.")
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.archive) { item in
                    HStack(spacing: 10) {
                        Favicon(url: item.url, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            Text([item.url?.host(), item.archivedAt.formatted(.relative(presentation: .named))]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.secondaryText)
                        }
                        Spacer()
                        Button("Вернуть") { store.restore(item.id); dismiss() }
                        Button { store.deleteArchived(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Удалить из архива")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 520, height: 440)
    }
}
