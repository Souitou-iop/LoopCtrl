import Foundation

/// Which app a name means, for `launch_app{name}`: the one app that matches,
/// or the candidates when several do (never a guess).
///
/// Levels, tried in order: the whole name ("Settings"), words that start the
/// app's words in order ("idol ludo" → "Idol Ludo Board"), initials ("ilb"),
/// then a part of the name ("微信" in "微信读书" — only if nothing closer
/// matched). Case and spaces never count. Pools are tried in order too: apps
/// known to be on the phone before the built-in catalog.
enum AppNameMatch {
    struct App: Equatable {
        let bundleId: String
        let name: String
        let from: String
    }

    enum Result: Equatable {
        case one(App, how: String)
        case several([App])
        case none
    }

    static func squash(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    /// Lower-cased words of a name, split on spaces and punctuation.
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation || $0.isSymbol }).map(String.init)
    }

    static func best(_ query: String, pools: [[App]]) -> Result {
        let q = squash(query)
        let qWords = words(query)
        guard !q.isEmpty else { return .none }
        let levels: [(String, (String) -> Bool)] = [
            ("exact", { squash($0) == q }),
            ("words", { name in
                let n = words(name)
                guard !qWords.isEmpty else { return false }
                var i = 0
                for w in qWords {
                    while i < n.count, !n[i].hasPrefix(w) { i += 1 }
                    if i == n.count { return false }
                    i += 1
                }
                return true
            }),
            ("initials", { name in
                let n = words(name)
                return q.count >= 2 && n.count >= 2 && n.compactMap(\.first).map(String.init).joined() == q
            }),
            ("contains", { q.count >= 2 && squash($0).contains(q) }),
        ]
        for pool in pools {
            for (how, matches) in levels {
                let hits = pool.filter { matches($0.name) }
                if hits.count == 1 { return .one(hits[0], how: how) }
                if hits.count > 1 { return .several(Array(hits.prefix(8))) }
            }
        }
        return .none
    }
}
