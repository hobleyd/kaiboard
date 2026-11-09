import SwiftUI

/// The words the keyboard has learned, read from the container it shares
/// with the app, so they can be deleted.
@MainActor
@Observable
final class LearnedDictionary {
    private(set) var words: [String] = []
    private(set) var fixes: [TextEngine.Fix] = []
    /// Whether the keyboard has saved anything to the shared container yet.
    private(set) var isShared = false
    private let engine = TextEngine()

    func reload() {
        let url = TextEngine.Store.shared
        isShared = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        engine.load(from: url)
        sync()
    }

    func delete(words doomed: [String]) {
        doomed.forEach(engine.forget)
        engine.save(to: TextEngine.Store.shared)
        TextEngine.queueForgetting(doomed.map { "W\t\($0)" })
        sync()
    }

    func delete(fixes doomed: [TextEngine.Fix]) {
        for fix in doomed {
            engine.forgetFix(from: fix.from, to: fix.to)
        }
        engine.save(to: TextEngine.Store.shared)
        TextEngine.queueForgetting(doomed.map { "F\t\($0.from)\t\($0.to)" })
        sync()
    }

    private func sync() {
        words = engine.learnedWords
        fixes = engine.learnedFixes
    }
}

struct DictionaryView: View {
    @State private var dictionary = LearnedDictionary()

    var body: some View {
        List {
            if !dictionary.isShared {
                Section {
                    Text("To review the words kAIboard learns, allow it Full Access: Settings → General → Keyboard → Keyboards → kAIboard → Allow Full Access. kAIboard uses it only to share its dictionary with this app; nothing leaves the iPhone.")
                        .font(.callout)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }

            Section {
                if dictionary.words.isEmpty {
                    Text("No words yet").foregroundStyle(.secondary)
                }
                ForEach(dictionary.words, id: \.self) { word in
                    Text(word)
                }
                .onDelete { offsets in
                    dictionary.delete(words: offsets.map { dictionary.words[$0] })
                }
            } header: {
                Text("Words")
            } footer: {
                Text("Words not in the built-in dictionary that you've typed more than once, or kept after undoing a correction. kAIboard stops correcting them.")
            }

            if !dictionary.fixes.isEmpty {
                Section {
                    ForEach(dictionary.fixes, id: \.self) { fix in
                        HStack {
                            Text("\(fix.from) → \(fix.to)")
                            Spacer()
                            Text("\(fix.count)×").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .onDelete { offsets in
                        dictionary.delete(fixes: offsets.map { dictionary.fixes[$0] })
                    }
                } header: {
                    Text("Corrections")
                } footer: {
                    Text("Words you've changed into others, from a selection or a swipe's alternatives. kAIboard offers the replacement first, and after three times applies it as you type.")
                }
            }
        }
        .navigationTitle("Dictionary")
        .toolbar {
            if !dictionary.words.isEmpty || !dictionary.fixes.isEmpty {
                EditButton()
            }
        }
        .onAppear { dictionary.reload() }
    }
}
