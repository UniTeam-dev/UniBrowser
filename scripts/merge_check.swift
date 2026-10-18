// Self-check for Shared/ViaMac/SessionMerge.swift:
//   swiftc -parse-as-library UniBrowser/Models/Space.swift UniBrowser/Models/SessionSnapshot.swift Shared/ViaMac/SessionMerge.swift scripts/merge_check.swift -o /tmp/merge_check && /tmp/merge_check
import Foundation

@main
enum MergeCheck {
    nonisolated(unsafe) static var failed = false

    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failed = true }
    }

    static func tab(_ id: UUID, _ title: String) -> SessionSnapshot.TabRecord {
        .init(id: id, url: URL(string: "https://\(title).example"), title: title, lastActivated: .distantPast)
    }

    static func snapshot(_ spaces: [Space], _ tabs: [SessionSnapshot.TabRecord], at time: Date?,
                         archive: [ArchivedTab]? = nil) -> SessionSnapshot {
        .init(spaces: spaces, activeSpaceID: spaces[0].id, tabs: tabs, archive: archive, modifiedAt: time)
    }

    static func space(_ s: SessionSnapshot, _ id: UUID) -> Space? { s.spaces.first { $0.id == id } }

    static func main() {
        let t1 = UUID(), t2 = UUID(), t3 = UUID(), t4 = UUID(), t5 = UUID()
        let g = TabGroup(name: "G", tabIDs: [t1])
        let main = Space(name: "Main", colorHex: "#2563C9", groups: [g], looseTabIDs: [t2])
        let base = snapshot([main], [tab(t1, "one"), tab(t2, "two")], at: Date(timeIntervalSince1970: 0))

        // Newer side (Mac): closed t2, renamed t1.
        var newerSpace = main
        newerSpace.looseTabIDs = []
        let newer = snapshot([newerSpace], [tab(t1, "new")], at: Date(timeIntervalSince1970: 200))

        // Older side (phone, offline): opened t3 in G and t4 loose, made group G2 with new t5 and t1 moved in.
        var olderSpace = main
        olderSpace.groups[0].tabIDs = [t3]
        olderSpace.groups.append(TabGroup(name: "G2", tabIDs: [t5, t1]))
        olderSpace.looseTabIDs = [t2, t4]
        let older = snapshot([olderSpace], [tab(t1, "old"), tab(t2, "two"), tab(t3, "three"), tab(t4, "four"), tab(t5, "five")],
                             at: Date(timeIntervalSince1970: 100))

        for (label, m) in [("older,newer", SessionSnapshot.merged(older, newer, base: base)),
                           ("newer,older", SessionSnapshot.merged(newer, older, base: base))] {
            let s = space(m, main.id)
            let ids = Set(m.tabs.map(\.id))
            let gTabs = s?.groups.first { $0.id == g.id }?.tabIDs ?? []
            check("(a) offline tabs kept in place [\(label)]",
                  ids.isSuperset(of: [t3, t4]) && gTabs.contains(t3) && s?.looseTabIDs.contains(t4) == true)
            check("(b) tab closed on newer side stays closed [\(label)]",
                  !ids.contains(t2) && s?.allTabIDs.contains(t2) == false)
            check("(c) newer side's title/url win [\(label)]",
                  m.tabs.first { $0.id == t1 }.map { $0.title == "new" && $0.url == URL(string: "https://new.example") } == true)
            let g2 = s?.groups.first { $0.name == "G2" }
            check("(e) new group added with only its new tabs [\(label)]",
                  g2?.tabIDs == [t5] && gTabs.contains(t1) && ids.contains(t5))
        }

        // (d) First sync: Mac wins, phone's tabs go loose into the same-named space, else the first.
        let m1 = UUID(), m2 = UUID(), p1 = UUID(), p2 = UUID()
        let work = Space(name: "Work", colorHex: "#E8833A", groups: [TabGroup(name: "W", tabIDs: [m1])])
        let macMain = Space(name: "Main", colorHex: "#2563C9", looseTabIDs: [m2])
        let mac = snapshot([work, macMain], [tab(m1, "m1"), tab(m2, "m2")], at: Date())
        let phone = snapshot([Space(name: "Main", colorHex: "#2563C9", looseTabIDs: [p1]),
                              Space(name: "Other", colorHex: "#2E9E5B", looseTabIDs: [p2])],
                             [tab(p1, "p1"), tab(p2, "p2")], at: .distantPast)
        let d = SessionSnapshot.merged(phone, mac, base: nil)
        check("(d) first sync keeps Mac spaces/groups, phone tabs land loose",
              d.spaces.map(\.id) == [work.id, macMain.id]
                && space(d, work.id)?.groups.map(\.tabIDs) == [[m1]]
                && space(d, macMain.id)?.looseTabIDs == [m2, p1]
                && space(d, work.id)?.looseTabIDs == [p2]
                && Set(d.tabs.map(\.id)) == [m1, m2, p1, p2])

        // (f) Archive is the union.
        let a1 = ArchivedTab(title: "a1", archivedAt: Date(timeIntervalSince1970: 10))
        let a2 = ArchivedTab(title: "a2", archivedAt: Date(timeIntervalSince1970: 20))
        var na = newer; na.archive = [a1]
        var oa = older; oa.archive = [a2, a1]
        let f = SessionSnapshot.merged(oa, na, base: base)
        check("(f) archive is the union", f.archive?.map(\.id) == [a2.id, a1.id])

        // (g) Pictures stripped from a live frame come back from the last full one.
        var pictured = work; pictured.imageData = Data([1, 2, 3])
        let withPicture = snapshot([pictured, macMain], [tab(m1, "m1"), tab(m2, "m2")], at: Date())
        let stripped = withPicture.withoutImages()
        check("(g) pictures strip and restore by space id",
              stripped.spaces.allSatisfy { $0.imageData == nil }
                && withPicture.spaceImages == [work.id: Data([1, 2, 3])]
                && stripped.withImages(withPicture.spaceImages).spaces == withPicture.spaces)

        // (h) «Отдельные входы» travels with the space: the later side's value wins, absent stays absent.
        var separate = work; separate.separateLogins = false
        var oldWork = work; oldWork.separateLogins = nil
        let h = SessionSnapshot.merged(snapshot([oldWork], [tab(m1, "m1")], at: .distantPast),
                                       snapshot([separate], [tab(m1, "m1")], at: Date()), base: nil)
        let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(h))
        check("(h) separateLogins travels through merge and the wire",
              space(h, work.id)?.separateLogins == false && decoded.flatMap { space($0, work.id)?.separateLogins } == false)

        exit(failed ? 1 : 0)
    }
}
