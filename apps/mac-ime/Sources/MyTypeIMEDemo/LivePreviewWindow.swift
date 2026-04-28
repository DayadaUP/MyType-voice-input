import AppKit

@MainActor
final class LivePreviewWindow {
    private let fallbackLockedPanelWidth: CGFloat = 340
    private let minPanelWidth: CGFloat = 280
    private let maxPanelWidth: CGFloat = 380
    private let widthRatio: CGFloat = 0.16
    private let minPanelHeight: CGFloat = 80
    private let maxPanelHeight: CGFloat = 330
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 13
    private let screenMargin: CGFloat = 12
    private let anchorGap: CGFloat = 8
    private let panel: NSPanel
    private let textLabel: NSTextField
    private var currentPanelWidth: CGFloat

    init() {
        currentPanelWidth = fallbackLockedPanelWidth
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: fallbackLockedPanelWidth, height: minPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        panel.contentView = content

        textLabel = NSTextField(wrappingLabelWithString: "")
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 14, weight: .medium)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byCharWrapping
        textLabel.maximumNumberOfLines = 0
        textLabel.alignment = .left
        if let cell = textLabel.cell {
            cell.wraps = true
            cell.isScrollable = false
            cell.truncatesLastVisibleLine = false
            cell.usesSingleLineMode = false
            cell.lineBreakMode = .byCharWrapping
        }

        content.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: horizontalPadding),
            textLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -horizontalPadding),
            textLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: verticalPadding),
            textLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -verticalPadding)
        ])
    }

    func show(near anchorRect: NSRect?) {
        enforceLockedWidth()
        if let anchorRect {
            let target = NSPoint(
                x: anchorRect.midX - panel.frame.width / 2,
                y: anchorRect.maxY + anchorGap
            )
            panel.setFrameOrigin(clampToVisibleFrame(origin: target, near: anchorRect))
        }
        panel.orderFrontRegardless()
    }

    func updateText(_ text: String, near anchorRect: NSRect?) {
        currentPanelWidth = resolvedPanelWidth(near: anchorRect)
        textLabel.stringValue = text
        resizeForText(text, panelWidth: currentPanelWidth)
        show(near: anchorRect)
        #if DEBUG
        print("LivePreview width locked=\(Int(currentPanelWidth)) actual=\(Int(panel.frame.width)) height=\(Int(panel.frame.height))")
        #endif
    }

    func move(near anchorRect: NSRect?) {
        guard panel.isVisible else { return }
        show(near: anchorRect)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func resizeForText(_ text: String, panelWidth: CGFloat) {
        let lockedWidth = panelWidth
        let availableWidth = max(lockedWidth - horizontalPadding * 2, 120)
        let font = textLabel.font ?? .systemFont(ofSize: 13, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        let contentHeight = ceil(bounds.height) + verticalPadding * 2
        let clampedHeight = min(max(contentHeight, minPanelHeight), maxPanelHeight)
        let estimatedLines = max(1, Int(round(bounds.height / max(font.pointSize + 4, 1))))
        panel.contentMinSize = NSSize(width: lockedWidth, height: minPanelHeight)
        panel.contentMaxSize = NSSize(width: lockedWidth, height: maxPanelHeight)
        var frame = panel.frame
        frame.size = NSSize(width: lockedWidth, height: clampedHeight)
        panel.setFrame(frame, display: false)
        #if DEBUG
        print("LivePreview layout width=\(Int(lockedWidth)) lines~\(estimatedLines) contentH=\(Int(contentHeight)) frameH=\(Int(clampedHeight))")
        #endif
    }

    private func resolvedPanelWidth(near anchorRect: NSRect?) -> CGFloat {
        resolvedLockedPanelWidth(near: anchorRect)
    }

    private func resolvedLockedPanelWidth(near anchorRect: NSRect?) -> CGFloat {
        guard let screen = screenForAnchor(anchorRect) else {
            return fallbackLockedPanelWidth
        }
        let visibleWidth = max(220, screen.visibleFrame.width - screenMargin * 2)
        let adaptive = floor(visibleWidth * widthRatio)
        return min(max(adaptive, minPanelWidth), min(maxPanelWidth, visibleWidth))
    }

    private func enforceLockedWidth() {
        let lockedWidth = min(max(currentPanelWidth, minPanelWidth), maxPanelWidth)
        panel.contentMinSize = NSSize(width: lockedWidth, height: minPanelHeight)
        panel.contentMaxSize = NSSize(width: lockedWidth, height: maxPanelHeight)
        if abs(panel.frame.width - lockedWidth) > 0.5 {
            var frame = panel.frame
            frame.size.width = lockedWidth
            panel.setFrame(frame, display: false)
        }
    }

    private func screenForAnchor(_ anchorRect: NSRect?) -> NSScreen? {
        if let anchorRect,
           let anchorScreen = NSScreen.screens.first(where: {
               $0.visibleFrame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY))
           }) {
            return anchorScreen
        }
        return NSScreen.main
    }

    private func clampToVisibleFrame(origin: NSPoint, near anchorRect: NSRect) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY)) }) else {
            return origin
        }
        let visible = screen.visibleFrame
        let minX = visible.minX + screenMargin
        let maxX = visible.maxX - panel.frame.width - screenMargin
        let minY = visible.minY + screenMargin
        let maxY = visible.maxY - panel.frame.height - screenMargin
        return NSPoint(
            x: max(minX, min(origin.x, maxX)),
            y: max(minY, min(origin.y, maxY))
        )
    }
}
