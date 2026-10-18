import Foundation

/// Page zoom steps (Safari's) and the level remembered per site, compiled into both apps.
enum PageZoom {
    static let steps: [Double] = [0.5, 0.75, 0.85, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The next step up or down from `level`; stays put at either end.
    static func step(from level: Double, up: Bool) -> Double {
        if up { return steps.first { $0 > level + 0.001 } ?? steps.last! }
        return steps.last { $0 < level - 0.001 } ?? steps.first!
    }

    /// «110 %», with a no-break space so it never wraps.
    static func label(_ level: Double) -> String {
        "\(Int((level * 100).rounded()))\u{00A0}%"
    }

    private static let key = "pageZoomByHost"

    /// The level saved for the site, 1 when none (or no host: about:, data:).
    static func level(for host: String?, in defaults: UserDefaults = .standard) -> Double {
        guard let host else { return 1 }
        return (defaults.dictionary(forKey: key)?[host] as? Double) ?? 1
    }

    /// 100 % forgets the site, so the dictionary only holds zoomed ones.
    static func setLevel(_ level: Double, for host: String?, in defaults: UserDefaults = .standard) {
        guard let host else { return }
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[host] = abs(level - 1) < 0.001 ? nil : level
        defaults.set(all, forKey: key)
    }
}
