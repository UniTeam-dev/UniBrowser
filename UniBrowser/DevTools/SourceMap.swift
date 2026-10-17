import Foundation

/// A source map, version 3 (spec «Источники»): original sources and the mapping from
/// generated line/column to original ones. Lines and columns are 0-based.
/// Self-check: scripts/sourcemap_check.swift.
struct SourceMap: Sendable {
    struct Segment: Sendable {
        var column: Int
        var source: Int
        var line: Int
        var sourceColumn: Int
    }

    enum DecodeError: Error { case notAMap, badMappings }

    /// Absolute URLs (or `webpack://…` and the like as written).
    let sources: [String]
    /// `sourcesContent`, nil where the map leaves it out.
    let contents: [String?]
    /// Segments by generated line, sorted by column; only those that point at a source.
    let lines: [[Segment]]

    // ponytail: index maps ("sections") are not decoded; add when a bundler emits them here.
    init(data: Data, url: URL?) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSources = json["sources"] as? [Any],
              let mappings = json["mappings"] as? String
        else { throw DecodeError.notAMap }
        var root = json["sourceRoot"] as? String ?? ""
        if !root.isEmpty, !root.hasSuffix("/") { root += "/" }
        sources = rawSources.map { raw in
            let source = raw as? String ?? ""
            if URL(string: source)?.scheme != nil { return source }
            let path = root + source
            return URL(string: path, relativeTo: url)?.absoluteString ?? path
        }
        let rawContents = json["sourcesContent"] as? [Any] ?? []
        contents = sources.indices.map { rawContents.indices.contains($0) ? rawContents[$0] as? String : nil }

        var lines: [[Segment]] = []
        var source = 0, line = 0, sourceColumn = 0
        for text in mappings.split(separator: ";", omittingEmptySubsequences: false) {
            var column = 0
            var segments: [Segment] = []
            for field in text.split(separator: ",") {
                guard let values = Self.vlq(field), !values.isEmpty else { throw DecodeError.badMappings }
                column += values[0]
                guard values.count >= 4 else { continue }
                source += values[1]
                line += values[2]
                sourceColumn += values[3]
                segments.append(Segment(column: column, source: source, line: line, sourceColumn: sourceColumn))
            }
            lines.append(segments.sorted { $0.column < $1.column })
        }
        self.lines = lines
    }

    /// The original position of a generated one: the last segment at or before `column`.
    func original(line: Int, column: Int) -> (source: Int, line: Int, column: Int)? {
        guard lines.indices.contains(line),
              let segment = lines[line].last(where: { $0.column <= column }),
              sources.indices.contains(segment.source)
        else { return nil }
        return (segment.source, segment.line, segment.sourceColumn)
    }

    private static let base64: [Character: Int] = Dictionary(
        uniqueKeysWithValues: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".enumerated().map { ($1, $0) }
    )

    /// Base64 VLQ: 5 value bits per digit, bit 6 means "more digits", the lowest bit of the
    /// first digit is the sign. nil on a character outside base64.
    static func vlq(_ text: Substring) -> [Int]? {
        var values: [Int] = []
        var value = 0, shift = 0
        for character in text {
            guard let digit = base64[character] else { return nil }
            value += (digit & 31) << shift
            if digit & 32 != 0 {
                shift += 5
                continue
            }
            values.append(value & 1 == 1 ? -(value >> 1) : value >> 1)
            value = 0
            shift = 0
        }
        return shift == 0 ? values : nil
    }

    /// The last `//# sourceMappingURL=` (or `/*# … */`, or the old `//@`) in a file.
    static func mappingURL(in text: String) -> String? {
        let tail = text.suffix(100_000)
        guard let range = tail.range(of: #"[#@]\s*sourceMappingURL=[^\s*]+"#, options: [.regularExpression, .backwards]) else { return nil }
        let url = tail[range].split(separator: "=", maxSplits: 1)[1]
        return String(url)
    }
}
