import UIKit

private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private let suggester = Suggester()
    private let bar = SuggestionBar()
    private let keys = KeyboardView()
    private let catalog = EmojiCatalog()
    private lazy var emoji = EmojiView(catalog: catalog)
    private let search = EmojiSearchBar()

    /// What is standing in for the suggestions and the keys.
    private enum Panel {
        case typing
        /// The emoji picker, under a search field.
        case emoji
        /// The keys again, typing into the search field.
        case emojiSearch
    }
    private var panel = Panel.typing
    /// What has been typed into the emoji search field, while it is in use.
    private var emojiQuery: String?
    /// The last thing done in the search was to pick an emoji, so backspace
    /// should take that back rather than eat into the query.
    private var justPickedEmoji = false
    private var heightConstraint: NSLayoutConstraint?

    private var shift = ShiftState.off {
        didSet { keys.shift = shift }
    }
    private var lastShiftTap = Date.distantPast

    /// An auto-correction that the next backspace should take back.
    private struct Undo {
        let original: String
        let corrected: String
        var trailing = ""
    }
    private var undo: Undo?
    /// The word just entered by swiping, with its trailing space, and the
    /// decoder's other readings of the same swipe.
    private struct Swiped {
        let id = UUID()
        var text: String
        var alternatives: [String]
    }
    private var swiped: Swiped?
    private var swipeChoice: Task<Void, Never>?
    /// Every reading of recent swipes, keyed by each of those readings in
    /// lowercase, so a wrongly decoded word can be swapped for a sibling later.
    private var swipeReadings: [String: [String]] = [:]

    /// A single word the user has selected in the document, and what could replace it.
    private struct Selection {
        let word: String
        let before: String
        let after: String
        var options: [String] = []
        /// Options Apple Intelligence came up with, lowercased; the rest are near spellings.
        var fromAI: Set<String> = []
        var isThinking = true
        /// How many times Review has been used on this selection.
        var reviews = 0
    }
    private static let selectionOptions = 12
    private var selection: Selection?
    private var selectionTask: Task<Void, Never>?
    /// How many readings of a swipe Apple Intelligence gets to choose between.
    private static let swipeCandidates = 8
    /// How long after a swipe to wait before asking for next-word suggestions:
    /// long enough that swiping straight on to the next word gets in first.
    private static let swipePatience = Duration.milliseconds(350)
    /// The space before the cursor was added by accepting a suggestion, so
    /// punctuation typed next should hug the word.
    private var spaceIsAutomatic = false
    private var lastKeyWasSpace = false

    private static let wordEnders: Set<String> = [".", ",", "!", "?", ";", ":", ")", "\""]
    /// Punctuation that belongs tight against the word before it. Hyphens,
    /// opening brackets and quotes legitimately follow a space, so they are left alone.
    private static let huggers: Set<String> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "%"]

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
        root.allowsSelfSizing = true
        inputView = root

        for subview in [bar, search, keys, emoji] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        emoji.isHidden = true
        search.isHidden = true
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 38),
            keys.topAnchor.constraint(equalTo: bar.bottomAnchor),
            keys.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            keys.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            search.topAnchor.constraint(equalTo: bar.topAnchor),
            search.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            search.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            emoji.topAnchor.constraint(equalTo: keys.topAnchor),
            emoji.leadingAnchor.constraint(equalTo: keys.leadingAnchor),
            emoji.trailingAnchor.constraint(equalTo: keys.trailingAnchor),
            emoji.bottomAnchor.constraint(equalTo: keys.bottomAnchor),
        ])
        let height = root.heightAnchor.constraint(equalToConstant: 262)
        height.priority = .init(999)
        height.isActive = true
        heightConstraint = height

        keys.onKey = { [weak self] key in self?.handle(key) }
        keys.onSwipe = { [weak self] path in self?.handleSwipe(path) }
        // Suggestions for the text as it stood are stale once the next word is
        // under way, and generating them competes with tracking the finger.
        keys.onTouchDown = { [weak self] in self?.suggester.pause() }
        emoji.onKey = { [weak self] key in self?.handle(key) }
        emoji.onEmoji = { [weak self] text in self?.insertEmoji(text) }
        search.onEmoji = { [weak self] text in self?.insertEmoji(text) }
        search.onBegin = { [weak self] in self?.show(.emojiSearch) }
        search.onCancel = { [weak self] in self?.show(.emoji) }
        keys.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(self.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        bar.onSelect = { [weak self] suggestion in self?.accept(suggestion) }
        bar.onReview = { [weak self] in self?.reviewSelection() }
        bar.statusText = { [weak self] in
            guard let self else { return "" }
            var text = self.suggester.predictor.statusText
            if let problem = self.keys.lastProblem {
                text += "\n\(problem.text), \(Int(-problem.at.timeIntervalSinceNow)) s ago"
            }
            return text
        }
        suggester.onUpdate = { [weak self] in self?.render() }
        suggester.engine.load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        suggester.predictor.prewarm()
        keys.showsGlobe = needsInputModeSwitchKey
        show(.typing)
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        suggester.engine.save()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let landscape = traitCollection.verticalSizeClass == .compact
        heightConstraint?.constant = landscape ? 198 : 262
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refresh()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Changing the bottom row rebuilds the keys, which would drop a swipe in progress.
        if !keys.isTouched {
            keys.showsGlobe = needsInputModeSwitchKey
        }
        refresh()
    }

    // MARK: Field traits

    private var before: String {
        textDocumentProxy.documentContextBeforeInput ?? ""
    }

    /// Fields like URLs and e-mail addresses want literal typing.
    private var isProse: Bool {
        switch textDocumentProxy.keyboardType ?? .default {
        case .URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad:
            false
        default:
            true
        }
    }

    private var autocorrects: Bool {
        isProse && textDocumentProxy.autocorrectionType != .no
    }

    private var returnTitle: String {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: "go"
        case .search, .google, .yahoo: "search"
        case .send: "send"
        case .done: "done"
        case .next, .continue: "next"
        case .join: "join"
        case .route: "route"
        default: "return"
        }
    }

    // MARK: State

    /// Re-reads the document and updates suggestions, and optionally shift.
    private func refresh(updateShift: Bool = true, useAI: Bool = true, patience: Duration? = nil) {
        updateSelection()
        suggester.update(before: before, useAI: isProse && useAI && selection == nil && !keys.isTouched, patience: patience)
        keys.returnTitle = returnTitle
        keys.allowsSwipe = isProse && emojiQuery == nil
        if updateShift, shift != .locked, emojiQuery == nil {
            let analysis = suggester.analysis
            let capitalise = switch textDocumentProxy.autocapitalizationType ?? .sentences {
            case .none: false
            case .allCharacters: true
            case .words: analysis.current.isEmpty
            case .sentences: analysis.current.isEmpty && analysis.sentenceStart
            @unknown default: false
            }
            shift = capitalise && isProse ? .on : .off
        }
        render()
    }

    /// The selected word, if exactly one word is selected in a prose field.
    private var selectedWord: String? {
        guard isProse, let text = textDocumentProxy.selectedText?.trimmingCharacters(in: .whitespaces),
              (1...24).contains(text.count), text.contains(where: \.isLetter),
              text.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
        else { return nil }
        return text
    }

    /// Starts looking for replacements when the user selects a word, using the
    /// text on both sides of it.
    private func updateSelection() {
        guard let word = selectedWord else {
            selectionTask?.cancel()
            selection = nil
            return
        }
        let engine = suggester.engine
        let predictor = suggester.predictor
        let before = engine.suggest(before: self.before).context
        let rest = (textDocumentProxy.documentContextAfterInput ?? "").prefix { !$0.isNewline }
        let after = String(rest.prefix(160)).trimmingCharacters(in: .whitespaces)
        if let selection, selection.word == word, selection.before == before, selection.after == after { return }

        selectionTask?.cancel()
        let siblings = (swipeReadings[word.lowercased()] ?? []).filter { $0.lowercased() != word.lowercased() }
        // Words the selection could be a slip for: other readings of the swipe that produced it, then near spellings.
        let near = engine.replacements(for: word, from: siblings + engine.neighbours(of: word, limit: 6), limit: 8)
        selection = Selection(word: word, before: before, after: after, options: near, isThinking: predictor.isAvailable)
        guard predictor.isAvailable else { return }

        selectionTask = Task { [weak self] in
            let filled = await predictor.fill(before: before, after: after, hints: siblings)
            guard !Task.isCancelled, let self, self.selection?.word == word else { return }
            var options = engine.replacements(for: word, from: filled ?? [])
            self.selection?.fromAI.formUnion(options.map { $0.lowercased() })
            self.selection?.options = engine.replacements(for: word, from: options + near, limit: Self.selectionOptions)
            self.render()

            // Give one slot to whichever near-miss fits the sentence best.
            let pick = near.count > 1 ? await predictor.choose(from: near, after: before, before: after) : near.first
            guard !Task.isCancelled, self.selection?.word == word else { return }
            if let pick, !options.prefix(2).contains(pick) {
                options.insert(pick, at: min(1, options.count))
                self.selection?.fromAI.insert(pick.lowercased())
            }
            self.selection?.options = engine.replacements(for: word, from: options + near, limit: Self.selectionOptions)
            self.selection?.isThinking = false
            self.render()
        }
    }

    /// Asks for further replacements for the selected word, beyond those already offered.
    private func reviewSelection() {
        guard let current = selection, !current.isThinking else { return }
        UIDevice.current.playInputClick()
        let engine = suggester.engine
        let predictor = suggester.predictor
        let round = current.reviews + 1
        selection?.reviews = round
        selection?.isThinking = predictor.isAvailable
        render()

        selectionTask = Task { [weak self] in
            let fresh = await predictor.fill(
                before: current.before, after: current.after, hints: [], excluding: current.options + [current.word])
            guard !Task.isCancelled, let self, self.selection?.word == current.word else { return }
            self.selection?.fromAI.formUnion((fresh ?? []).map { $0.lowercased() })
            // Each round also casts the net for near spellings a little wider.
            let wider = engine.neighbours(of: current.word, limit: 6 + 4 * round)
            self.selection?.options = engine.replacements(
                for: current.word, from: current.options + (fresh ?? []) + wider, limit: Self.selectionOptions * (round + 1))
            self.selection?.isThinking = false
            self.render()
        }
    }

    /// `word` capitalised as the shift key asks.
    private static func cased(_ word: String, for shift: ShiftState) -> String {
        switch shift {
        case .off: word
        case .on: word.prefix(1).uppercased() + word.dropFirst()
        case .locked: word.uppercased()
        }
    }

    private func render() {
        let predictor = suggester.predictor
        if let selection {
            // Shift is up where the selection starts a sentence.
            let options = selection.options.map { option in
                let text = Self.cased(option, for: shift)
                let ai = selection.fromAI.contains(option.lowercased())
                return Suggestion(text: text, replace: "", insert: text, kind: .fix, ai: ai, auto: false)
            }
            bar.show(options, highlightAuto: false, ai: selection.isThinking ? .thinking : .idle, offersReview: true)
            return
        }
        let ai: SuggestionBar.AIState = !predictor.isAvailable ? .unavailable : suggester.isThinking ? .thinking : .idle
        var suggestions = isProse ? suggester.analysis.suggestions : []
        if let swiped, before.hasSuffix(swiped.text) {
            // Lead with the other words the swipe could have meant.
            let others = swiped.alternatives.map {
                Suggestion(text: $0, replace: swiped.text, insert: $0 + " ", kind: .fix, ai: false, auto: false)
            }
            suggestions = others + suggestions.filter { $0.kind != .fix }
        }
        bar.show(suggestions, highlightAuto: autocorrects, ai: ai)
    }

    // MARK: Editing

    private func replace(_ old: String, with new: String) {
        guard before.hasSuffix(old) else { return }
        for _ in old {
            textDocumentProxy.deleteBackward()
        }
        if !new.isEmpty {
            textDocumentProxy.insertText(new)
        }
    }

    /// Forgets the pending swipe, recording its word as typed if it is still there.
    private func settleSwipe() {
        swipeChoice?.cancel()
        swipeChoice = nil
        if let swiped, before.hasSuffix(swiped.text) {
            suggester.engine.learn(before: before)
        }
        swiped = nil
    }

    private func handleSwipe(_ path: [CGPoint]) {
        UIDevice.current.playInputClick()
        undo = nil
        settleSwipe()
        lastKeyWasSpace = false
        let (words, contenders) = suggester.engine.swipe(before: before, path: path, limit: Self.swipeCandidates)
        guard let best = words.first else {
            keys.lastProblem = ("swipe of \(path.count) points matched no word", Date())
            return
        }

        // A swipe is a whole word: finish whatever was being typed first.
        if let last = before.last, !last.isWhitespace, !"([{\"'“‘-/".contains(last) {
            autocorrect()
            undo = nil
            textDocumentProxy.insertText(" ")
        }
        let cased: (String) -> String = { [shift] word in Self.cased(word, for: shift) }
        let context = suggester.engine.suggest(before: before).context
        let text = cased(best) + " "
        textDocumentProxy.insertText(text)
        spaceIsAutomatic = true
        let entry = Swiped(text: text, alternatives: words.dropFirst().map(cased))
        swiped = entry
        if swipeReadings.count > 200 { swipeReadings.removeAll() }
        for word in words {
            swipeReadings[word.lowercased()] = words
        }

        // The shape of a swipe often fits several words equally well. Enter
        // the closest match now, then let Apple Intelligence overrule it from
        // the meaning of the sentence, unless the user has moved on by then.
        // It only gets the words the shape can't tell apart: offered the long
        // shots too, it picks them over a clear winner.
        let predictor = suggester.predictor
        let close = Array(words.prefix(contenders))
        guard predictor.isAvailable, close.count > 1 else {
            refresh(patience: Self.swipePatience)
            return
        }
        refresh(useAI: false)
        swipeChoice = Task { [weak self] in
            let choice = await predictor.choose(from: close, after: context)
            guard !Task.isCancelled, let self, var current = self.swiped, current.id == entry.id else { return }
            if let choice, choice != best, self.before.hasSuffix(current.text) {
                let chosen = cased(choice) + " "
                self.replace(current.text, with: chosen)
                current.alternatives = [cased(best)] + current.alternatives.filter { $0 != cased(choice) }
                current.text = chosen
                self.swiped = current
            }
            // Next-word suggestions were held back so the two requests didn't compete.
            self.suggester.invalidate()
            self.refresh(patience: Self.swipePatience)
        }
    }

    /// Swaps the word at the cursor for its auto-correction, if it has one.
    private func autocorrect() {
        guard autocorrects else { return }
        suggester.update(before: before, useAI: false)
        let analysis = suggester.analysis
        guard analysis.mode == .complete, let fix = analysis.suggestions.first(where: \.auto) else { return }
        replace(fix.replace, with: fix.insert)
        undo = Undo(original: fix.replace, corrected: fix.insert)
    }

    private func handle(_ key: Key) {
        UIDevice.current.playInputClick()
        if typeQuery(key) { return }
        let pendingUndo = undo
        let pendingSwipe = swiped
        if key == .backspace {
            swipeChoice?.cancel()
            swiped = nil
        } else {
            settleSwipe()
        }
        let wasSpace = lastKeyWasSpace
        let automaticSpace = spaceIsAutomatic
        undo = nil
        lastKeyWasSpace = false
        spaceIsAutomatic = false

        switch key {
        case .character(let raw):
            let text = shift == .off ? raw : raw.uppercased()
            let endsWord = Self.wordEnders.contains(text)
            let context = before
            let spaces = context.reversed().prefix { $0 == " " }.count
            let followsWord = context.dropLast(spaces).last.map { !$0.isWhitespace } ?? false
            if isProse, Self.huggers.contains(text), spaces > 0, followsWord {
                // "word ." becomes "word.", however the spaces got there.
                for _ in 0..<spaces {
                    textDocumentProxy.deleteBackward()
                }
            } else if endsWord {
                autocorrect()
            }
            textDocumentProxy.insertText(text)
            if endsWord {
                undo?.trailing = text
                suggester.engine.learn(before: before)
            }
            if text == "'" {
                keys.page = .letters
            }

        case .space:
            let text = before
            let previous = text.dropLast().last
            if automaticSpace, text.hasSuffix(" ") {
                // The space is already there; this press just confirms it.
                lastKeyWasSpace = true
            } else if wasSpace, text.hasSuffix(" "), let previous, previous.isLetter || previous.isNumber, isProse {
                textDocumentProxy.deleteBackward()
                textDocumentProxy.insertText(". ")
            } else {
                autocorrect()
                textDocumentProxy.insertText(" ")
                undo?.trailing = " "
                suggester.engine.learn(before: before)
                lastKeyWasSpace = true
            }
            keys.page = .letters

        case .enter:
            autocorrect()
            suggester.engine.learn(before: before)
            undo = nil
            textDocumentProxy.insertText("\n")

        case .backspace:
            if let pendingUndo, before.hasSuffix(pendingUndo.corrected + pendingUndo.trailing) {
                // Take back the auto-correction and remember the word is intentional.
                replace(pendingUndo.corrected + pendingUndo.trailing, with: pendingUndo.original + pendingUndo.trailing)
                suggester.engine.learnWord(pendingUndo.original)
            } else if let pendingSwipe, before.hasSuffix(pendingSwipe.text) {
                // One backspace takes back a whole swiped word.
                replace(pendingSwipe.text, with: "")
            } else {
                textDocumentProxy.deleteBackward()
            }

        case .shift:
            let now = Date()
            if shift != .locked, now.timeIntervalSince(lastShiftTap) < 0.35 {
                shift = .locked
            } else {
                shift = shift == .off ? .on : .off
            }
            lastShiftTap = now
            refresh(updateShift: false)
            return

        case .page(let page):
            keys.page = page
            if panel == .emoji {
                show(.typing)
                refresh()
            }
            return

        case .emoji:
            show(.emoji)
            return

        case .globe:
            return
        }
        refresh()
    }

    private func show(_ panel: Panel) {
        guard panel != self.panel else { return }
        if panel == .emoji {
            emoji.open()
        }
        self.panel = panel
        emojiQuery = panel == .emojiSearch ? "" : nil
        justPickedEmoji = false
        emoji.isHidden = panel != .emoji
        keys.isHidden = panel == .emoji
        bar.isHidden = panel != .typing
        search.isHidden = panel == .typing
        if panel == .emojiSearch {
            keys.page = .letters
            keys.allowsSwipe = false
            if shift != .locked {
                shift = .off
            }
        }
        renderSearch()
    }

    private func renderSearch() {
        search.show(query: emojiQuery, matches: emojiQuery.map { catalog.search($0) } ?? [])
    }

    /// While an emoji is being searched for, the keys type the query rather
    /// than the document. Returns false for keys that keep their usual job.
    private func typeQuery(_ key: Key) -> Bool {
        guard var query = emojiQuery else { return false }
        switch key {
        case .character(let text):
            query += text.lowercased()
        case .space:
            if !query.isEmpty, !query.hasSuffix(" ") {
                query += " "
            }
        case .backspace:
            // With nothing typed, or straight after picking an emoji,
            // backspace edits the document as usual.
            if query.isEmpty || justPickedEmoji {
                return false
            }
            query.removeLast()
        case .enter:
            show(.emoji)
            return true
        case .shift, .page, .emoji, .globe:
            return false
        }
        justPickedEmoji = false
        emojiQuery = query
        renderSearch()
        return true
    }

    private func insertEmoji(_ text: String) {
        UIDevice.current.playInputClick()
        settleSwipe()
        undo = nil
        lastKeyWasSpace = false
        spaceIsAutomatic = false
        catalog.use(text)
        justPickedEmoji = panel == .emojiSearch
        textDocumentProxy.insertText(text)
        refresh()
    }

    private func accept(_ suggestion: Suggestion) {
        UIDevice.current.playInputClick()
        undo = nil
        swipeChoice?.cancel()
        swiped = nil
        lastKeyWasSpace = false
        switch suggestion.kind {
        case .fix:
            replace(suggestion.replace, with: suggestion.insert)
            spaceIsAutomatic = suggestion.insert.hasSuffix(" ")
        case .verbatim:
            suggester.engine.learnWord(suggestion.text)
            textDocumentProxy.insertText(" ")
            spaceIsAutomatic = true
        default:
            replace(suggestion.replace, with: suggestion.insert + " ")
            spaceIsAutomatic = true
        }
        suggester.engine.learn(before: before)
        refresh()
    }
}
