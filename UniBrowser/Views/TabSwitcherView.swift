import SwiftUI

/// Shown while Ctrl is held after Ctrl+Tab: the space's tabs, most recent first.
struct TabSwitcherView: View {
    @Environment(BrowserStore.self) private var store
    let highlighted: Int

    var body: some View {
        let tabs = Array(store.tabsByRecency.prefix(9))
        HStack(spacing: 10) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                VStack(spacing: 8) {
                    Favicon(tab: tab, size: 36)
                    Text(tab.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 112, height: 32, alignment: .top)
                    Text(store.groupName(containing: tab.id) ?? tab.url?.host() ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(index == highlighted ? .white.opacity(0.85) : Palette.secondaryText)
                        .lineLimit(1)
                }
                .foregroundStyle(index == highlighted ? .white : Palette.text)
                .padding(12)
                .background(index == highlighted ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
