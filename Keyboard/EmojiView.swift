import UIKit

final class EmojiCell: UICollectionViewCell {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 29)
        label.textAlignment = .center
        contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted ? .tertiarySystemFill : nil
            contentView.layer.cornerRadius = 8
        }
    }
}

private final class EmojiHeader: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 0)
    }
}

/// The emoji picker, which takes the place of the keys: every emoji in one
/// scrolling grid, grouped, with the ones used lately first.
final class EmojiView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onEmoji: ((String) -> Void)?
    /// The keys along the bottom: back to the letters, and backspace.
    var onKey: ((Key) -> Void)?

    private struct Group {
        let name: String
        let symbol: String
        var emoji: [String]
    }

    private static let symbols = [
        "Smileys & People": "face.smiling",
        "Animals & Nature": "leaf",
        "Food & Drink": "fork.knife",
        "Travel & Places": "car",
        "Activities": "soccerball",
        "Objects": "lightbulb",
        "Symbols": "heart",
        "Flags": "flag",
    ]
    private static let columns: CGFloat = 8

    private let catalog: EmojiCatalog
    /// Recents first, as they stood when the picker opened so the grid
    /// doesn't shuffle under the finger, then the catalog's groups.
    private var groups: [Group]

    private let layout = UICollectionViewFlowLayout()
    private let grid: UICollectionView
    private let letters = KeyButton(.page(.letters))
    private let backspace = KeyButton(.backspace)
    private let tabs = UIStackView()
    private var repeatTimer: Timer?
    private let barHeight: CGFloat = 44

    init(catalog: EmojiCatalog) {
        self.catalog = catalog
        groups = [Group(name: "Recently Used", symbol: "clock", emoji: catalog.recents)] + catalog.groups.map {
            Group(name: $0.name, symbol: Self.symbols[$0.name] ?? "circle", emoji: $0.entries.map(\.emoji))
        }
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)

        grid.backgroundColor = .clear
        grid.dataSource = self
        grid.delegate = self
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "emoji")
        grid.register(EmojiHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        addSubview(grid)

        letters.label.text = "ABC"
        letters.label.font = .systemFont(ofSize: 16)
        letters.addTarget(self, action: #selector(lettersTapped), for: .touchUpInside)
        backspace.icon.image = UIImage(systemName: "delete.left")
        backspace.addTarget(self, action: #selector(backspaceDown), for: .touchDown)
        backspace.addTarget(self, action: #selector(stopRepeating), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])

        tabs.axis = .horizontal
        tabs.distribution = .fillEqually
        for (index, group) in groups.enumerated() {
            let tab = UIButton(type: .system)
            tab.setImage(UIImage(systemName: group.symbol), for: .normal)
            tab.setPreferredSymbolConfiguration(.init(pointSize: 15, weight: .regular), forImageIn: .normal)
            tab.accessibilityLabel = group.name
            tab.tag = index
            tab.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            tabs.addArrangedSubview(tab)
        }
        for view in [letters, tabs, backspace] {
            addSubview(view)
        }
        markTab(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the picker up to date before it is shown.
    func open() {
        groups[0].emoji = catalog.recents
        grid.reloadData()
        grid.layoutIfNeeded()
        grid.setContentOffset(.zero, animated: false)
        markTab(firstSection)
    }

    /// The first section that has anything in it.
    private var firstSection: Int {
        groups.firstIndex { !$0.emoji.isEmpty } ?? 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let unit = bounds.width / 10
        grid.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
        let bar = CGRect(x: 0, y: grid.frame.maxY, width: bounds.width, height: barHeight)
        letters.frame = CGRect(x: 0, y: bar.minY, width: unit * 1.5, height: barHeight)
        backspace.frame = CGRect(x: bounds.width - unit * 1.5, y: bar.minY, width: unit * 1.5, height: barHeight)
        tabs.frame = CGRect(x: letters.frame.maxX, y: bar.minY, width: backspace.frame.minX - letters.frame.maxX, height: barHeight)

        let side = (bounds.width / Self.columns).rounded(.down)
        if layout.itemSize.width != side {
            layout.itemSize = CGSize(width: side, height: 42)
            let slack = (bounds.width - side * Self.columns) / 2
            layout.sectionInset = UIEdgeInsets(top: 0, left: slack, bottom: 4, right: slack)
            layout.invalidateLayout()
        }
    }

    // MARK: Grid

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        groups.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        groups[section].emoji.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath) as! EmojiCell
        cell.label.text = groups[indexPath.section].emoji[indexPath.item]
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! EmojiHeader
        header.label.text = groups[indexPath.section].name.uppercased()
        return header
    }

    func collectionView(
        _ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        groups[section].emoji.isEmpty ? .zero : CGSize(width: collectionView.bounds.width, height: 24)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onEmoji?(groups[indexPath.section].emoji[indexPath.item])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // The group at the top of the grid is the one whose tab is lit.
        let top = CGPoint(x: grid.bounds.midX, y: grid.contentOffset.y + 30)
        let section = grid.indexPathForItem(at: top)?.section
            ?? grid.indexPathsForVisibleItems.map(\.section).min()
        if let section {
            markTab(section)
        }
    }

    // MARK: Bottom bar

    private func markTab(_ section: Int) {
        for case let tab as UIButton in tabs.arrangedSubviews {
            tab.tintColor = tab.tag == section ? .label : .tertiaryLabel
        }
    }

    @objc private func tabTapped(_ sender: UIButton) {
        let section = sender.tag
        guard !groups[section].emoji.isEmpty else { return }
        let header = grid.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))
        let limit = max(0, grid.contentSize.height - grid.bounds.height)
        grid.setContentOffset(CGPoint(x: 0, y: min(header?.frame.minY ?? 0, limit)), animated: false)
        markTab(section)
    }

    @objc private func lettersTapped() {
        onKey?(.page(.letters))
    }

    @objc private func backspaceDown() {
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
