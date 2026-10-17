import SwiftUI

/// "Вечерняя уборка": one stale tab at a time, archive it (←) or keep it (→).
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store
    let session: AppModel.CleanupSession

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        ZStack {
            Button { model.cleanup = nil } label: {
                Color(red: 20 / 255, green: 20 / 255, blue: 28 / 255).opacity(0.28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть уборку")

            VStack(alignment: .leading, spacing: 14) {
                if let id = session.current, let tab = store.tab(id) {
                    content(tab)
                } else {
                    Text("Вечерняя уборка").font(.system(size: 17, weight: .semibold))
                    Text("Нет вкладок, которые не открывались больше 12 часов.")
                        .foregroundStyle(Palette.secondaryText)
                    HStack {
                        Spacer()
                        Button("Закрыть") { model.cleanup = nil }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(22)
            .frame(width: 480)
            .background(Color(hex: "#F6F6F8"), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 32, y: 24)
        }
    }

    @ViewBuilder
    private func content(_ tab: BrowserTab) -> some View {
        let total = session.queue.count
        let remaining = session.remaining.count
        HStack {
            Text("Вечерняя уборка").font(.system(size: 17, weight: .semibold))
            Spacer()
            Text("\(session.index + 1) из \(total)").font(.system(size: 13)).foregroundStyle(Palette.secondaryText)
        }
        Text("\(total) \(Plural.tabs(total)) \(Plural.verbPast(total, singular: "не открывалась", plural: "не открывались")) больше 12 часов. Всё, что уберёте, останется в архиве и найдётся через ⌘K.")
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        ProgressView(value: Double(session.index), total: Double(max(total, 1)))
            .progressViewStyle(.linear)
            .tint(Palette.accent)

        card(tab)
            .background {
                // The cards still to come, peeking out under the current one.
                ForEach(Array([2, 1].filter { $0 < remaining }), id: \.self) { depth in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                        .scaleEffect(1 - Double(depth) * 0.05, anchor: .bottom)
                        .offset(y: Double(depth) * 8)
                }
            }
            .padding(.bottom, remaining > 1 ? 16 : 0)

        HStack(spacing: 10) {
            Button { model.archiveCurrentCleanupTab() } label: {
                Text("← В архив").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button { model.advanceCleanup() } label: {
                Text("Оставить →").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
        }
        HStack {
            Button("Напомнить завтра в 10:00") { model.remindCleanupTomorrow() }
            Spacer()
            Button("Убрать все \(remaining) в архив") { model.archiveAllCleanupTabs() }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }

    private func card(_ tab: BrowserTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = tab.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ZStack {
                        Color(hex: "#E8E8EC")
                        Favicon(url: tab.url, size: 40)
                    }
                }
            }
            .frame(height: 170)
            .clipped()
            HStack(spacing: 10) {
                Favicon(tab: tab, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text("\(tab.url?.host() ?? "") · открыта \(Self.relative.localizedString(for: tab.lastActivated, relativeTo: .now))")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
