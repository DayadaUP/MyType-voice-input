import AppKit

@MainActor
final class RecordingCountdownWindow {
    private var panelSize = NSSize(width: 52, height: 28)
    private let screenMargin: CGFloat = 8
    private let minPanelWidth: CGFloat = 36
    private let panelHeight: CGFloat = 28
    private let horizontalPadding: CGFloat = 4
    private let panel: NSPanel
    private let textLabel: NSTextField

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = content

        textLabel = NSTextField(labelWithString: "")
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        textLabel.textColor = .systemRed
        textLabel.alignment = .center
        content.addSubview(textLabel)

        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            textLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
    }

    func updateRemainingSeconds(_ seconds: Int, near anchorRect: NSRect?) {
        guard seconds > 0 else {
            hide()
            return
        }
        let text = "\(seconds)s"
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1.5
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        textLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.systemRed,
                .strokeColor: NSColor.white.withAlphaComponent(0.9),
                .strokeWidth: -1.0,
                .shadow: shadow
            ]
        )
        panelSize = measuredPanelSize(for: text)
        panel.setContentSize(panelSize)
        if let anchorRect {
            panel.setFrameOrigin(origin(near: anchorRect))
        }
        panel.orderFrontRegardless()
    }

    func move(near anchorRect: NSRect?) {
        guard panel.isVisible, let anchorRect else { return }
        panel.setFrameOrigin(origin(near: anchorRect))
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func origin(near anchorRect: NSRect) -> NSPoint {
        let target = NSPoint(
            x: anchorRect.midX - panelSize.width / 2,
            y: anchorRect.minY - panelSize.height - 6
        )
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY)) }) else {
            return target
        }
        let visible = screen.visibleFrame
        let minX = visible.minX + screenMargin
        let maxX = visible.maxX - panelSize.width - screenMargin
        let minY = visible.minY + screenMargin
        let maxY = visible.maxY - panelSize.height - screenMargin
        return NSPoint(
            x: max(minX, min(target.x, maxX)),
            y: max(minY, min(target.y, maxY))
        )
    }

    private func measuredPanelSize(for text: String) -> NSSize {
        let font = textLabel.font ?? .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        let bounds = (text as NSString).size(withAttributes: [.font: font])
        let width = max(minPanelWidth, ceil(bounds.width) + horizontalPadding * 2)
        return NSSize(width: width, height: panelHeight)
    }
}
