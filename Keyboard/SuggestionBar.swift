import UIKit

/// The strip above the keys: three suggestions and an Apple Intelligence status light.
final class SuggestionBar: UIView {
    var onSelect: ((Suggestion) -> Void)?
    /// Supplies the text shown when the status light is tapped.
    var statusText: (() -> String)?

    private let stack = UIStackView()
    private let status = UIButton(type: .system)
    private let message = UILabel()
    private var buttons: [UIButton] = []
    private var suggestions: [Suggestion] = []
    private var messageTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        for index in 0..<3 {
            let button = UIButton(type: .system)
            button.tag = index
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            buttons.append(button)
            stack.addArrangedSubview(button)
        }

        status.setImage(UIImage(systemName: "sparkles"), for: .normal)
        status.setPreferredSymbolConfiguration(.init(pointSize: 13, weight: .medium), forImageIn: .normal)
        status.addTarget(self, action: #selector(showStatus), for: .touchUpInside)

        message.font = .preferredFont(forTextStyle: .footnote)
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.adjustsFontSizeToFitWidth = true
        message.minimumScaleFactor = 0.7
        message.isHidden = true

        for view in [stack, message, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: status.leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            message.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            message.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            status.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 30),
            status.heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    enum AIState {
        case unavailable, idle, thinking
    }

    func show(_ suggestions: [Suggestion], highlightAuto: Bool, ai: AIState) {
        self.suggestions = suggestions
        for (index, button) in buttons.enumerated() {
            guard index < suggestions.count else {
                button.configuration = nil
                button.isEnabled = false
                continue
            }
            let suggestion = suggestions[index]
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
            }
            button.configuration = config
            button.isEnabled = true
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
