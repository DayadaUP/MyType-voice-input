import AppKit

@MainActor
protocol LexiconTermCellDelegate: AnyObject {
    func didTapDelete(for term: String)
}

final class LexiconTermCellView: NSView {
    private let term: String
    private weak var delegate: LexiconTermCellDelegate?
    
    private let label = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(frame: .zero)
    
    private var trackingAreaRef: NSTrackingArea?
    
    init(term: String, delegate: LexiconTermCellDelegate?) {
        self.term = term
        self.delegate = delegate
        super.init(frame: .zero)
        
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
        
        label.stringValue = term
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        deleteButton.setButtonType(.momentaryPushIn)
        deleteButton.isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "删除")?.withSymbolConfiguration(config)
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.isHidden = true
        
        addSubview(label)
        addSubview(deleteButton)
        
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -4),
            
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 16),
            deleteButton.heightAnchor.constraint(equalToConstant: 16),
            
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        deleteButton.isHidden = false
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        deleteButton.isHidden = true
    }
    
    @objc private func deleteTapped() {
        delegate?.didTapDelete(for: term)
    }
}
