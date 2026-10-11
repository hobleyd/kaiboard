import Foundation
import FoundationModels

@Generable
struct WordGuesses {
    @Guide(description: "Three single words, most likely first. No punctuation.", .count(3))
    var words: [String]
}

@Generable
struct NextGuesses {
    @Guide(description: "The unfinished sentence copied exactly, changing only words that are misspelled or are the wrong word (their/there, your/you're, here/hear). Do not add or remove words.")
    var corrected: String
    @Guide(description: "The next few words the person is most likely to type.")
    var continuation: String
    @Guide(description: "Two other single words that could come immediately next instead.", .count(2))
    var alternatives: [String]
}

/// Asks the on-device Apple Intelligence model what the user is likely to mean
/// or type next, given everything before the cursor.
@MainActor
final class Predictor {
    private static let instructions = """
        You are the prediction engine inside a phone keyboard. You are shown text a person is in the \
        middle of writing and you predict words for them. Use the meaning of the whole text, not just \
        the last word, and match its language, tone and spelling conventions. Never reply to the text \
        or comment on it.
        """

    private let model = SystemLanguageModel.default
    private var warm: LanguageModelSession?
    private(set) var lastError: String?
    private(set) var lastLatency: Duration?

    var isAvailable: Bool {
        model.availability == .available
    }

    var statusText: String {
        switch model.availability {
        case .available:
            if let lastError { return "Apple Intelligence error: \(lastError)" }
            if let lastLatency {
                let ms = Int(lastLatency.components.seconds * 1000 + lastLatency.components.attoseconds / 1_000_000_000_000_000)
                return "Apple Intelligence ready · last answer \(ms) ms"
            }
            return "Apple Intelligence ready"
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence model is still downloading"
        case .unavailable:
            return "Apple Intelligence is unavailable"
        }
    }

    // A session accumulates every exchange in its transcript, so each
    // prediction gets a fresh one.
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: Self.instructions)
    }

    /// Loads the model ahead of the first keystroke.
    func prewarm() {
        guard isAvailable, warm == nil else { return }
        let session = makeSession()
        session.prewarm()
        warm = session
    }

    static func worthAsking(_ analysis: Analysis) -> Bool {
        switch analysis.mode {
        case .complete: !analysis.current.contains(where: \.isNumber)
        case .next: !analysis.context.isEmpty
        }
    }

    /// Runs a raw prompt, for trying out wording against the model on a device.
    func probe(_ prompt: String) async -> String {
        do {
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64)
            let response = try await makeSession().respond(to: prompt, generating: WordGuesses.self, options: options)
            return response.content.words.joined(separator: ", ")
        } catch {
            return "error: \(error)"
        }
    }

    /// Proposes words for a gap in the text. Returns nil when cancelled or
    /// when the model can't answer.
    ///
    /// The word being replaced is deliberately not shown to the model: told
    /// what the wrong word is, it tends to answer with synonyms of it.
    func fill(before: String, after: String, hints: [String], excluding: [String] = []) async -> [String]? {
        guard isAvailable else { return nil }
        let session = warm ?? makeSession()
        warm = nil
        // Wording settled by trial on an iPhone: without the worked example
        // the phone's model echoes nouns from the text instead of filling the gap.
        var prompt = """
            A word is missing from this text where the blank is. Example: «I can't find my ____ anywhere, \
            have you seen them?» → keys, glasses, shoes.
            Text: «\(before) ____ \(after)»
            Give three different words that could be the missing one, most likely first. Prefer short, \
            common, everyday words.
            """
        if !hints.isEmpty {
            prompt += " It may be one of: \(hints.joined(separator: ", "))."
        }
        if !excluding.isEmpty {
            prompt += " Do not give any of these: \(excluding.joined(separator: ", "))."
        }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 64)
            let response = try await session.respond(to: prompt, generating: WordGuesses.self, options: options)
            lastLatency = clock.now - start
            lastError = nil
            return response.content.words
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                lastError = String(String(describing: error).prefix(120))
            }
            return nil
        }
    }

    /// Picks which of `candidates` best fits after `context` (and, when
    /// replacing a word mid-sentence, before `following`). Returns nil when
    /// cancelled or when the model can't answer.
    func choose(from candidates: [String], after context: String, before following: String? = nil) async -> String? {
        guard isAvailable, candidates.count > 1 else { return nil }
        let session = warm ?? makeSession()
        warm = nil
        let clock = ContinuousClock()
        let start = clock.now
        do {
            // Constraining the answer to the candidates means it can't wander off the list.
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "NextWord", anyOf: candidates), dependencies: [])
            let list = candidates.joined(separator: ", ")
            let prompt: String
            if let following {
                prompt = "Text: «\(context) ____ \(following)»\nThe blank is one of: \(list). Which one fits the text best?"
            } else {
                let story = context.isEmpty ? "The text is empty so far." : "Text so far: «\(context)»"
                prompt = "\(story)\nThe next word is one of: \(list). Which one fits the text best?"
            }
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24)
            let response = try await session.respond(to: prompt, schema: schema, options: options)
            let choice = try response.content.value(String.self)
            lastLatency = clock.now - start
            lastError = nil
            return candidates.contains(choice) ? choice : nil
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                lastError = String(String(describing: error).prefix(120))
            }
            return nil
        }
    }

    /// Returns nil when cancelled or when the model can't answer.
    func hints(for analysis: Analysis) async -> AIHints? {
        guard isAvailable else { return nil }
        let session = warm ?? makeSession()
        warm = nil
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
        let clock = ContinuousClock()
        let start = clock.now

        do {
            let hints: AIHints
            if analysis.mode == .complete {
                let story = analysis.context.isEmpty ? "The text is empty so far." : "Text so far: «\(analysis.context)»"
                let prompt = """
                    \(story)
                    The person is now typing the next word and has entered the letters "\(analysis.current)". \
                    The letters may be an unfinished word and may contain typos. Give the three words they \
                    most likely intend, judging by the text so far.
                    """
                let response = try await session.respond(to: prompt, generating: WordGuesses.self, options: options)
                hints = AIHints(words: response.content.words, fix: nil)
            } else if analysis.sentence.isEmpty {
                let prompt = "Text so far: «\(analysis.context)»\nGive the three words most likely to begin the next sentence."
                let response = try await session.respond(to: prompt, generating: WordGuesses.self, options: options)
                hints = AIHints(words: response.content.words, fix: nil)
            } else {
                // The model is far better at continuing and proofreading a
                // sentence than at naming "the next word", so ask for that and
                // let the engine pick the words out.
                let earlier = analysis.context.dropLast(analysis.sentence.count).trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = (earlier.isEmpty ? "" : "Earlier text: «\(earlier)»\n") + "Unfinished sentence: «\(analysis.sentence)»"
                let response = try await session.respond(to: prompt, generating: NextGuesses.self, options: options)
                var continuation = response.content.continuation.trimmingCharacters(in: CharacterSet(charactersIn: "«» \n"))
                if continuation.hasPrefix(analysis.sentence) {
                    continuation.removeFirst(analysis.sentence.count)
                }
                hints = AIHints(words: [continuation] + response.content.alternatives, fix: response.content.corrected)
            }
            lastLatency = clock.now - start
            lastError = nil
            return hints
        } catch {
            if !(error is CancellationError), !Task.isCancelled {
                lastError = String(String(describing: error).prefix(120))
            }
            return nil
        }
    }
}
