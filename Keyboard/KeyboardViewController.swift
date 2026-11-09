import UIKit

private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// The keys a field wants.
private struct FieldSetup: Equatable {
    var page: Page
    var marks: [String]
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
    /// The keys the last field wanted.
    private var fieldSetup: FieldSetup?

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
    /// Where learned words are saved; set when they are first loaded.
    private var store: URL?
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
        keys.onSwipe = { [weak self] path, fromSpace, toSpace in self?.handleSwipe(path, fromSpace: fromSpace, toSpace: toSpace) }
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
        // Only Apple's keyboard can fetch passwords, so the key button hands over to it, the way the globe does.
        bar.configureCredentials = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(self.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        bar.statusText = { [weak self] in
            guard let self else { return "" }
            var text = self.suggester.predictor.statusText
            if let problem = self.keys.lastProblem {
                text += "\n\(problem.text), \(Int(-problem.at.timeIntervalSinceNow)) s ago"
            }
            return text
        }
        suggester.onUpdate = { [weak self] in self?.render() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if store == nil {
            loadLearned()
        }
        if hasFullAccess {
            suggester.engine.applyForgetting()
            suggester.invalidate()
        }
        suggester.predictor.prewarm()
        keys.showsGlobe = needsInputModeSwitchKey
        fieldSetup = nil
        applyField()
        show(.typing)
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if hasFullAccess {
            suggester.engine.applyForgetting()
        }
        suggester.engine.save(to: store)
    }

    /// Loads learned words from the container shared with the app if the
    /// keyboard has Full Access, so they can be reviewed there, or else from its own.
    private func loadLearned() {
        let engine = suggester.engine
        guard hasFullAccess, let shared = TextEngine.Store.shared else {
            store = TextEngine.Store.local
            engine.load(from: store)
            return
        }
        store = shared
        engine.load(from: shared)
        // Words learned before Full Access was allowed move to the shared container.
        if let local = TextEngine.Store.local, FileManager.default.fileExists(atPath: local.path) {
            engine.load(from: local)
            engine.applyForgetting()
            engine.save(to: shared)
            try? FileManager.default.removeItem(at: local)
        }
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
            applyField()
        }
        refresh()
    }

    // MARK: Field traits

    private var before: String {
        textDocumentProxy.documentContextBeforeInput ?? ""
    }

    private var contentType: UITextContentType? {
        textDocumentProxy.textContentType ?? nil
    }

    /// Content types that want literal typing even on the default keyboard.
    private static let literalContentTypes: Set<UITextContentType> = [
        .username, .password, .newPassword, .oneTimeCode, .emailAddress, .URL, .telephoneNumber,
        .creditCardNumber, .creditCardSecurityCode, .creditCardExpiration, .creditCardExpirationMonth,
        .creditCardExpirationYear, .flightNumber, .shipmentTrackingNumber, .cellularEID, .cellularIMEI,
    ]

    /// Content types made only of digits.
    private static let numericContentTypes: Set<UITextContentType> = [
        .oneTimeCode, .creditCardNumber, .creditCardSecurityCode, .creditCardExpirationMonth,
        .creditCardExpirationYear, .cellularEID, .cellularIMEI,
    ]

    private static let credentialTypes: Set<UITextContentType> = [.username, .password, .newPassword, .oneTimeCode, .emailAddress]

    /// A field a password manager could fill: a username, password or sign-in code.
    private var isCredential: Bool {
        contentType.map(Self.credentialTypes.contains) ?? false
    }

    /// Fields like URLs, e-mail addresses and passwords want literal typing.
    private var isProse: Bool {
        if let contentType, Self.literalContentTypes.contains(contentType) { return false }
        switch textDocumentProxy.keyboardType ?? .default {
        case .URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad:
            return false
        default:
            return true
        }
    }

    /// Codes and card numbers, which want a number pad whatever keyboard the app asked for.
    private var isNumericCode: Bool {
        contentType.map(Self.numericContentTypes.contains) ?? false
    }

    private var spellChecks: Bool {
        textDocumentProxy.spellCheckingType != .no
    }

    /// The page the keys open on, and go back to after a space.
    private var startPage: Page {
        if isNumericCode { return .digits }
        return switch textDocumentProxy.keyboardType ?? .default {
        case .numberPad, .asciiCapableNumberPad: .digits
        case .decimalPad: .decimal
        case .numbersAndPunctuation: .numbers
        default: .letters
        }
    }

    /// The marks beside the space bar.
    private var marks: [String] {
        if contentType == .emailAddress { return ["@", "."] }
        if contentType == .URL { return ["/", "."] }
        return switch textDocumentProxy.keyboardType ?? .default {
        case .emailAddress: ["@", "."]
        case .URL: ["/", "."]
        case .twitter: ["@", "#"]
        default: [",", "."]
        }
    }

    /// Sets the keys up for the field, if it wants different keys from the last one.
    private func applyField() {
        let setup = FieldSetup(page: startPage, marks: marks)
        guard setup != fieldSetup else { return }
        fieldSetup = setup
        show(.typing)
        keys.marks = setup.marks
        keys.page = setup.page
    }

    private var autocorrects: Bool {
        isProse && spellChecks && textDocumentProxy.autocorrectionType != .no
    }

    /// Whether words typed here may be learned. Postcodes are prose, for their
    /// capitals, but shouldn't come back as suggestions.
    private var learns: Bool {
        autocorrects && contentType != .postalCode
    }

    private func learn() {
        if learns {
            suggester.engine.learn(before: before)
        }
    }

    private func learnWord(_ word: String) {
        if learns {
            suggester.engine.learnWord(word)
        }
    }

    /// Records that the user changed `from` into `to`, so `to` is offered first next time.
    private func learnFix(from: String, to: String) {
        if learns {
            suggester.engine.learnFix(from: from, to: to)
        }
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

    /// Fields can ask for return to wait until something has been typed. It always closes the emoji search.
    private var returnEnabled: Bool {
        emojiQuery != nil || textDocumentProxy.enablesReturnKeyAutomatically != true || !before.isEmpty
            || !(textDocumentProxy.documentContextAfterInput ?? "").isEmpty
            || !(textDocumentProxy.selectedText ?? "").isEmpty
    }

    /// Fields can ask for a light or dark keyboard regardless of the system setting.
    private var appearance: UIUserInterfaceStyle {
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
    }

    // MARK: State

    /// Re-reads the document and updates suggestions, and optionally shift.
    private func refresh(updateShift: Bool = true, useAI: Bool = true, patience: Duration? = nil) {
        updateSelection()
        suggester.update(before: before, useAI: isProse && useAI && selection == nil && !keys.isTouched, patience: patience)
        keys.returnTitle = returnTitle
        keys.returnEnabled = returnEnabled
        view.overrideUserInterfaceStyle = appearance
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
        // Words the user has changed this one into before lead.
        let preferred = engine.preferred(for: word)
        // Words the selection could be a slip for: other readings of the swipe that produced it, then near spellings.
        let near = engine.replacements(
            for: word, from: preferred + siblings + engine.neighbours(of: word, limit: 6), limit: 8 + preferred.count)
        selection = Selection(word: word, before: before, after: after, options: near, isThinking: predictor.isAvailable)
        guard predictor.isAvailable else { return }

        selectionTask = Task { [weak self] in
            let filled = await predictor.fill(before: before, after: after, hints: siblings)
            guard !Task.isCancelled, let self, self.selection?.word == word else { return }
            var options = engine.replacements(for: word, from: filled ?? [])
            self.selection?.fromAI.formUnion(options.map { $0.lowercased() })
            self.selection?.options = engine.replacements(for: word, from: preferred + options + near, limit: Self.selectionOptions)
            self.render()

            // Lead with whichever near-miss fits the sentence best. Picking
            // from a list is far more reliable than the open-ended fill, which
            // stumbles on small words ("This ____ a test" gets nouns, not "is").
            let pick = near.count > 1 ? await predictor.choose(from: near, after: before, before: after) : near.first
            guard !Task.isCancelled, self.selection?.word == word else { return }
            if let pick {
                options.removeAll { $0 == pick }
                options.insert(pick, at: 0)
                self.selection?.fromAI.insert(pick.lowercased())
            }
            self.selection?.options = engine.replacements(for: word, from: preferred + options + near, limit: Self.selectionOptions)
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

    /// `text` lower-cased if it has any capitals, otherwise with its first letter capitalised.
    private static func togglingCase(of text: String) -> String {
        if text.contains(where: \.isUppercase) { return text.lowercased() }
        guard let first = text.firstIndex(where: \.isLetter) else { return text }
        return text[..<first] + text[first...].prefix(1).uppercased() + text[text.index(after: first)...]
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
        if !spellChecks {
            suggestions.removeAll { $0.kind == .fix || $0.kind == .correction }
        }
        if let swiped, before.hasSuffix(swiped.text) {
            // Lead with the other words the swipe could have meant.
            let others = swiped.alternatives.map {
                Suggestion(text: $0, replace: swiped.text, insert: $0 + " ", kind: .fix, ai: false, auto: false)
            }
            suggestions = others + suggestions.filter { $0.kind != .fix }
        }
        bar.show(suggestions, highlightAuto: autocorrects, ai: ai, offersCredentials: isCredential)
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
            learn()
        }
        swiped = nil
    }

    private func handleSwipe(_ path: [CGPoint], fromSpace: Bool, toSpace: Bool) {
        UIDevice.current.playInputClick()
        undo = nil
        settleSwipe()
        lastKeyWasSpace = false
        let (words, contenders) = suggester.engine.swipe(
            before: before, path: path, fromSpace: fromSpace, toSpace: toSpace, limit: Self.swipeCandidates)
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
                learn()
            }
            if text == "'" {
                keys.page = startPage
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
                learn()
                lastKeyWasSpace = true
            }
            keys.page = startPage

        case .enter:
            guard returnEnabled else { return }
            autocorrect()
            learn()
            undo = nil
            textDocumentProxy.insertText("\n")

        case .backspace:
            if let pendingUndo, before.hasSuffix(pendingUndo.corrected + pendingUndo.trailing) {
                // Take back the auto-correction and remember the word is intentional.
                replace(pendingUndo.corrected + pendingUndo.trailing, with: pendingUndo.original + pendingUndo.trailing)
                learnWord(pendingUndo.original)
                suggester.engine.forgetFix(from: pendingUndo.original, to: pendingUndo.corrected)
            } else if let pendingSwipe, before.hasSuffix(pendingSwipe.text) {
                // One backspace takes back a whole swiped word.
                replace(pendingSwipe.text, with: "")
            } else {
                textDocumentProxy.deleteBackward()
            }

        case .shift:
            if selection != nil, let text = textDocumentProxy.selectedText {
                // With a word selected, shift flips its capital instead.
                textDocumentProxy.insertText(Self.togglingCase(of: text))
                break
            }
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

        case .globe, .gap:
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
        keys.returnEnabled = returnEnabled
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
        case .shift, .page, .emoji, .globe, .gap:
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
        let pendingSwipe = swiped
        swiped = nil
        lastKeyWasSpace = false
        switch suggestion.kind {
        case .fix:
            if let selection {
                learnFix(from: selection.word, to: suggestion.text)
            } else if let pendingSwipe, suggestion.replace == pendingSwipe.text {
                learnFix(from: pendingSwipe.text.trimmingCharacters(in: .whitespaces), to: suggestion.text)
            }
            replace(suggestion.replace, with: suggestion.insert)
            spaceIsAutomatic = suggestion.insert.hasSuffix(" ")
        case .verbatim:
            learnWord(suggestion.text)
            textDocumentProxy.insertText(" ")
            spaceIsAutomatic = true
        default:
            replace(suggestion.replace, with: suggestion.insert + " ")
            spaceIsAutomatic = true
        }
        learn()
        refresh()
    }
}
