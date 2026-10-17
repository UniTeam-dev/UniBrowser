// Self-check for UniBrowser/DevTools/SourceMap.swift:
//   swiftc -parse-as-library UniBrowser/DevTools/SourceMap.swift scripts/sourcemap_check.swift -o /tmp/sourcemap_check && /tmp/sourcemap_check
import Foundation

@main
enum SourceMapCheck {
    static func main() throws {
        assert(SourceMap.vlq("A") == [0])
        assert(SourceMap.vlq("C") == [1])
        assert(SourceMap.vlq("D") == [-1])
        assert(SourceMap.vlq("gB") == [16])
        assert(SourceMap.vlq("2H") == [123])
        assert(SourceMap.vlq("jB") == [-17])
        assert(SourceMap.vlq("AAgBC") == [0, 0, 16, 1])
        assert(SourceMap.vlq("!") == nil)

        // Line 0: col 0 → a.js 0:0, col 4 → a.js 0:4 (name), col 10 → b.js 2:1.
        // Line 1 is empty. Line 2: col 2 → a.js 1:4 (fields relative across lines).
        let json = """
        {"version":3,"file":"out.js","sourceRoot":"src/","sources":["a.js","webpack:///./b.js"],
         "sourcesContent":["let a = 1;\\nfoo(a);",null],"names":["foo"],
         "mappings":"AAAA,IAAIA,MCEH;;EDDG"}
        """
        let map = try SourceMap(data: Data(json.utf8), url: URL(string: "https://x.test/js/out.js.map"))
        assert(map.sources == ["https://x.test/js/src/a.js", "webpack:///./b.js"], "\(map.sources)")
        assert(map.contents == ["let a = 1;\nfoo(a);", nil])
        func at(_ line: Int, _ column: Int) -> [Int]? {
            map.original(line: line, column: column).map { [$0.source, $0.line, $0.column] }
        }
        assert(at(0, 0) == [0, 0, 0])
        assert(at(0, 5) == [0, 0, 4])
        assert(at(0, 10) == [1, 2, 1])
        assert(at(0, 99) == [1, 2, 1])
        assert(at(1, 0) == nil)
        assert(at(2, 0) == nil)
        assert(at(2, 3) == [0, 1, 4], "\(String(describing: at(2, 3)))")
        assert(at(9, 0) == nil)

        // Data URL map and the comment that points at it.
        let comment = "x()\n//# sourceMappingURL=data:application/json;base64,\(Data(json.utf8).base64EncodedString())\n"
        let found = SourceMap.mappingURL(in: comment)
        assert(found?.hasPrefix("data:application/json;base64,") == true)
        assert(SourceMap.mappingURL(in: "a()\n//@ sourceMappingURL=app.js.map") == "app.js.map")
        assert(SourceMap.mappingURL(in: "a()") == nil)
        print("SourceMap: OK")
    }
}
