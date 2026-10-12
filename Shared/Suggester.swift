import Foundation

/// Produces the suggestion bar for the text before the cursor: instantly from
/// the Rust engine, then again once Apple Intelligence has weighed in.
@MainActor
final class Suggester {
    let engine = TextEngine()
    let predictor = Predictor()

    /// Called whenever `analysis` or `isThinking` changes.
    var onUpdate: (() -> Void)?
    private(set) var analysis = Analysis.empty
    private(set) var before: String?
    private(set) var isThinking = false

    /// More than fit in the bar at once; the rest are reached by scrolling it.
    private static let limit = 8

    private var cache: [String: AIHints] = [:]
    private var pending: Task<Void, Never>?

    /// Makes the next `update` recompute even if the text hasn't changed.
    func invalidate() {
        before = nil
    }

    /// Abandons the request in flight, if any. The next `update` starts over.
    func pause() {
        guard pending != nil else { return }
        pending?.cancel()
        pending = nil
        before = nil
        isThinking = false
        onUpdate?()
    }

    /// `patience` overrides how long to wait for the user to stop before asking Apple Intelligence.
    func update(before: String, useAI: Bool = true, patience: Duration? = nil) {
        guard before != self.before else { return }
        self.before = before
        pending?.cancel()
        pending = nil

        let hints = cache[before]
        analysis = engine.suggest(before: before, hints: hints, limit: Self.limit)
        isThinking = useAI && hints == nil && predictor.isAvailable && Predictor.worthAsking(analysis)
        onUpdate?()
        guard isThinking else { return }

        let snapshot = analysis
        // Wait for a pause in typing; mid-word keystrokes arrive in bursts.
        let pause = patience ?? (snapshot.mode == .next ? .milliseconds(40) : .milliseconds(160))
        pending = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self else { return }
            let hints = await self.predictor.hints(for: snapshot)
            guard !Task.isCancelled, self.before == before else { return }
            if let hints {
                if self.cache.count > 200 { self.cache.removeAll() }
                self.cache[before] = hints
                self.analysis = self.engine.suggest(before: before, hints: hints, limit: Self.limit)
            }
            self.isThinking = false
            self.pending = nil
            self.onUpdate?()
        }
    }
}
