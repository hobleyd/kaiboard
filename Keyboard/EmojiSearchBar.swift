import UIKit

/// Stands in for the suggestion bar while the emoji picker is up. At rest it
/// is a search field to tap; once tapped, the letter keys come back to type
/// the query and the matches line up beside it.
final class EmojiSearchBar: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    /// The field was tapped: the user wants to type a query.
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onEmoji: ((String) -> Void)?

    private let field = UIControl()
    private let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let text = UILabel()
    private let caret = UIView()
    private let cancel = UIButton(type: .system)
    private let layout = UICollectionViewFlowLayout()
    private let results: UICollectionView

    private var query: String?
    private var matches: [String] = []

    override init(frame: CGRect) {
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        results = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)

        field.backgroundColor = .tertiarySystemFill
        field.layer.cornerRadius = 9
        field.layer.cornerCurve = .continuous
        field.addTarget(self, action: #selector(fieldTapped), for: .touchUpInside)
        glass.tintColor = .secondaryLabel
        glass.contentMode = .center
        glass.preferredSymbolConfiguration = .init(pointSize: 13, weight: .medium)
        text.font = .systemFont(ofSize: 16)
        text.lineBreakMode = .byTruncatingHead
        caret.backgroundColor = .tintColor
        caret.layer.cornerRadius = 1
        for view in [glass, text, caret] {
            view.isUserInteractionEnabled = false
            field.addSubview(view)
        }

        cancel.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancel.setPreferredSymbolConfiguration(.init(pointSize: 16, weight: .regular), forImageIn: .normal)
        cancel.tintColor = .secondaryLabel
        cancel.accessibilityLabel = "Cancel search"
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        results.backgroundColor = .clear
        results.showsHorizontalScrollIndicator = false
        results.alwaysBounceHorizontal = true
        results.dataSource = self
        results.delegate = self
        results.register(EmojiCell.self, forCellWithReuseIdentifier: "emoji")

        for view in [field, results, cancel] {
            addSubview(view)
        }
        show(query: nil, matches: [])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `query` is nil while the field is only an invitation to search.
    func show(query: String?, matches: [String]) {
        let wasSearching = self.query != nil
        self.query = query
        let changed = matches != self.matches
        self.matches = matches

        if let query, !query.isEmpty {
            text.text = query
            text.textColor = .label
        } else {
            text.text = "Search Emoji"
            text.textColor = .secondaryLabel
        }
        let searching = query != nil
        caret.isHidden = !searching
        cancel.isHidden = !searching
        results.isHidden = !searching
        if changed {
            results.reloadData()
            results.setContentOffset(.zero, animated: false)
        }
        if searching != wasSearching {
            caret.layer.removeAllAnimations()
            caret.alpha = 1
            if searching {
                UIView.animate(withDuration: 0.5, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]) {
                    self.caret.alpha = 0
                }
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.insetBy(dx: 6, dy: 4)
        let searching = query != nil
        // While searching the field keeps to the left and the matches get the rest.
        let fieldWidth = searching ? min(max(inner.width * 0.36, 120), inner.width) : inner.width
        field.frame = CGRect(x: inner.minX, y: inner.minY, width: fieldWidth, height: inner.height)
        glass.frame = CGRect(x: 4, y: 0, width: 24, height: inner.height)

        let room = field.bounds.width - glass.frame.maxX - 8
        let typed = searching && !(query ?? "").isEmpty
        let wanted = text.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: inner.height)).width
        text.frame = CGRect(x: glass.frame.maxX, y: 0, width: min(wanted, room), height: inner.height)
        // The caret sits before the placeholder and after anything typed.
        let caretX = typed ? text.frame.maxX + 1 : text.frame.minX - 1
        caret.frame = CGRect(x: caretX, y: (inner.height - 18) / 2, width: 2, height: 18)

        cancel.frame = CGRect(x: bounds.width - 36, y: 0, width: 36, height: bounds.height)
        results.frame = CGRect(x: field.frame.maxX + 4, y: 0, width: max(0, cancel.frame.minX - field.frame.maxX - 4), height: bounds.height)
        if layout.itemSize.height != bounds.height, bounds.height > 0 {
            layout.itemSize = CGSize(width: 40, height: bounds.height)
            layout.invalidateLayout()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        matches.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath) as! EmojiCell
        cell.label.text = matches[indexPath.item]
        cell.label.font = .systemFont(ofSize: 26)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onEmoji?(matches[indexPath.item])
    }

    @objc private func fieldTapped() {
        if query == nil {
            onBegin?()
        }
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
