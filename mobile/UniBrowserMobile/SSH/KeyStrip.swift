import SwiftUI
import UIKit

/// What the strip above the keyboard shows; the terminal fills it.
@MainActor
@Observable
final class KeyStripModel {
    enum Arrow { case up, down, left, right }

    var suggestions: [Suggestion] = []
    /// «Подсказки в терминале»: the suggestion row is there at all.
    var showsSuggestions = true
    var isControl = false
}

/// The terminal's input accessory: SwiftUI `KeyStrip` in a keyboard-styled input view.
final class KeyStripHost: UIInputView {
    private static let keysHeight: CGFloat = 44
    private static let suggestionsHeight: CGFloat = 38
    private weak var terminal: SSHTerminalView?

    init(terminal: SSHTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero, inputViewStyle: .keyboard)
        let host = UIHostingController(rootView: KeyStrip(model: terminal.strip) { [weak terminal] key in
            guard let terminal else { return }
            UIDevice.current.playInputClick()
            switch key {
            case .escape: terminal.send([0x1B])
            case .tab: terminal.send([0x09])
            case .control: terminal.toggleControl()
            case .arrow(let arrow): terminal.sendArrow(arrow)
            case .text(let text): terminal.send(txt: text)
            case .suggestion(let suggestion): terminal.accept(suggestion)
            case .hideKeyboard: _ = terminal.resignFirstResponder()
            }
        })
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        autoresizingMask = .flexibleWidth
        fit()
    }

    required init?(coder: NSCoder) { nil }

    /// One row of keys, plus one of suggestions while they're on.
    func fit() {
        let height = Self.keysHeight + (terminal?.strip.showsSuggestions == true ? Self.suggestionsHeight : 0)
        frame.size.height = height
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: frame.height)
    }
}

extension KeyStripHost: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Esc, Tab, sticky Ctrl, arrows, `|` `/` `-`, hide keyboard; above them the suggestions, a tap types the rest.
struct KeyStrip: View {
    enum Key {
        case escape, tab, control
        /// The bottom bar steps aside while the keyboard is up; this brings it back.
        case hideKeyboard
        case arrow(KeyStripModel.Arrow)
        case text(String)
        case suggestion(Suggestion)
    }

    let model: KeyStripModel
    let press: (Key) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.showsSuggestions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.suggestions, id: \.self) { suggestion in
                            Button { press(.suggestion(suggestion)) } label: {
                                Label(suggestion.display, systemImage: icon(suggestion))
                                    .font(.system(size: 14, design: .monospaced))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .background(.background.opacity(0.7), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(height: 38)
            }
            HStack(spacing: 4) {
                key("Esc", .escape)
                key("Tab", .tab)
                key("Ctrl", .control, isOn: model.isControl)
                key("↑", .arrow(.up), label: "Вверх", image: "arrow.up")
                key("↓", .arrow(.down), label: "Вниз", image: "arrow.down")
                key("←", .arrow(.left), label: "Влево", image: "arrow.left")
                key("→", .arrow(.right), label: "Вправо", image: "arrow.right")
                key("|", .text("|"))
                key("/", .text("/"))
                key("-", .text("-"))
                key("", .hideKeyboard, label: "Скрыть клавиатуру", image: "keyboard.chevron.compact.down")
            }
            .padding(.horizontal, 4)
            .frame(height: 44)
        }
    }

    private func key(_ title: String, _ key: Key, isOn: Bool = false, label: String? = nil, image: String? = nil) -> some View {
        Button { press(key) } label: {
            Group {
                if let image { Image(systemName: image) } else { Text(title) }
            }
            .font(.system(size: 15, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? Color.accentColor : Color(uiColor: .systemBackground).opacity(0.75),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func icon(_ suggestion: Suggestion) -> String {
        switch suggestion.kind {
        case .history: "clock.arrow.circlepath"
        case .command: "terminal"
        case .path: suggestion.display.hasSuffix("/") ? "folder" : "doc"
        }
    }
}
