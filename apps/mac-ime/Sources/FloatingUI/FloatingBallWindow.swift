#if canImport(AppKit)
import AppKit
import QuartzCore
import Common

@MainActor
public final class FloatingBallWindow {
    private enum Layout {
        static let panelSize = NSSize(width: 141, height: 43)
        static let cornerRadius: CGFloat = panelSize.height / 2
        static let horizontalInset: CGFloat = 14
        static let contentSpacing: CGFloat = 8
        static let iconSize: CGFloat = 16
        static let bottomMargin: CGFloat = 18
        static let dockClearance: CGFloat = 14
    }

    public var onTap: (() -> Void)?
    public var onSecondaryTap: (() -> Void)?
    public var onMoved: ((NSPoint) -> Void)?
    public private(set) var state: RecordingState = .idle

    private let panel: NSPanel
    private let button: FloatingBallButton
    private let titleField = NSTextField(labelWithString: "")
    private let iconLayer = CALayer()
    private let processingProgressTrackLayer = CALayer()
    private let processingProgressFillLayer = CALayer()
    private var processingProgress: CGFloat = 0

    public init(initialOrigin: NSPoint = NSPoint(x: 80, y: 480)) {
        panel = NSPanel(
            contentRect: NSRect(origin: initialOrigin, size: Layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        button = FloatingBallButton(frame: NSRect(origin: .zero, size: Layout.panelSize))

        configurePanel()
        configureButton()
        setState(.idle)
    }

    public func show() {
        positionPanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public func frameInScreen() -> NSRect {
        panel.frame
    }

    public func setState(_ nextState: RecordingState) {
        state = nextState
        if nextState != .processing {
            processingProgress = 0
        }
        applyStyle(for: nextState)
        updateProcessingProgressLayers(for: nextState)
        if nextState == .idle {
            hide()
        } else {
            show()
        }
    }

    public func setProcessingProgress(_ progress: Double) {
        let clamped = max(0.0, min(1.0, progress))
        processingProgress = CGFloat(clamped)
        guard state == .processing else { return }
        updateProcessingProgressLayers(for: .processing)
    }

    public func refreshDisplay() {
        panel.displayIfNeeded()
        panel.contentView?.displayIfNeeded()
    }

    private func configurePanel() {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        let contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = contentView
    }

    private func configureButton() {
        button.isBordered = false
        button.wantsLayer = true
        button.focusRingType = .none
        button.layer?.cornerRadius = Layout.cornerRadius
        button.layer?.cornerCurve = .continuous
        button.layer?.masksToBounds = true
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        button.imagePosition = .imageOnly
        button.image = nil
        button.toolTip = "MyType 语音输入"
        button.onPrimaryTap = { [weak self] in
            self?.onTap?()
        }
        button.onSecondaryTap = { [weak self] in
            self?.onSecondaryTap?()
        }
        button.onMoved = { [weak self] point in
            self?.onMoved?(point)
        }

        configureIconLayer()
        configureTitleField()
        configureProcessingProgressLayers()
        panel.contentView?.addSubview(button)
    }

    private func configureTitleField() {
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.font = .systemFont(ofSize: 13, weight: .bold)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        button.addSubview(titleField)
        updateContentLayout()
    }

    private func configureIconLayer() {
        guard let buttonLayer = button.layer else { return }
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.masksToBounds = false
        iconLayer.zPosition = 20
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        buttonLayer.addSublayer(iconLayer)
        updateIconLayerFrame()
    }

    private func updateIconLayerFrame() {
        updateContentLayout()
    }

    private func configureProcessingProgressLayers() {
        guard let buttonLayer = button.layer else { return }
        processingProgressTrackLayer.isHidden = true
        processingProgressTrackLayer.masksToBounds = true
        processingProgressTrackLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.30).cgColor
        processingProgressFillLayer.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.95).cgColor
        processingProgressTrackLayer.addSublayer(processingProgressFillLayer)
        buttonLayer.addSublayer(processingProgressTrackLayer)
        updateProcessingProgressLayers(for: .idle)
    }

    private func updateProcessingProgressLayers(for state: RecordingState) {
        guard button.layer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = button.bounds
        updateIconLayerFrame()
        processingProgressTrackLayer.frame = bounds
        processingProgressTrackLayer.cornerRadius = Layout.cornerRadius

        let progressWidth = max(0, min(bounds.width, bounds.width * processingProgress))
        processingProgressFillLayer.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: progressWidth,
            height: bounds.height
        )
        processingProgressFillLayer.cornerRadius = Layout.cornerRadius

        let isProcessing = state == .processing
        processingProgressTrackLayer.isHidden = !isProcessing
        if isProcessing {
            processingProgressTrackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            processingProgressFillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
        }
        if !isProcessing {
            processingProgressFillLayer.frame.size.width = 0
        }
    }

    private func applyStyle(for state: RecordingState) {
        if state != .processing {
            stopProcessingIconAnimation()
        }
        switch state {
        case .idle:
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
            button.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
            titleField.stringValue = "准备输入"
            titleField.textColor = NSColor.black.withAlphaComponent(0.82)
            setIconSymbol("mic.fill", tint: .black)
            button.toolTip = "左键开始录音"
        case .recording:
            button.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.96).cgColor
            button.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.50).cgColor
            titleField.stringValue = "正在输入"
            titleField.textColor = NSColor.white.withAlphaComponent(0.96)
            setIconSymbol("waveform", tint: .white)
            button.toolTip = "左键结束录音，右键取消本次录音"
        case .processing:
            button.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.92).cgColor
            button.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.55).cgColor
            titleField.stringValue = "正在识别"
            titleField.textColor = NSColor.white.withAlphaComponent(0.96)
            setIconSymbol("arrow.triangle.2.circlepath", tint: .white)
            startProcessingIconAnimation()
            button.toolTip = "识别处理进度"
        }
        updateContentLayout()
    }

    private func setIconSymbol(_ symbolName: String, tint: NSColor) {
        button.contentTintColor = tint
        button.image = nil
        guard let image = symbol(named: symbolName, tint: tint),
              let cgImage = cgImage(from: image) else {
            iconLayer.contents = nil
            return
        }
        iconLayer.contents = cgImage
    }

    private func startProcessingIconAnimation() {
        let layer = iconLayer
        let rotateKey = "mytype.processing.rotate"
        if layer.animation(forKey: rotateKey) == nil {
            let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
            rotate.fromValue = 0.0
            rotate.toValue = Double.pi * 2.0
            rotate.duration = 1.5
            rotate.repeatCount = .infinity
            rotate.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(rotate, forKey: rotateKey)
        }
    }

    private func stopProcessingIconAnimation() {
        let layer = iconLayer
        layer.removeAnimation(forKey: "mytype.processing.rotate")
        layer.transform = CATransform3DIdentity
    }

    private func symbol(named name: String, tint: NSColor? = nil) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        if let tint {
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func updateContentLayout() {
        let bounds = button.bounds
        let iconWidth = iconLayer.contents == nil ? CGFloat.zero : Layout.iconSize
        let spacing = iconWidth > 0 && !titleField.stringValue.isEmpty ? Layout.contentSpacing : 0
        let availableWidth = max(0, bounds.width - Layout.horizontalInset * 2)
        let maxTitleWidth = max(0, availableWidth - iconWidth - spacing)
        let titleSize = measuredTitleSize(maxWidth: maxTitleWidth)
        let groupWidth = min(availableWidth, iconWidth + spacing + titleSize.width)
        let groupStartX = max(Layout.horizontalInset, round((bounds.width - groupWidth) / 2))

        iconLayer.frame = NSRect(
            x: groupStartX,
            y: round((bounds.height - Layout.iconSize) / 2),
            width: iconWidth,
            height: iconWidth
        )

        titleField.frame = NSRect(
            x: groupStartX + iconWidth + spacing,
            y: round((bounds.height - titleSize.height) / 2),
            width: titleSize.width,
            height: titleSize.height
        )
    }

    private func measuredTitleSize(maxWidth: CGFloat) -> NSSize {
        let font = titleField.font ?? .systemFont(ofSize: 13, weight: .bold)
        let rawSize = (titleField.stringValue as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: Layout.panelSize.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).size
        return NSSize(
            width: min(maxWidth, ceil(rawSize.width)),
            height: ceil(rawSize.height)
        )
    }

    private func positionPanel() {
        guard let screen = panel.isVisible ? (panel.screen ?? preferredScreen()) : preferredScreen() else {
            return
        }
        panel.setFrame(frameForAnchoredPosition(on: screen), display: false)
        iconLayer.contentsScale = screen.backingScaleFactor
    }

    private func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func frameForAnchoredPosition(on screen: NSScreen) -> NSRect {
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let hasBottomDock = visibleFrame.minY > fullFrame.minY + 1
        let originY = hasBottomDock
            ? visibleFrame.minY + Layout.dockClearance
            : fullFrame.minY + Layout.bottomMargin
        let originX = fullFrame.midX - Layout.panelSize.width / 2
        return NSRect(origin: NSPoint(x: originX, y: originY), size: Layout.panelSize)
    }
}

private final class FloatingBallButton: NSButton {
    var onPrimaryTap: (() -> Void)?
    var onSecondaryTap: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        _ = event
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        onPrimaryTap?()
    }

    override func rightMouseUp(with event: NSEvent) {
        _ = event
        onSecondaryTap?()
    }
}
#else
import Common

public final class FloatingBallWindow {
    public var onTap: (() -> Void)?
    public var onSecondaryTap: (() -> Void)?
    public var onMoved: ((CGPoint) -> Void)?
    public private(set) var state: RecordingState = .idle

    public init() {}

    public func show() {}

    public func frameInScreen() -> CGRect { .zero }

    public func setState(_ nextState: RecordingState) {
        state = nextState
    }

    public func setProcessingProgress(_ progress: Double) {
        _ = progress
    }

    public func refreshDisplay() {}
}
#endif
