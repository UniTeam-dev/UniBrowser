// Self-check for Shared/Convenience/BrowserSettings.swift (search engines, suggestions):
//   swiftc -parse-as-library Shared/Convenience/BrowserSettings.swift scripts/search_engine_check.swift -o /tmp/search_engine_check && /tmp/search_engine_check
import Foundation

@main
enum SearchEngineCheck {
    static func main() async {
        let query = "кот & пёс?"
        for engine in SearchEngine.allCases {
            let url = engine.searchURL(for: query)
            assert(engine.query(in: url) == query, "\(engine): round trip failed for \(url)")
            for other in SearchEngine.allCases where other != engine {
                assert(other.query(in: url) == nil, "\(other) must not claim \(engine)'s results page")
            }
            let suggest = URLComponents(url: engine.suggestURL(for: query), resolvingAgainstBaseURL: false)!
            assert(suggest.scheme == "https" && suggest.queryItems!.contains { $0.value == query }, "\(engine) suggest URL")
        }
        assert(SearchEngine.yandex.searchURL(for: "a b").absoluteString == "https://yandex.ru/search/?text=a%20b")
        assert(SearchEngine.google.query(in: URL(string: "https://www.google.com/maps?q=x")!) == nil)

        assert(SearchSuggestions.parse(Data(#"["кот",["кот","котики",3],[],{"x":1}]"#.utf8)) == ["кот", "котики"])
        assert(SearchSuggestions.parse(Data("<html>".utf8)).isEmpty)
        assert(SearchSuggestions.parse(Data("[\"q\"]".utf8)).isEmpty)

        // Never sent in private browsing or for a typed URL, whatever the switch says.
        for (text, isPrivate) in [("кот", true), ("https://example.com", false), ("   ", false)] {
            let result = await SearchSuggestions.fetch(text, isPrivate: isPrivate)
            assert(result.isEmpty, "nothing may be fetched for \(text), private: \(isPrivate)")
        }

        UserDefaults.standard.removeObject(forKey: HomePage.key)
        assert(HomePage.url == nil)
        UserDefaults.standard.set(" ya.ru ", forKey: HomePage.key)
        assert(HomePage.url?.absoluteString == "https://ya.ru")
        UserDefaults.standard.removeObject(forKey: HomePage.key)
        print("search_engine_check: OK")
    }
}
