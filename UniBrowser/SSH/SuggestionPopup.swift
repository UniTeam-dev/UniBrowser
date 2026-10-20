import SwiftUI

/// The terminal's suggestion list; `SSHTerminalView` places it at the cursor and handles its keys.
struct SuggestionPopup: View {
    let suggestions: [Suggestion]
    let selected: Int
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                HStack(spacing: 6) {
                    Image(systemName: icon(suggestion)).foregroundStyle(.secondary).frame(width: 14)
                    Text(suggestion.display).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: fontSize, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index == selected ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
    }

    private func icon(_ suggestion: Suggestion) -> String {
        switch suggestion.kind {
        case .history: "clock.arrow.circlepath"
        case .command: "terminal"
        case .path: suggestion.display.hasSuffix("/") ? "folder" : "doc"
        }
    }
}
