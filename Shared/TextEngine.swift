import Foundation

struct Suggestion: Decodable, Equatable {
    enum Kind: String, Decodable {
        case verbatim, completion, correction, next, fix
    }

    /// What the bar shows.
    let text: String
    /// Text immediately before the cursor that accepting this replaces.
    let replace: String
    let insert: String
    let kind: Kind
    /// Proposed by the language model rather than the built-in lexicon.
    let ai: Bool
    /// Applied automatically when the user ends the word.
    let auto: Bool
}

struct Analysis: Decodable, Equatable {
    enum Mode: String, Decodable {
        case complete, next
    }

    let mode: Mode
    /// The partial word at the cursor.
    let current: String
    /// The preceding text, clipped for the language model.
    let context: String
    /// The unfinished sentence at the end of `context`.
    let sentence: String
    let sentenceStart: Bool
    let suggestions: [Suggestion]

    static let empty = Analysis(mode: .next, current: "", context: "", sentence: "", sentenceStart: true, suggestions: [])
}

/// What the language model proposed for a given piece of text.
struct AIHints: Equatable {
    var words: [String]
    /// The model's proofread copy of `Analysis.sentence`.
    var fix: String?
}

/// Swift face of the Rust engine in `core/`.
final class TextEngine {
    private let handle: OpaquePointer

    init() {
        handle = kb_engine_new()
    }

    deinit {
        kb_engine_free(handle)
    }

    func suggest(before: String, hints: AIHints? = nil, limit: Int = 3) -> Analysis {
        guard let raw = kb_suggest(handle, before, hints?.words.joined(separator: "\n"), hints?.fix, UInt32(limit)) else {
            return .empty
        }
        defer { kb_string_free(raw) }
        let data = Data(bytesNoCopy: raw, count: strlen(raw), deallocator: .none)
        return (try? JSONDecoder().decode(Analysis.self, from: data)) ?? .empty
    }

    /// Decodes a path swiped across the letter keys into candidate words, best
    /// first. Points are in key widths from the left of the top letter row
    /// and rows from its top. The first `contenders` words fit the path nearly
    /// equally well; the others are long shots. A path that starts or ends on
    /// the space bar, between words, says so with `fromSpace` or `toSpace`.
    func swipe(
        before: String, path: [CGPoint], fromSpace: Bool = false, toSpace: Bool = false, limit: Int = 3
    ) -> (words: [String], contenders: Int) {
        let flat = path.flatMap { [Float($0.x), Float($0.y)] }
        let spaces = (fromSpace ? KB_FROM_SPACE : 0) | (toSpace ? KB_TO_SPACE : 0)
        var contenders: UInt32 = 0
        let words = Self.words(kb_swipe(handle, before, flat, UInt32(path.count), spaces, UInt32(limit), &contenders))
        return (words, min(Int(contenders), words.count))
    }

    /// Real words a slip of the thumb away from `word`, most common first.
    func neighbours(of word: String, limit: Int) -> [String] {
        Self.words(kb_neighbours(handle, word, UInt32(limit)))
    }

    /// Tidies words proposed as replacements for `selected`: single words, no
    /// repeats, capitalised like it.
    func replacements(for selected: String, from proposed: [String], limit: Int = 3) -> [String] {
        Self.words(kb_replacements(handle, selected, proposed.joined(separator: "\n"), UInt32(limit)))
    }

    private static func words(_ raw: UnsafeMutablePointer<CChar>?) -> [String] {
        guard let raw else { return [] }
        defer { kb_string_free(raw) }
        let data = Data(bytesNoCopy: raw, count: strlen(raw), deallocator: .none)
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Records the word just completed at the end of `before`.
    func learn(before: String) {
        kb_learn(handle, before)
    }

    /// Marks a word as correctly spelled.
    func learnWord(_ word: String) {
        kb_learn_word(handle, word)
    }

    /// Records that the user changed `from` into `to`.
    func learnFix(from: String, to: String) {
        kb_learn_fix(handle, from, to)
    }

    /// Forgets that the user changed `from` into `to`.
    func forgetFix(from: String, to: String) {
        kb_forget_fix(handle, from, to)
    }

    /// Words the user has changed `word` into, most often first.
    func preferred(for word: String) -> [String] {
        Self.words(kb_preferred(handle, word))
    }

    // MARK: Dictionary

    struct Fix: Decodable, Hashable {
        let from: String
        let to: String
        let count: Int
    }

    /// Words learned from the user that are treated as correctly spelled.
    var learnedWords: [String] {
        Self.words(kb_learned_words(handle))
    }

    /// Words the user keeps changing into others.
    var learnedFixes: [Fix] {
        guard let raw = kb_learned_fixes(handle) else { return [] }
        defer { kb_string_free(raw) }
        let data = Data(bytesNoCopy: raw, count: strlen(raw), deallocator: .none)
        return (try? JSONDecoder().decode([Fix].self, from: data)) ?? []
    }

    /// Forgets everything learned about `word`.
    func forget(_ word: String) {
        kb_forget(handle, word)
    }

    // MARK: Persistence

    /// Where learned words are kept. The keyboard can only write to the
    /// container it shares with the app when it has Full Access; without it,
    /// it keeps them in its own.
    enum Store {
        static let group = "group.au.com.sharpblue.kaiboard"

        static var shared: URL? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
                .appendingPathComponent("learned.tsv")
        }

        static var local: URL? {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("learned.tsv")
        }

        /// Words deleted in the app, one record per line ("W\tword" or
        /// "F\tfrom\tto"), for a running keyboard to forget too: it would
        /// otherwise write them back from memory the next time it saves.
        static var forgotten: URL? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
                .appendingPathComponent("forgotten.tsv")
        }

        /// Left by the keyboard whenever it opens with Full Access, so the app,
        /// which can't ask, knows it has been allowed. It can't be removed when
        /// Full Access is taken away again, since that also takes the container.
        static var fullAccess: URL? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
                .appendingPathComponent("full-access")
        }

        static var hasFullAccess: Bool {
            fullAccess.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    func load(from url: URL?) {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        kb_import(handle, text)
    }

    func save(to url: URL?) {
        guard let url, let raw = kb_export(handle) else { return }
        defer { kb_string_free(raw) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(cString: raw).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Asks a running keyboard to forget `records` (see `Store.forgotten`).
    static func queueForgetting(_ records: [String]) {
        guard let url = Store.forgotten, !records.isEmpty else { return }
        let earlier = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (earlier + records.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Forgets whatever the app has deleted since this was last called.
    func applyForgetting() {
        guard let url = Store.forgotten, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "W" where fields.count == 2: forget(fields[1])
            case "F" where fields.count == 3: forgetFix(from: fields[1], to: fields[2])
            default: break
            }
        }
    }
}
