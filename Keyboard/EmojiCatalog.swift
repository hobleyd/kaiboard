import Foundation

/// Every emoji the keyboard offers, the words each is looked up by, and the
/// ones used lately.
final class EmojiCatalog {
    struct Entry {
        let emoji: String
        /// The words of its name, lowercased.
        let name: [String]
        /// Those and its other keywords.
        let words: [String]
    }

    struct Group {
        let name: String
        let entries: [Entry]
    }

    private static let recentsKey = "recentEmoji"
    private static let maxRecents = 32

    let groups: [Group]
    private(set) var recents: [String]

    init() {
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        groups = Self.load()
    }

    /// Reads `emoji.txt`, which `tools/gen_emoji.swift` writes.
    private static func load() -> [Group] {
        guard let url = Bundle(for: EmojiCatalog.self).url(forResource: "emoji", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        var groups: [Group] = []
        var name: String?
        var entries: [Entry] = []
        func close() {
            if let name {
                groups.append(Group(name: name, entries: entries))
            }
            entries = []
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# ") {
                close()
                name = String(line.dropFirst(2))
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let named = words(in: fields[1])
            var all = named
            for word in words(in: fields[2]) where !all.contains(word) {
                all.append(word)
            }
            entries.append(Entry(emoji: String(fields[0]), name: named, words: all))
        }
        close()
        return groups
    }

    private static func words(in text: some StringProtocol) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Moves `emoji` to the front of the recents.
    func use(_ emoji: String) {
        recents.removeAll { $0 == emoji }
        recents.insert(emoji, at: 0)
        recents = Array(recents.prefix(Self.maxRecents))
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    /// Emoji for a typed query, best first: every word of the query must begin
    /// a different word the emoji is known by. Those it is named for come
    /// before those that only list it as a keyword, whole-word matches before
    /// partial ones, and short names before long: "fire" is 🔥 before 🚒.
    func search(_ query: String, limit: Int = 48) -> [String] {
        let wanted = Self.words(in: query)
        guard !wanted.isEmpty else { return recents }
        /// Whether the query fits `words`, and if so whether it does so with whole words.
        func fit(_ words: [String]) -> Bool? {
            var free = words
            var whole = true
            for want in wanted {
                guard let index = free.firstIndex(of: want) ?? free.firstIndex(where: { $0.hasPrefix(want) }) else { return nil }
                whole = whole && free[index] == want
                free.remove(at: index)
            }
            return whole
        }
        var found: [(rank: Int, emoji: String)] = []
        for entry in groups.flatMap(\.entries) {
            if let whole = fit(entry.name) {
                found.append(((whole ? 0 : 10) + min(entry.name.count, 9), entry.emoji))
            } else if let whole = fit(entry.words) {
                found.append((whole ? 20 : 21, entry.emoji))
            }
        }
        // The sort is stable in practice only if told how to break ties: keep the catalog's order.
        return found.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .prefix(limit).map(\.element.emoji)
    }
}
