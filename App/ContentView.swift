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
    @Environment(\.scenePhase) private var scenePhase
    @State private var fullAccess = TextEngine.Store.hasFullAccess
    @State private var askingForFullAccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Turn it on") {
                    Label("Open Settings → General → Keyboard → Keyboards", systemImage: "1.circle")
                    Label("Tap Add New Keyboard… and choose kAIboard", systemImage: "2.circle")
                    Label("In any app, hold the globe key and pick kAIboard", systemImage: "3.circle")
                    Button("Open Settings", action: openSettings)
                }

                if !fullAccess {
                    Section {
                        Label("In Settings → kAIboard → Keyboards → kAIboard, turn on Allow Full Access", systemImage: "lock.open")
                        Button("Open kAIboard Settings", action: openSettings)
                    } header: {
                        Text("Allow Full Access")
                    } footer: {
                        Text("Full Access lets kAIboard share the words it learns with this app, so you can review them. Once it's on, use kAIboard once, here or anywhere, and this goes away.")
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

                Section {
                    NavigationLink("Review Dictionary") {
                        DictionaryView()
                    }
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
                    Text("kAIboard works entirely on this iPhone and sends nothing over the network. Words you type often are remembered on the device so they stop being corrected. Full Access is used only to share those words with this app so you can review them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("kAIboard")
            .onAppear {
                // Lets a scripted launch bring the keyboard straight up.
                typing = CommandLine.arguments.contains("--type")
                let scripted = ["--type", "--selftest", "--ask"].contains { CommandLine.arguments.contains($0) }
                askingForFullAccess = !fullAccess && !scripted
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { fullAccess = TextEngine.Store.hasFullAccess }
            }
            // The keyboard leaves its marker as it comes up, so trying it here
            // after allowing Full Access is enough to notice.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                fullAccess = TextEngine.Store.hasFullAccess
            }
            .alert("Allow Full Access", isPresented: $askingForFullAccess) {
                Button("Open Settings", action: openSettings)
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("kAIboard needs Full Access to share the words it learns with this app. In Settings, tap Keyboards → kAIboard and turn on Allow Full Access. If kAIboard isn't listed there yet, add it first under General → Keyboard → Keyboards.")
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
