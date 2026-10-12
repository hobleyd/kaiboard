import UIKit

/// The strip above the keys: a row of suggestions that scrolls sideways when
/// there are more than fit, and an Apple Intelligence status light.
final class SuggestionBar: UIView {
    var onSelect: ((Suggestion) -> Void)?
    /// The Review button was tapped: the user wants more options.
    var onReview: (() -> Void)?
    /// Supplies the text shown when the status light is tapped.
    var statusText: (() -> String)?

    /// How many suggestions are visible without scrolling.
    private static let visibleSlots: CGFloat = 3

    private let review = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let status = UIButton(type: .system)
    private let message = UILabel()
    private var buttons: [UIButton] = []
    private var suggestions: [Suggestion] = []
    private var messageTimer: Timer?
    /// The latest `show` that arrived while a finger was scrolling the bar.
    private var deferred: (() -> Void)?
    private var isPanning = false
    private var panStart: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        var reviewConfig = UIButton.Configuration.tinted()
        reviewConfig.title = "Review"
        reviewConfig.image = UIImage(systemName: "sparkle.magnifyingglass")
        reviewConfig.imagePadding = 3
        reviewConfig.cornerStyle = .capsule
        reviewConfig.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 10)
        reviewConfig.preferredSymbolConfigurationForImage = .init(pointSize: 11, weight: .semibold)
        reviewConfig.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 14, weight: .medium)
            return attributes
        }
        review.configuration = reviewConfig
        review.isHidden = true
        review.setContentHuggingPriority(.required, for: .horizontal)
        review.setContentCompressionResistancePriority(.required, for: .horizontal)
        review.addTarget(self, action: #selector(reviewTapped), for: .touchUpInside)

        scroll.showsHorizontalScrollIndicator = false
        // The bar scrolls itself, from a pan anywhere on it in any direction.
        // The scroll view's own recogniser has to guess whether a touch is a
        // tap on a suggestion or a sideways drag, and on a strip this thin it
        // guessed wrong too often.
        scroll.isScrollEnabled = false
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        status.setImage(UIImage(systemName: "sparkles"), for: .normal)
        status.setPreferredSymbolConfiguration(.init(pointSize: 13, weight: .medium), forImageIn: .normal)
        status.addTarget(self, action: #selector(showStatus), for: .touchUpInside)

        message.font = .preferredFont(forTextStyle: .footnote)
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.adjustsFontSizeToFitWidth = true
        message.minimumScaleFactor = 0.7
        message.numberOfLines = 2
        message.isHidden = true

        let row = UIStackView(arrangedSubviews: [review, scroll, status])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        for view in [row, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // With up to three suggestions the row is exactly as wide as the bar;
        // beyond that each keeps a third of the bar and the row scrolls.
        let snug = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        snug.priority = .defaultLow
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalTo: row.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
            snug,
            message.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            message.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 30),
            status.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    enum AIState {
        case unavailable, idle, thinking
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let limit = max(0, scroll.contentSize.width - scroll.bounds.width)
        switch pan.state {
        case .began:
            isPanning = true
            scroll.layer.removeAllAnimations()
            panStart = scroll.contentOffset.x
        case .changed:
            var x = panStart - pan.translation(in: self).x
            // Past either end the row drags with resistance, which shows the
            // touch was felt even when there is nothing more to scroll to.
            if x < 0 {
                x /= 3
            } else if x > limit {
                x = limit + (x - limit) / 3
            }
            scroll.contentOffset.x = x
        case .ended, .cancelled, .failed:
            // Carry on a little way in the direction of a flick.
            let coast = pan.state == .ended ? pan.velocity(in: self).x * 0.2 : 0
            let target = min(max(scroll.contentOffset.x - coast, 0), limit)
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.scroll.contentOffset.x = target
            }
            isPanning = false
            applyDeferred()
        default:
            break
        }
    }

    private func applyDeferred() {
        let update = deferred
        deferred = nil
        update?()
    }

    func show(_ suggestions: [Suggestion], highlightAuto: Bool, ai: AIState, offersReview: Bool = false) {
        // Suggestions often change just as a finger starts scrolling the old
        // ones. Swapping the buttons out from under it would kill the drag.
        guard !isPanning else {
            deferred = { [weak self] in
                self?.show(suggestions, highlightAuto: highlightAuto, ai: ai, offersReview: offersReview)
            }
            return
        }
        deferred = nil
        // When options are added to the end of the same list, keep the user's
        // place and bring the first new one into view; otherwise start over.
        let previous = self.suggestions
        let extended = !previous.isEmpty && suggestions.count > previous.count && Array(suggestions.prefix(previous.count)) == previous
        let unchanged = suggestions == previous
        self.suggestions = suggestions
        review.isHidden = !offersReview

        while buttons.count > suggestions.count {
            buttons.removeLast().removeFromSuperview()
        }
        while buttons.count < suggestions.count {
            let button = UIButton(type: .system)
            button.tag = buttons.count
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, multiplier: 1 / Self.visibleSlots).isActive = true
            buttons.append(button)
        }

        for (button, suggestion) in zip(buttons, suggestions) {
            var config = UIButton.Configuration.plain()
            config.title = suggestion.kind == .verbatim ? "“\(suggestion.text)”" : suggestion.text
            config.titleLineBreakMode = .byTruncatingMiddle
            config.contentInsets = .init(top: 0, leading: 4, bottom: 0, trailing: 4)
            config.baseForegroundColor = .label
            config.titleTextAttributesTransformer = .init { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 17)
                return attributes
            }
            if suggestion.kind == .fix {
                // Rewrites the word already typed, so make it look different.
                config.image = UIImage(systemName: "arrow.uturn.backward")
                config.baseForegroundColor = .tintColor
            } else if suggestion.ai {
                config.image = UIImage(systemName: "sparkle")
            }
            config.imagePadding = 4
            config.preferredSymbolConfigurationForImage = .init(pointSize: 10, weight: .semibold)
            if suggestion.auto && highlightAuto {
                config.background.backgroundColor = .tertiarySystemFill
                config.background.cornerRadius = 8
                config.background.backgroundInsets = .init(top: 4, leading: 0, bottom: 4, trailing: 0)
            }
            button.configuration = config
        }

        if extended {
            layoutIfNeeded()
            scroll.scrollRectToVisible(buttons[previous.count].frame, animated: true)
        } else if !unchanged {
            scroll.setContentOffset(.zero, animated: false)
        }

        status.layer.removeAllAnimations()
        switch ai {
        case .unavailable:
            status.tintColor = .quaternaryLabel
            status.alpha = 1
        case .idle:
            status.tintColor = .secondaryLabel
            status.alpha = 1
        case .thinking:
            status.tintColor = .tintColor
            status.alpha = 1
            UIView.animate(withDuration: 0.5, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]) {
                self.status.alpha = 0.3
            }
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        guard sender.tag < suggestions.count else { return }
        onSelect?(suggestions[sender.tag])
    }

    @objc private func reviewTapped() {
        onReview?()
    }

    @objc private func showStatus() {
        message.text = statusText?()
        message.isHidden = false
        stack.isHidden = true
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.message.isHidden = true
            self?.stack.isHidden = false
        }
    }
}
