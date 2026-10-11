import SwiftUI

@MainActor
@Observable
final class Playground {
    var text = "" {
        didSet { suggester.update(before: text) }
    }
    private(set) var suggestions: [Suggestion] = []
    private(set) var thinking = false
    private(set) var status = ""
    private let suggester = Suggester()

    init() {
        suggester.onUpdate = { [weak self] in self?.sync() }
        suggester.predictor.prewarm()
        sync()
    }

    private func sync() {
        suggestions = Array(suggester.analysis.suggestions.prefix(3))
        thinking = suggester.isThinking
        status = suggester.predictor.statusText
    }
}

struct ContentView: View {
    @State private var playground = Playground()
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Turn it on") {
                    Label("Open Settings → General → Keyboard → Keyboards", systemImage: "1.circle")
                    Label("Tap Add New Keyboard… and choose kAIboard", systemImage: "2.circle")
                    Label("In any app, hold the globe key and pick kAIboard", systemImage: "3.circle")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section {
                    TextField("Type here", text: $playground.text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($typing)
                    if playground.suggestions.isEmpty {
                        Text("No suggestions").foregroundStyle(.secondary)
                    } else {
                        HStack {
                            ForEach(Array(playground.suggestions.enumerated()), id: \.offset) { _, suggestion in
                                Label(suggestion.text, systemImage: suggestion.ai ? "sparkle" : "textformat")
                                    .font(.callout)
                                    .fontWeight(suggestion.auto ? .semibold : .regular)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                } header: {
                    Text("Try it")
                } footer: {
                    Text("These are the suggestions kAIboard would show for this text. A sparkle marks ones chosen by Apple Intelligence from the context; bold is what auto-correct would apply.")
                }

                Section("Apple Intelligence") {
                    HStack {
                        Text(playground.status)
                        Spacer()
                        if playground.thinking { ProgressView() }
                    }
                    .font(.callout)
                }

                Section {
                    Text("kAIboard works entirely on this iPhone. It doesn't ask for Full Access and sends nothing over the network. Words you type often are remembered on the device so they stop being corrected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("kAIboard")
            .onAppear {
                // Lets a scripted launch bring the keyboard straight up.
                typing = CommandLine.arguments.contains("--type")
            }
        }
    }
}
