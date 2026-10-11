import SwiftUI

@main
struct KaiboardApp: App {
    init() {
        // `--selftest` runs the suggestion pipeline once and prints the result,
        // so the build can be checked from the command line.
        // `--ask <prompt>` (repeatable) sends raw prompts to the on-device model.
        let asks = zip(CommandLine.arguments, CommandLine.arguments.dropFirst()).filter { $0.0 == "--ask" }.map(\.1)
        if !asks.isEmpty {
            Task { @MainActor in
                let predictor = Predictor()
                for ask in asks {
                    print("ASK \(await predictor.probe(ask.replacingOccurrences(of: "\\n", with: "\n")))")
                }
                exit(0)
            }
        } else if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in
                await SelfTest.run()
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@MainActor
enum SelfTest {
    static let samples = [
        "I'll see you tomor",
        "Can you pick up some milk on your way ",
        "I left my keys over their ",
        "The weather is beutiful",
        "We need to book a flight to Par",
    ]

    static func run() async {
        let engine = TextEngine()
        let predictor = Predictor()
        print("SELFTEST status: \(predictor.statusText)")
        predictor.prewarm()
        for sample in samples {
            let local = engine.suggest(before: sample)
            let hints = await predictor.hints(for: local)
            let merged = engine.suggest(before: sample, hints: hints)
            print("SELFTEST \"\(sample)\"")
            print("  local: \(local.suggestions.map(\.text))")
            print("  model: \(hints.map { "\($0.words) fix=\($0.fix ?? "")" } ?? "none")")
            print("  bar:   \(merged.suggestions.map { $0.text + ($0.auto ? "*" : "") })")
            print("  \(predictor.statusText)")
        }
        let readings = ["duvet", "Robert", "river", "rubber", "rivet", "runner", "rider", "rudder"]
        let choice = await predictor.choose(from: readings, after: "We walk down by the")
        print("SELFTEST swipe after \"We walk down by the\": \(choice ?? "none") from \(readings)")
        print("  \(predictor.statusText)")
        let lead = "I've just built an iOS keyboard that uses Apple Intelligence to try to predict the"
        for tail in ["you meant to type...", ""] {
            let filled = await predictor.fill(before: lead, after: tail, hints: [])
            print("SELFTEST blank before \"\(tail)\": \(filled ?? [])")
        }
        print("SELFTEST done")
    }
}
