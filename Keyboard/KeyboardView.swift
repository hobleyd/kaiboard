import UIKit

enum Page {
    case letters, numbers, symbols
}

enum ShiftState {
    case off, on, locked
}

enum Key: Equatable {
    case character(String)
    case shift, backspace, space, enter, globe
    case page(Page)
}

final class KeyButton: UIControl {
    let key: Key
    /// Width in tenths of the keyboard.
    let units: CGFloat
    /// Extra touch area beyond the visible key, for keys at the end of an inset row.
    var slack = UIEdgeInsets.zero

    private let face = UIView()
    let label = UILabel()
    let icon = UIImageView()

    init(_ key: Key, units: CGFloat = 1) {
        self.key = key
        self.units = units
        super.init(frame: .zero)

        face.isUserInteractionEnabled = false
        face.layer.cornerRadius = 8.5
        face.layer.cornerCurve = .continuous
        face.layer.shadowColor = UIColor.black.cgColor
        face.layer.shadowOpacity = 0.25
        face.layer.shadowRadius = 0
        face.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(face)

        label.textAlignment = .center
        label.textColor = .label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        icon.contentMode = .center
        icon.tintColor = .label
        icon.preferredSymbolConfiguration = .init(pointSize: 18, weight: .regular)
        face.addSubview(label)
        face.addSubview(icon)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var isCharacter: Bool {
        switch key {
        case .character, .space: true
        default: false
        }
    }

    /// Draws the key as engaged, e.g. shift while it is on.
    var isActive = false {
        didSet { updateColors() }
    }

    override var isHighlighted: Bool {
        didSet { updateColors() }
    }

    private func updateColors() {
        let plain = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
        let special = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(white: 0.69, alpha: 1) }
        let lit = isCharacter ? isHighlighted : (isHighlighted != isActive)
        face.backgroundColor = isCharacter ? (lit ? special : plain) : (lit ? plain : special)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let visible = bounds.inset(by: slack)
        face.frame = visible.insetBy(dx: 3, dy: min(5.5, visible.height * 0.1))
        label.frame = face.bounds.insetBy(dx: 2, dy: 0)
        icon.frame = face.bounds
    }
}

/// The key grid. Purely presentational: it reports presses and swipes and knows nothing about text.
final class KeyboardView: UIView {
    var onKey: ((Key) -> Void)?
    /// A finger was dragged across the letter keys. Points are in key widths
    /// from the left of the top letter row and rows from its top.
    var onSwipe: (([CGPoint]) -> Void)?
    var allowsSwipe = true
    /// Lets the controller wire the globe key to the system input-mode picker.
    var configureGlobe: ((UIControl) -> Void)?

    var page = Page.letters {
        didSet { if page != oldValue { rebuild() } }
    }
    var shift = ShiftState.off {
        didSet { if shift != oldValue { relabel() } }
    }
    var showsGlobe = false {
        didSet { if showsGlobe != oldValue { rebuild() } }
    }
    var returnTitle = "return" {
        didSet { if returnTitle != oldValue { relabel() } }
    }

    private var rows: [[KeyButton]] = []
    private var repeatTimer: Timer?

    /// A finger currently down on a character key.
    private struct Track {
        let button: KeyButton
        var points: [CGPoint]
        var isSwipe = false
    }
    private var tracks: [UITouch: Track] = [:]
    private let trail = CAShapeLayer()
    private let margin: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        trail.fillColor = nil
        trail.lineWidth = 6
        trail.lineCap = .round
        trail.lineJoin = .round
        trail.zPosition = 1
        layer.addSublayer(trail)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func characters(_ keys: String, units: CGFloat = 1) -> [KeyButton] {
        keys.map { KeyButton(.character(String($0)), units: units) }
    }

    private func makeRows() -> [[KeyButton]] {
        let punctuation = Self.characters(".,?!'", units: 1.4)
        var bottom: [KeyButton] = []
        let other: Page = page == .letters ? .numbers : .letters
        if showsGlobe {
            bottom = [KeyButton(.page(other), units: 1.25), KeyButton(.globe, units: 1.25)]
        } else {
            bottom = [KeyButton(.page(other), units: 2.5)]
        }
        bottom += [KeyButton(.space, units: 5), KeyButton(.enter, units: 2.5)]

        switch page {
        case .letters:
            return [
                Self.characters("qwertyuiop"),
                Self.characters("asdfghjkl"),
                [KeyButton(.shift, units: 1.5)] + Self.characters("zxcvbnm") + [KeyButton(.backspace, units: 1.5)],
                bottom,
            ]
        case .numbers:
            return [
                Self.characters("1234567890"),
                Self.characters("-/:;()$&@\""),
                [KeyButton(.page(.symbols), units: 1.5)] + punctuation + [KeyButton(.backspace, units: 1.5)],
                bottom,
            ]
        case .symbols:
            return [
                Self.characters("[]{}#%^*+="),
                Self.characters("_\\|~<>€£¥•"),
                [KeyButton(.page(.numbers), units: 1.5)] + punctuation + [KeyButton(.backspace, units: 1.5)],
                bottom,
            ]
        }
    }

    private func rebuild() {
        stopRepeating()
        tracks.removeAll()
        trail.path = nil
        rows.joined().forEach { $0.removeFromSuperview() }
        rows = makeRows()
        for button in rows.joined() {
            addSubview(button)
            switch button.key {
            case .character:
                // Character keys are tracked by this view so a touch can turn into a swipe.
                button.isUserInteractionEnabled = false
            case .space, .shift:
                button.addTarget(self, action: #selector(pressed(_:)), for: .touchDown)
            case .backspace:
                button.addTarget(self, action: #selector(backspaceDown(_:)), for: .touchDown)
                button.addTarget(self, action: #selector(stopRepeating), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            case .enter, .page:
                button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            case .globe:
                configureGlobe?(button)
            }
        }
        relabel()
        setNeedsLayout()
    }

    private func relabel() {
        for button in rows.joined() {
            button.label.font = .systemFont(ofSize: 16)
            switch button.key {
            case .character(let text):
                button.label.text = shift == .off ? text : text.uppercased()
                button.label.font = .systemFont(ofSize: page == .letters ? 24 : 21, weight: .light)
            case .shift:
                let name = switch shift {
                case .off: "shift"
                case .on: "shift.fill"
                case .locked: "capslock.fill"
                }
                button.icon.image = UIImage(systemName: name)
                button.isActive = shift != .off
            case .backspace:
                button.icon.image = UIImage(systemName: "delete.left")
            case .globe:
                button.icon.image = UIImage(systemName: "globe")
            case .space:
                button.label.text = "space"
            case .enter:
                button.label.text = returnTitle
            case .page(let target):
                button.label.text = switch target {
                case .letters: "ABC"
                case .numbers: "123"
                case .symbols: "#+="
                }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let unit = (bounds.width - 2 * margin) / 10
        let rowHeight = bounds.height / CGFloat(max(rows.count, 1))
        for (index, row) in rows.enumerated() {
            let total = row.reduce(0) { $0 + $1.units }
            let inset = margin + (10 - total) / 2 * unit
            var x = inset
            for button in row {
                let width = button.units * unit
                var frame = CGRect(x: x, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
                button.slack = .zero
                // Stretch the outermost keys to the screen edge so near misses still land.
                if button === row.first {
                    frame.origin.x -= inset
                    frame.size.width += inset
                    button.slack.left = inset
                }
                if button === row.last {
                    frame.size.width += inset
                    button.slack.right = inset
                }
                button.frame = frame
                button.setNeedsLayout()
                x += width
            }
        }
    }

    // MARK: Taps and swipes on character keys

    private func characterButton(at point: CGPoint) -> KeyButton? {
        rows.joined().first { button in
            if case .character = button.key { return button.frame.contains(point) }
            return false
        }
    }

    private func isLetter(_ button: KeyButton) -> Bool {
        if case .character(let text) = button.key { return text.allSatisfy(\.isLetter) }
        return false
    }

    /// Types every finger that is resting on a key, so that a second thumb
    /// landing before the first lifts keeps the letters in order.
    private func commitTaps() {
        for (touch, track) in tracks where !track.isSwipe {
            track.button.isHighlighted = false
            tracks[touch] = nil
            onKey?(track.button.key)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        commitTaps()
        for touch in touches {
            let point = touch.location(in: self)
            guard let button = characterButton(at: point) else { continue }
            button.isHighlighted = true
            tracks[touch] = Track(button: button, points: [point])
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let unit = (bounds.width - 2 * margin) / 10
        for touch in touches {
            guard var track = tracks[touch] else { continue }
            let point = touch.location(in: self)
            track.points.append(point)
            if !track.isSwipe, allowsSwipe, page == .letters, tracks.count == 1, isLetter(track.button),
               let over = characterButton(at: point), over !== track.button,
               hypot(point.x - track.points[0].x, point.y - track.points[0].y) > unit * 0.7 {
                track.isSwipe = true
                track.button.isHighlighted = false
            }
            tracks[touch] = track
            if track.isSwipe {
                let path = UIBezierPath()
                path.move(to: track.points[0])
                track.points.dropFirst().forEach(path.addLine(to:))
                trail.strokeColor = tintColor.withAlphaComponent(0.45).cgColor
                trail.path = path.cgPath
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let unit = (bounds.width - 2 * margin) / 10
        let rowHeight = bounds.height / CGFloat(max(rows.count, 1))
        for touch in touches {
            guard let track = tracks.removeValue(forKey: touch) else { continue }
            track.button.isHighlighted = false
            if track.isSwipe {
                trail.path = nil
                onSwipe?(track.points.map { CGPoint(x: ($0.x - margin) / unit, y: $0.y / rowHeight) })
            } else {
                onKey?(track.button.key)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            tracks.removeValue(forKey: touch)?.button.isHighlighted = false
        }
        trail.path = nil
    }

    // MARK: Other keys

    @objc private func pressed(_ sender: KeyButton) {
        onKey?(sender.key)
    }

    @objc private func backspaceDown(_ sender: KeyButton) {
        onKey?(.backspace)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.onKey?(.backspace)
            }
        }
    }

    @objc private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
