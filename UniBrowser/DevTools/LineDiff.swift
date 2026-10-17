import Foundation

/// A line diff for «Изменения»: unchanged, removed and added lines in reading order.
enum LineDiff {
    enum Kind: Equatable { case same, removed, added }

    static func lines(_ before: String, _ after: String) -> [(kind: Kind, text: String)] {
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [(Kind, String)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                result.append((.removed, old[i])); i += 1
            } else if j < new.count, inserted.contains(j) {
                result.append((.added, new[j])); j += 1
            } else {
                if i < old.count { result.append((.same, old[i])) }
                i += 1; j += 1
            }
        }
        return result
    }
}
