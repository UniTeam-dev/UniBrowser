// Self-check for UniBrowser/DevTools/NetworkData.swift (cURL, fetch, HAR, rule list):
//   swiftc -parse-as-library UniBrowser/DevTools/NetworkData.swift scripts/network_check.swift -o /tmp/network_check && /tmp/network_check
import Foundation

@main
enum NetworkCheck {
    static func main() {
        var entry = NetworkEntry(id: "f1", url: "https://api.example.com/v1/items?q=a%20b&n=2", start: 1_700_000_000_000)
        entry.method = "POST"
        entry.kind = .fetch
        entry.requestHeaders = [NetworkHeader(name: "Content-Type", value: "application/json")]
        entry.requestBody = #"{"name":"it's"}"#
        entry.status = 201
        entry.statusText = "Created"
        entry.responseHeaders = [NetworkHeader(name: "Content-Type", value: "application/json")]
        entry.responseBody = #"{"id":7}"#
        entry.end = entry.start + 120
        entry.timings = NetworkTimings(blocked: 1, dns: 2, connect: 3, ssl: 1, send: 0, wait: 50, receive: 64)
        entry.frames = [NetworkFrame(outgoing: true, data: "hi", length: 2, time: entry.start + 5)]

        // Names and queries.
        assert(entry.name == "items?q=a%20b&n=2", entry.name)
        assert(entry.queryItems == [NetworkHeader(name: "q", value: "a b"), NetworkHeader(name: "n", value: "2")])

        // cURL: single quotes escaped, POST with a body needs no -X.
        let curl = NetworkFormat.curl(entry)
        assert(curl.contains(#"--data-raw '{"name":"it'\''s"}'"#), curl)
        assert(!curl.contains("-X"), curl)
        var put = entry
        put.method = "PUT"
        assert(NetworkFormat.curl(put).contains("-X 'PUT'"))

        // fetch: valid JS string literals.
        let fetch = NetworkFormat.fetch(entry)
        assert(fetch.hasPrefix(#"fetch("https://api.example.com/v1/items?q=a%20b&n=2", {"#), fetch)
        assert(fetch.contains(#""body": "{\"name\":\"it's\"}""#), fetch)
        assert(fetch.contains(#""content-type": "application/json""#), fetch)

        // Content rule list: `*` → `.*`, regex specials escaped, Офлайн blocks everything.
        assert(NetworkFormat.urlFilter("*.example.com/ads/*") == #".*\.example\.com\/ads\/.*"#, NetworkFormat.urlFilter("*.example.com/ads/*"))
        assert(NetworkFormat.urlFilter("a?b(c)") == #"a\?b\(c\)"#)
        assert(NetworkFormat.ruleList(offline: false, patterns: []) == nil)
        assert(NetworkFormat.ruleList(offline: true, patterns: [])!.contains(#""url-filter":".*""#))
        assert(NetworkFormat.ruleList(offline: false, patterns: ["x.png"])!.contains(#""url-filter":"x\\.png""#))

        // Sites for «Только сторонние».
        assert(NetworkFormat.site("cdn.example.com") == "example.com")
        assert(NetworkFormat.site("a.b.example.co.uk") == "example.co.uk")
        assert(NetworkFormat.site("127.0.0.1") == "127.0.0.1")

        // JSON pretty-print.
        assert(NetworkFormat.prettyJSON(#"{"b":1,"a":[1]}"#) == "{\n  \"a\" : [\n    1\n  ],\n  \"b\" : 1\n}")
        assert(NetworkFormat.prettyJSON("<html>") == nil)

        // HAR round trip.
        let har = NetworkHAR.export([entry], pageURL: "https://example.com/", pageTitle: "")
        let back = try! NetworkHAR.entries(from: har)
        assert(back.count == 1)
        let item = back[0]
        assert(item.imported && item.url == entry.url && item.method == "POST" && item.status == 201)
        assert(item.requestBody == entry.requestBody && item.responseBody == entry.responseBody)
        assert(item.requestHeaders == entry.requestHeaders && item.responseHeaders == entry.responseHeaders)
        assert(abs(item.start - entry.start) < 1 && abs((item.end ?? 0) - entry.end!) < 1)
        assert(item.timings == entry.timings, "\(String(describing: item.timings))")
        assert(item.kind == .fetch && item.frames.count == 1 && item.frames[0].outgoing)
        do {
            _ = try NetworkHAR.entries(from: Data("{}".utf8))
            assertionFailure("not a HAR")
        } catch {}

        print("network_check: ok")
    }
}
