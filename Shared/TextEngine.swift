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
    /// equally well; the others are long shots.
    func swipe(before: String, path: [CGPoint], limit: Int = 3) -> (words: [String], contenders: Int) {
        let flat = path.flatMap { [Float($0.x), Float($0.y)] }
        var contenders: UInt32 = 0
        let words = Self.words(kb_swipe(handle, before, flat, UInt32(path.count), UInt32(limit), &contenders))
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

    // MARK: Persistence

    private static var storeURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("learned.tsv")
    }

    func load() {
        guard let url = Self.storeURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        kb_import(handle, text)
    }

    func save() {
        guard let url = Self.storeURL, let raw = kb_export(handle) else { return }
        defer { kb_string_free(raw) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(cString: raw).write(to: url, atomically: true, encoding: .utf8)
    }
}
