import SwiftUI

/// ⌘Y: visits by day, or search results, with open / ⌘-click in background, a context menu
/// and «Очистить историю…».
struct HistoryWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var isClearing = false

    private static let russian = Locale(identifier: "ru_RU")

    private struct Day: Identifiable {
        let date: Date
        let visits: [Visit]
        var id: Date { date }
    }

    /// Recomputed when the store's `revision` changes (read below); each query is sub-millisecond.
    private var days: [Day] {
        let history = model.history
        _ = history.revision
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return history.days(limit: 400).map { Day(date: $0, visits: history.visits(on: $0)) }
        }
        let calendar = Calendar.current
        let found = history.search(q, limit: 500)
        return Dictionary(grouping: found) { calendar.startOfDay(for: $0.visitedAt) }
            .map { Day(date: $0.key, visits: $0.value.sorted { $0.visitedAt > $1.visitedAt }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        let days = days
        List {
            ForEach(days) { day in
                Section(Self.title(of: day.date)) {
                    ForEach(day.visits) { row($0) }
                }
            }
        }
        .overlay {
            if days.isEmpty {
                ContentUnavailableView(query.isEmpty ? "История пуста" : "Ничего не найдено", systemImage: "clock")
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Поиск в истории")
        .toolbar {
            Button("Очистить историю…") { isClearing = true }
        }
        .confirmationDialog("Очистить историю", isPresented: $isClearing) {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            Button("За последний час", role: .destructive) { model.history.delete(since: .now.addingTimeInterval(-3600)) }
            Button("За сегодня", role: .destructive) { model.history.delete(since: today) }
            Button("За сегодня и вчера", role: .destructive) {
                model.history.delete(since: calendar.date(byAdding: .day, value: -1, to: today) ?? today)
            }
            Button("За всё время", role: .destructive) { model.history.deleteAll() }
        } message: {
            Text("Посещённые страницы удалятся с этого Mac.")
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func row(_ visit: Visit) -> some View {
        HStack(spacing: 10) {
            Favicon(url: visit.url, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.title.isEmpty ? visit.url.absoluteString : visit.title).lineLimit(1)
                Text(visit.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(visit.visitedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Self.russian)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(visit.url.absoluteString)
        .onTapGesture {
            // ⌘-click: a background tab, this window stays in front.
            if NSEvent.modifierFlags.contains(.command) {
                model.store.openFromLibrary(visit.url, background: true)
            } else {
                model.store.openFromLibrary(visit.url)
                openWindow(id: "main")
            }
        }
        .contextMenu {
            Button("Открыть") {
                model.store.openFromLibrary(visit.url)
                openWindow(id: "main")
            }
            Button("Открыть в новой вкладке") {
                model.store.openFromLibrary(visit.url, newTab: true)
                openWindow(id: "main")
            }
            Button("Скопировать ссылку") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(visit.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Удалить") { model.history.delete(ids: [visit.id]) }
            if !visit.host.isEmpty {
                Button("Удалить все посещения сайта \(visit.host)") { model.history.delete(host: visit.host) }
            }
        }
    }

    private static func title(of day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Сегодня" }
        if calendar.isDateInYesterday(day) { return "Вчера" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        let style = Date.FormatStyle().weekday(.wide).day().month(.wide).locale(russian)
        let text = day.formatted(sameYear ? style : style.year())
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
