import AppKit
import QuartzCore
import Settings
import ASRAdapter
import TextProcessor

private final class ShortcutEnabledTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let action: Selector?
        switch key {
        case "v":
            action = #selector(NSText.paste(_:))
        case "c":
            action = #selector(NSText.copy(_:))
        case "x":
            action = #selector(NSText.cut(_:))
        case "a":
            action = #selector(NSResponder.selectAll(_:))
        case "z":
            action = flags.contains(.shift) ? #selector(UndoManager.redo) : #selector(UndoManager.undo)
        case "y":
            action = #selector(UndoManager.redo)
        default:
            action = nil
        }

        guard let action else {
            return super.performKeyEquivalent(with: event)
        }

        if NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ShortcutEnabledSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let action: Selector?
        switch key {
        case "v":
            action = #selector(NSText.paste(_:))
        case "c":
            action = #selector(NSText.copy(_:))
        case "x":
            action = #selector(NSText.cut(_:))
        case "a":
            action = #selector(NSResponder.selectAll(_:))
        case "z":
            action = flags.contains(.shift) ? #selector(UndoManager.redo) : #selector(UndoManager.undo)
        case "y":
            action = #selector(UndoManager.redo)
        default:
            action = nil
        }

        guard let action else {
            return super.performKeyEquivalent(with: event)
        }

        if NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private struct APISettingsDraft {
    var endpoint: String
    var appKey: String
    var apiKey: String
    var model: String
    var resourceID: String
    var pricePerMinute: String
}

private enum APISettingsModalResult {
    case cancel
    case save(APISettingsDraft)
}

private struct APIConnectionTestFeedback {
    enum Kind {
        case idle
        case testing
        case success
        case failure
    }

    var kind: Kind
    var title: String
    var detail: String
}

@MainActor
private final class APISettingsModalController: NSObject, NSWindowDelegate {
    private let validateDraft: (APISettingsDraft, Bool) -> String?
    private let runConnectionTest: (APISettingsDraft, @Sendable @escaping (APIConnectionTestFeedback) -> Void) -> Void

    private(set) var result: APISettingsModalResult = .cancel

    private let panel: NSPanel
    private let endpointField: ShortcutEnabledTextField
    private let appKeyField: ShortcutEnabledTextField
    private let keyField: ShortcutEnabledSecureTextField
    private let modelField: ShortcutEnabledTextField
    private let resourceIDField: ShortcutEnabledTextField
    private let priceField: ShortcutEnabledTextField
    private let statusContainer = NSView(frame: .zero)
    private let statusIconView = NSImageView(frame: .zero)
    private let statusSpinner = NSProgressIndicator(frame: .zero)
    private let statusTitleLabel = NSTextField(labelWithString: "")
    private let statusDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private var editableControls: [NSControl] = []
    private var activeTestID: UUID?

    init(
        initialDraft: APISettingsDraft,
        validateDraft: @escaping (APISettingsDraft, Bool) -> String?,
        runConnectionTest: @escaping (APISettingsDraft, @Sendable @escaping (APIConnectionTestFeedback) -> Void) -> Void
    ) {
        self.validateDraft = validateDraft
        self.runConnectionTest = runConnectionTest

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 630),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "API设置"
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .visible
        panel.isMovableByWindowBackground = true

        endpointField = ShortcutEnabledTextField(string: initialDraft.endpoint)
        appKeyField = ShortcutEnabledTextField(string: initialDraft.appKey)
        keyField = ShortcutEnabledSecureTextField(string: initialDraft.apiKey)
        modelField = ShortcutEnabledTextField(string: initialDraft.model)
        resourceIDField = ShortcutEnabledTextField(string: initialDraft.resourceID)
        priceField = ShortcutEnabledTextField(string: initialDraft.pricePerMinute)

        super.init()

        panel.delegate = self
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        endpointField.placeholderString = "推荐: wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async 或 https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
        appKeyField.placeholderString = "豆包 APP ID（AppKey）"
        keyField.placeholderString = "Access Key / Token"
        modelField.placeholderString = "whisper-1 或 bigmodel"
        resourceIDField.placeholderString = "volc.bigasr.auc_turbo（豆包默认）"
        priceField.placeholderString = "0.00"

        editableControls = [
            endpointField,
            appKeyField,
            keyField,
            modelField,
            resourceIDField,
            priceField
        ]
        editableControls.forEach {
            $0.font = .systemFont(ofSize: 13)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.wantsLayer = true
        statusContainer.layer?.cornerRadius = 14
        statusContainer.layer?.borderWidth = 1

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        statusIconView.contentTintColor = .secondaryLabelColor

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false

        statusTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDetailLabel.font = .systemFont(ofSize: 11)
        statusDetailLabel.textColor = .secondaryLabelColor
        statusDetailLabel.maximumNumberOfLines = 0
        statusDetailLabel.preferredMaxLayoutWidth = 290
        statusDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        testButton.target = self
        testButton.action = #selector(handleTestButton)
        testButton.bezelStyle = .rounded

        cancelButton.target = self
        cancelButton.action = #selector(handleCancelButton)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.target = self
        saveButton.action = #selector(handleSaveButton)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        buildUI()
        renderStatus(
            APIConnectionTestFeedback(
                kind: .idle,
                title: "还没测试",
                detail: "填写完信息后点“测试连接”，我们会用一段系统测试语音验证这个接口是否真的可用。"
            )
        )
    }

    func runModal() -> APISettingsModalResult {
        panel.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }

    func windowWillClose(_ notification: Notification) {
        activeTestID = nil
        if NSApp.modalWindow === panel {
            NSApp.stopModal()
        }
    }

    private func buildUI() {
        let contentView = FlippedView(frame: panel.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        if let logoURL = Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
           let logoImage = NSImage(contentsOf: logoURL) {
            let logoWrap = NSView(frame: .zero)
            logoWrap.translatesAutoresizingMaskIntoConstraints = false
            logoWrap.wantsLayer = true
            logoWrap.layer?.cornerRadius = 22
            logoWrap.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            logoWrap.layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
            logoWrap.layer?.shadowOpacity = 1
            logoWrap.layer?.shadowRadius = 12
            logoWrap.layer?.shadowOffset = NSSize(width: 0, height: -3)

            let imageView = NSImageView(image: logoImage)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            logoWrap.addSubview(imageView)

            NSLayoutConstraint.activate([
                logoWrap.widthAnchor.constraint(equalToConstant: 76),
                logoWrap.heightAnchor.constraint(equalToConstant: 76),
                imageView.leadingAnchor.constraint(equalTo: logoWrap.leadingAnchor, constant: 10),
                imageView.trailingAnchor.constraint(equalTo: logoWrap.trailingAnchor, constant: -10),
                imageView.topAnchor.constraint(equalTo: logoWrap.topAnchor, constant: 10),
                imageView.bottomAnchor.constraint(equalTo: logoWrap.bottomAnchor, constant: -10)
            ])
            rootStack.addArrangedSubview(logoWrap)
        }

        let hintLabel = NSTextField(
            wrappingLabelWithString: "通用模式：http/https 的 POST JSON（model、audio_base64、audio_format）。豆包适配：支持 openspeech.bytedance.com 下的 /api/v3/sauc/bigmodel(_async) 或 /api/v3/auc/bigmodel/*，程序会自动走豆包鉴权头与文件识别接口。"
        )
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.maximumNumberOfLines = 0
        hintLabel.preferredMaxLayoutWidth = 380
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusTextStack = NSStackView(views: [statusTitleLabel, statusDetailLabel])
        statusTextStack.orientation = .vertical
        statusTextStack.alignment = .leading
        statusTextStack.spacing = 4
        statusTextStack.translatesAutoresizingMaskIntoConstraints = false

        statusContainer.addSubview(statusIconView)
        statusContainer.addSubview(statusSpinner)
        statusContainer.addSubview(statusTextStack)

        NSLayoutConstraint.activate([
            statusIconView.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 14),
            statusIconView.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 14),
            statusIconView.widthAnchor.constraint(equalToConstant: 20),
            statusIconView.heightAnchor.constraint(equalToConstant: 20),

            statusSpinner.centerXAnchor.constraint(equalTo: statusIconView.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: statusIconView.centerYAnchor),

            statusTextStack.leadingAnchor.constraint(equalTo: statusIconView.trailingAnchor, constant: 10),
            statusTextStack.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -14),
            statusTextStack.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 12),
            statusTextStack.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -12)
        ])

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let buttonSpacer = NSView(frame: .zero)
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(buttonSpacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(testButton)
        buttonRow.addArrangedSubview(saveButton)

        rootStack.addArrangedSubview(makeFieldGroup(title: "接口 URL", field: endpointField))
        rootStack.addArrangedSubview(makeFieldGroup(title: "APP ID（豆包可填）", field: appKeyField))
        rootStack.addArrangedSubview(makeFieldGroup(title: "Access Key / API Key", field: keyField))
        rootStack.addArrangedSubview(makeFieldGroup(title: "模型名", field: modelField))
        rootStack.addArrangedSubview(makeFieldGroup(title: "资源 ID（豆包可填）", field: resourceIDField))
        rootStack.addArrangedSubview(makeFieldGroup(title: "单价（元/分钟，用于估算）", field: priceField))
        rootStack.addArrangedSubview(hintLabel)
        rootStack.addArrangedSubview(statusContainer)
        rootStack.addArrangedSubview(buttonRow)

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),

            hintLabel.widthAnchor.constraint(equalToConstant: 380),
            statusContainer.widthAnchor.constraint(equalToConstant: 380),
            statusContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 86),
            buttonRow.widthAnchor.constraint(equalToConstant: 380)
        ])
    }

    private func makeFieldGroup(title: String, field: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)

        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return stack
    }

    private func currentDraft() -> APISettingsDraft {
        APISettingsDraft(
            endpoint: endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            appKey: appKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            resourceID: resourceIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            pricePerMinute: priceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func renderStatus(_ feedback: APIConnectionTestFeedback) {
        statusTitleLabel.stringValue = feedback.title
        statusDetailLabel.stringValue = feedback.detail

        switch feedback.kind {
        case .idle:
            statusContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            statusContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
            statusTitleLabel.textColor = .labelColor
            statusDetailLabel.textColor = .secondaryLabelColor
            statusIconView.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: nil)
            statusIconView.contentTintColor = .secondaryLabelColor
            statusIconView.isHidden = false
            statusSpinner.stopAnimation(nil)
        case .testing:
            statusContainer.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            statusContainer.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
            statusTitleLabel.textColor = .labelColor
            statusDetailLabel.textColor = .secondaryLabelColor
            statusIconView.isHidden = true
            statusSpinner.startAnimation(nil)
        case .success:
            statusContainer.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.10).cgColor
            statusContainer.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.28).cgColor
            statusTitleLabel.textColor = NSColor.systemGreen.blended(withFraction: 0.25, of: .labelColor) ?? .systemGreen
            statusDetailLabel.textColor = .secondaryLabelColor
            statusIconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            statusIconView.contentTintColor = .systemGreen
            statusIconView.isHidden = false
            statusSpinner.stopAnimation(nil)
        case .failure:
            statusContainer.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
            statusContainer.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.28).cgColor
            statusTitleLabel.textColor = NSColor.systemOrange.blended(withFraction: 0.25, of: .labelColor) ?? .systemOrange
            statusDetailLabel.textColor = .secondaryLabelColor
            statusIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            statusIconView.contentTintColor = .systemOrange
            statusIconView.isHidden = false
            statusSpinner.stopAnimation(nil)
        }
    }

    private func setTesting(_ isTesting: Bool) {
        editableControls.forEach { $0.isEnabled = !isTesting }
        saveButton.isEnabled = !isTesting
        testButton.isEnabled = !isTesting
    }

    private func finish(with result: APISettingsModalResult) {
        self.result = result
        activeTestID = nil
        if NSApp.modalWindow === panel {
            NSApp.stopModal()
        }
        panel.orderOut(nil)
    }

    @objc
    private func handleSaveButton() {
        let draft = currentDraft()
        if let message = validateDraft(draft, true) {
            renderStatus(
                APIConnectionTestFeedback(
                    kind: .failure,
                    title: "保存前请先检查配置",
                    detail: message
                )
            )
            return
        }
        finish(with: .save(draft))
    }

    @objc
    private func handleCancelButton() {
        finish(with: .cancel)
    }

    @objc
    private func handleTestButton() {
        let draft = currentDraft()
        if let message = validateDraft(draft, false) {
            renderStatus(
                APIConnectionTestFeedback(
                    kind: .failure,
                    title: "还差一点",
                    detail: message
                )
            )
            return
        }

        let testID = UUID()
        activeTestID = testID
        setTesting(true)
        renderStatus(
            APIConnectionTestFeedback(
                kind: .testing,
                title: "正在测试连接…",
                detail: "我们正在发送一段系统测试语音，请稍等几秒，看看这个接口能不能真正跑通。"
            )
        )

        runConnectionTest(draft) { [weak self] feedback in
            DispatchQueue.main.async {
                guard let self, self.activeTestID == testID else { return }
                self.activeTestID = nil
                self.setTesting(false)
                self.renderStatus(feedback)
            }
        }
    }
}

private final class HoverableSidebarRowView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}

private enum SettingsPanelPalette {
    static let accent = NSColor(calibratedRed: 0.33, green: 0.83, blue: 0.27, alpha: 1)
    static let accentStrong = NSColor(calibratedRed: 0.26, green: 0.71, blue: 0.22, alpha: 1)
    static let canvas = NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.94, alpha: 1)
    static let sidebarFill = NSColor.white.withAlphaComponent(0.72)
    static let contentFill = NSColor(calibratedWhite: 1, alpha: 0.96)
    static let cardFill = NSColor.white.withAlphaComponent(0.92)
    static let secondaryCardFill = NSColor(calibratedRed: 0.97, green: 0.99, blue: 0.97, alpha: 0.96)
    static let border = NSColor(calibratedRed: 0.84, green: 0.90, blue: 0.84, alpha: 0.95)
    static let chartTrack = NSColor(calibratedRed: 0.89, green: 0.94, blue: 0.88, alpha: 1)
}

private final class OverviewMetricCardView: NSView {
    let valueLabel = NSTextField(labelWithString: "--")
    let detailLabel = NSTextField(wrappingLabelWithString: "")

    init(title: String, iconName: String, accentColor: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = SettingsPanelPalette.cardFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = SettingsPanelPalette.border.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.06).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        let iconBubble = NSView(frame: .zero)
        iconBubble.translatesAutoresizingMaskIntoConstraints = false
        iconBubble.wantsLayer = true
        iconBubble.layer?.cornerRadius = 14
        iconBubble.layer?.backgroundColor = accentColor.withAlphaComponent(0.14).cgColor

        let iconView = NSImageView(frame: .zero)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        iconView.contentTintColor = accentColor
        iconBubble.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.font = .systemFont(ofSize: 24, weight: .bold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping

        let titleRow = NSStackView(views: [iconBubble, titleLabel, NSView()])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleRow, valueLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

            iconBubble.widthAnchor.constraint(equalToConstant: 28),
            iconBubble.heightAnchor.constraint(equalToConstant: 28),
            iconView.centerXAnchor.constraint(equalTo: iconBubble.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBubble.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class WeeklyActivityChartView: NSView {
    struct Point {
        let label: String
        let count: Int
    }

    var points: [Point] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = SettingsPanelPalette.secondaryCardFill.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 172)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let chartBounds = bounds.insetBy(dx: 14, dy: 12)
        guard chartBounds.width > 0, chartBounds.height > 0 else { return }

        let topInset: CGFloat = 20
        let bottomInset: CGFloat = 24
        let barArea = NSRect(
            x: chartBounds.minX,
            y: chartBounds.minY + topInset,
            width: chartBounds.width,
            height: max(42, chartBounds.height - topInset - bottomInset)
        )

        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: barArea.minX, y: barArea.maxY))
        baseline.line(to: NSPoint(x: barArea.maxX, y: barArea.maxY))
        NSColor.separatorColor.withAlphaComponent(0.18).setStroke()
        baseline.lineWidth = 1
        baseline.stroke()

        let points = self.points.isEmpty
            ? (0..<7).map { _ in Point(label: "--", count: 0) }
            : self.points
        let maxCount = max(points.map(\.count).max() ?? 0, 1)
        let columnWidth = barArea.width / CGFloat(max(points.count, 1))
        let barWidth = min(28, max(14, columnWidth * 0.5))
        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for (index, point) in points.enumerated() {
            let x = barArea.minX + CGFloat(index) * columnWidth + (columnWidth - barWidth) / 2
            let ratio = CGFloat(point.count) / CGFloat(maxCount)
            let visibleHeight = point.count > 0
                ? max(16, ratio * (barArea.height - 18))
                : 6
            let trackRect = NSRect(x: x, y: barArea.minY, width: barWidth, height: barArea.height)
            let barRect = NSRect(
                x: x,
                y: barArea.maxY - visibleHeight,
                width: barWidth,
                height: visibleHeight
            )

            let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            SettingsPanelPalette.chartTrack.setFill()
            trackPath.fill()

            let barColor = point.count > 0
                ? SettingsPanelPalette.accentStrong
                : SettingsPanelPalette.accent.withAlphaComponent(0.24)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            barColor.setFill()
            barPath.fill()

            let countString = NSAttributedString(string: "\(point.count)", attributes: countAttributes)
            let countSize = countString.size()
            countString.draw(
                at: NSPoint(
                    x: x + (barWidth - countSize.width) / 2,
                    y: max(chartBounds.minY, barArea.minY - countSize.height - 6)
                )
            )

            let labelString = NSAttributedString(string: point.label, attributes: labelAttributes)
            let labelSize = labelString.size()
            labelString.draw(
                at: NSPoint(
                    x: x + (barWidth - labelSize.width) / 2,
                    y: barArea.maxY + 6
                )
            )
        }
    }
}

private final class AdaptiveCardGridView: NSView {
    private let spacing: CGFloat
    private let baselineWidth: CGFloat
    private let baselineColumns: Int
    private let maxColumns: Int

    override var isFlipped: Bool { true }

    init(
        views: [NSView],
        baselineWidth: CGFloat,
        baselineColumns: Int = 3,
        maxColumns: Int = 6,
        spacing: CGFloat = 12
    ) {
        self.spacing = spacing
        self.baselineWidth = baselineWidth
        self.baselineColumns = max(1, baselineColumns)
        self.maxColumns = max(self.baselineColumns, maxColumns)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for view in views {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)
        if abs(previousWidth - newSize.width) > 0.5 {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let result = computeLayout(for: resolvedAvailableWidth(), applyingFrames: true)
        if abs(result.height - intrinsicContentSize.height) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let layout = computeLayout(for: resolvedAvailableWidth(), applyingFrames: false)
        return NSSize(width: NSView.noIntrinsicMetric, height: layout.height)
    }

    private struct LayoutResult {
        let height: CGFloat
    }

    private func resolvedAvailableWidth() -> CGFloat {
        let width = bounds.width > 0 ? bounds.width : baselineWidth
        return max(width, 1)
    }

    private func computeLayout(for availableWidth: CGFloat, applyingFrames: Bool) -> LayoutResult {
        let visibleSubviews = subviews.filter { !$0.isHidden }
        guard !visibleSubviews.isEmpty else {
            return LayoutResult(height: 0)
        }

        let referenceItemWidth = max(
            180,
            (baselineWidth - spacing * CGFloat(max(0, baselineColumns - 1))) / CGFloat(baselineColumns)
        )
        let rawColumns = Int(floor((availableWidth + spacing) / (referenceItemWidth + spacing)))
        let columnCount = max(1, min(maxColumns, rawColumns))
        let itemWidth = max(
            1,
            (availableWidth - spacing * CGFloat(max(0, columnCount - 1))) / CGFloat(columnCount)
        )

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var currentColumn = 0

        for view in visibleSubviews {
            let itemHeight = measuredHeight(for: view, width: itemWidth)
            if applyingFrames {
                view.frame = NSRect(x: currentX, y: currentY, width: itemWidth, height: itemHeight)
            }

            currentRowHeight = max(currentRowHeight, itemHeight)
            currentColumn += 1

            if currentColumn >= columnCount {
                currentColumn = 0
                currentX = 0
                currentY += currentRowHeight + spacing
                currentRowHeight = 0
            } else {
                currentX += itemWidth + spacing
            }
        }

        if currentColumn > 0 {
            currentY += currentRowHeight
        } else {
            currentY = max(0, currentY - spacing)
        }

        return LayoutResult(height: ceil(currentY))
    }

    private func measuredHeight(for view: NSView, width: CGFloat) -> CGFloat {
        let previousFrame = view.frame
        view.frame = NSRect(x: 0, y: 0, width: width, height: max(previousFrame.height, 1))
        view.layoutSubtreeIfNeeded()
        let height = max(view.fittingSize.height, 1)
        view.frame = previousFrame
        return ceil(height)
    }
}

@MainActor
final class SettingsPanelController: NSWindowController, NSWindowDelegate {
    private struct PanelPlacement {
        let startOrigin: NSPoint
        let finalOrigin: NSPoint
    }

    private enum SettingsPage: Int, CaseIterable {
        case home
        case history
        case dictionary

        var title: String {
            switch self {
            case .home:
                return "概览"
            case .history:
                return "历史记录"
            case .dictionary:
                return "词库"
            }
        }

        var subtitle: String {
            switch self {
            case .home:
                return "常用设置、状态摘要和近 7 天输入趋势"
            case .history:
                return "日志统计、缓存管理与输入明细"
            case .dictionary:
                return "语气词过滤与个人词库管理"
            }
        }
    }

    private enum HistoryDurationUnit: String {
        case minutes
        case hours

        var title: String {
            switch self {
            case .minutes:
                return "分"
            case .hours:
                return "小时"
            }
        }

        static func fromStored(_ raw: String) -> HistoryDurationUnit {
            switch raw {
            case "hours":
                return .hours
            case "seconds", "minutes":
                return .minutes
            default:
                return .minutes
            }
        }
    }

    private enum HistoryRetentionPolicy: String, CaseIterable {
        case never
        case h24
        case w1
        case m1
        case forever

        var title: String {
            switch self {
            case .never:
                return "永不"
            case .h24:
                return "24小时"
            case .w1:
                return "1周"
            case .m1:
                return "1个月"
            case .forever:
                return "永远"
            }
        }

        var retentionDays: Int? {
            switch self {
            case .never:
                return 0
            case .h24:
                return 1
            case .w1:
                return 7
            case .m1:
                return 30
            case .forever:
                return nil
            }
        }

        static func fromStored(_ raw: String) -> HistoryRetentionPolicy {
            switch raw {
            case "never":
                return .never
            case "24h", "h24":
                return .h24
            case "1w", "w1":
                return .w1
            case "1m", "m1":
                return .m1
            case "forever":
                return .forever
            default:
                return .forever
            }
        }
    }

    private enum LexiconCategoryFilter: Int {
        case all = 0
        case learned = 1
        case manual = 2
    }

    private struct HistoryInputRecord {
        let id: String
        let timestamp: Date
        let text: String
    }

    private let settings: SettingsStore
    private let onModelChanged: (ASRModelSize) -> Void
    private let onChineseScriptModeChanged: (ChineseScriptMode) -> Void
    private let onRecognitionModeChanged: (RecognitionMode) -> Void
    private let onReapplyPermissions: () -> Void
    private let fillerBlacklistProvider: () -> [String]
    private let onFillerBlacklistChanged: ([String]) -> Void
    private let onClearPersonalLexicon: () -> Void
    private let allLexiconProvider: () -> [String]
    private let learnedLexiconProvider: () -> [String]
    private let manualLexiconProvider: () -> [String]
    private let onAddManualLexiconTerms: ([String]) -> Void
    private let onDeleteManualLexiconTerm: (String) -> Void
    private let onOpenAudioCacheDirectory: () -> Void
    private let onClearAudioCacheFiles: () -> Int
    private let onClearAllHistory: () -> Void
    private let onShortcutSettingsChanged: () -> Void

    private let removeFillersButton = NSButton(checkboxWithTitle: "自动删除语气词", target: nil, action: nil)
    private let autoPunctuationButton = NSButton(checkboxWithTitle: "自动标点和分段", target: nil, action: nil)
    private let inputCompletionSoundButton = NSButton(checkboxWithTitle: "输入完成提示音", target: nil, action: nil)
    private let preserveCloudRawPunctuationButton = NSButton(checkboxWithTitle: "保留云端原始标点", target: nil, action: nil)
    private let adaptivePunctuationButton = NSButton(checkboxWithTitle: "启用自适应标点（学习画像）", target: nil, action: nil)
    private let punctuationLearningButton = NSButton(checkboxWithTitle: "记录并学习标点回改（本地）", target: nil, action: nil)
    private let punctuationDebugLogButton = NSButton(checkboxWithTitle: "标点调试日志（本地）", target: nil, action: nil)
    private let lexiconHitVisibilityButton = NSButton(checkboxWithTitle: "显示词库命中详情（调试）", target: nil, action: nil)
    private let fillerBlacklistField = NSTextField(frame: .zero)
    private let saveBlacklistButton = NSButton(title: "保存语气词黑名单", target: nil, action: nil)
    private let manualLexiconInputField = NSTextField(frame: .zero)
    private let manualLexiconAddButton = NSButton(title: "新词", target: nil, action: nil)
    private let lexiconCategoryControl = NSSegmentedControl(
        labels: ["全部", "学习词库", "手动词库"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let lexiconGrid = LexiconFlowLayout()

    private let modelPopup = NSSegmentedControl(
        labels: ASRModelSize.allCases.map(\.rawValue),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let recognitionModePopup = NSSegmentedControl(
        labels: ["本地", "云端", "混合"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let livePreviewEnabledPopup = NSSegmentedControl(
        labels: ["开启", "关闭"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let livePreviewSourcePopup = NSSegmentedControl(
        labels: ["本地", "云端"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let liveOutputPopup = NSSegmentedControl(
        labels: ["关闭", "稳定前缀"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let recordingLimitPopup = NSSegmentedControl(
        labels: ["60s", "120s", "180s", "无限制"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let apiSettingsButton = NSButton(title: "API设置", target: nil, action: nil)
    private let localASRStatusLabel = NSTextField(labelWithString: "")
    private let localASRDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let localASRActivityIndicator = NSProgressIndicator(frame: .zero)
    private let localASRPrimaryButton = NSButton(title: "下载本地模型", target: nil, action: nil)
    private let localASRDeleteButton = NSButton(title: "删除本地模型", target: nil, action: nil)
    private let punctuationStylePopup = NSSegmentedControl(
        labels: ["自动", "中文", "English"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sentenceEndingPunctuationPopup = NSSegmentedControl(
        labels: ["开启", "关闭"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let chineseScriptPopup = NSSegmentedControl(
        labels: ["简体中文", "繁体中文"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let reapplyPermissionsButton = NSButton(title: "重新申请权限", target: nil, action: nil)
    private let quitButton = NSButton(title: "退出 MyType", target: nil, action: nil)
    private let cloudLogSummaryLabel = NSTextField(labelWithString: "暂无请求日志")
    private let viewCloudLogsButton = NSButton(title: "查看", target: nil, action: nil)
    private let historyRetentionPopup = NSSegmentedControl(
        labels: HistoryRetentionPolicy.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let historyDurationValueLabel = NSTextField(labelWithString: "--")
    private let historyDurationDetailLabel = NSTextField(labelWithString: "暂无记录")
    private let historyCharactersValueLabel = NSTextField(labelWithString: "--")
    private let historyCharactersDetailLabel = NSTextField(labelWithString: "暂无记录")
    private let historyDurationUnitPopup = NSSegmentedControl(
        labels: [HistoryDurationUnit.minutes.title, HistoryDurationUnit.hours.title],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let historyOpenAudioCacheDirectoryButton = NSButton(title: "打开音频文件存放目录", target: nil, action: nil)
    private let historyClearAudioCacheButton = NSButton(title: "立即清除音频缓存文件", target: nil, action: nil)
    private let historyClearAllRecordsButton = NSButton(title: "清除所有历史", target: nil, action: nil)
    private let overviewModePillLabel = NSTextField(labelWithString: "")
    private let overviewShortcutPillLabel = NSTextField(labelWithString: "")
    private let overviewPreviewPillLabel = NSTextField(labelWithString: "")
    private let overviewAPIUsageCard = OverviewMetricCardView(
        title: "API 用量",
        iconName: "antenna.radiowaves.left.and.right",
        accentColor: NSColor(calibratedRed: 0.24, green: 0.69, blue: 0.35, alpha: 1)
    )
    private let overviewDurationCard = OverviewMetricCardView(
        title: "使用时长",
        iconName: "clock.badge.checkmark",
        accentColor: NSColor(calibratedRed: 0.20, green: 0.66, blue: 0.73, alpha: 1)
    )
    private let overviewShortcutCard = OverviewMetricCardView(
        title: "快捷键",
        iconName: "command",
        accentColor: NSColor(calibratedRed: 0.91, green: 0.58, blue: 0.18, alpha: 1)
    )
    private let overviewConfigCard = OverviewMetricCardView(
        title: "当前配置",
        iconName: "slider.horizontal.3",
        accentColor: NSColor(calibratedRed: 0.31, green: 0.49, blue: 0.85, alpha: 1)
    )
    private let overviewWeeklyChartView = WeeklyActivityChartView(frame: .zero)

    private let historyListContainer = NSStackView(frame: .zero)
    private let historyPaginationInfoLabel = NSTextField(labelWithString: "")
    private let historyPreviousPageButton = NSButton(title: "上一页", target: nil, action: nil)
    private let historyNextPageButton = NSButton(title: "下一页", target: nil, action: nil)
    private var historyInputRecords: [HistoryInputRecord] = []
    private var historyInputPageIndex = 0
    private let shortcutInputModeControl = NSSegmentedControl(
        labels: [ShortcutInputMode.holdToTalk.title, ShortcutInputMode.continuous.title],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let primaryShortcutValueLabel = NSTextField(labelWithString: "")
    private let primaryShortcutSetButton = NSButton(title: "设置", target: nil, action: nil)
    private let primaryShortcutClearButton = NSButton(title: "清除", target: nil, action: nil)
    private var cloudLogViewer: CloudLogViewerWindowController?
    private var transientSuccessPopover: NSPopover?
    private var shortcutCaptureLocalMonitor: Any?
    private enum ShortcutCaptureTarget {
        case primary
    }
    private var shortcutCaptureTarget: ShortcutCaptureTarget?
    private let contentTitleLabel = NSTextField(labelWithString: "")
    private let contentSubtitleLabel = NSTextField(labelWithString: "")
    private let pageTabView = NSTabView(frame: .zero)
    private let homeNavButton = NSButton(title: "首页", target: nil, action: nil)
    private let historyNavButton = NSButton(title: "历史记录", target: nil, action: nil)
    private let dictionaryNavButton = NSButton(title: "词库", target: nil, action: nil)
    private var pageButtons: [SettingsPage: NSButton] = [:]
    private var pageRows: [SettingsPage: HoverableSidebarRowView] = [:]
    private var currentPage: SettingsPage?
    private var hoveredPage: SettingsPage?
    private var currentLexiconFilter: LexiconCategoryFilter = .all
    private var historyListNeedsReload = true
    private static let historyInputRecordsPerPage = 30
    private static let maxParsedHistoryRecords = 5000
    private static let overviewGridBaselineWidth: CGFloat = 848
    private static let historyDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let pipelinePerformanceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(
        settings: SettingsStore,
        onModelChanged: @escaping (ASRModelSize) -> Void,
        onChineseScriptModeChanged: @escaping (ChineseScriptMode) -> Void,
        onRecognitionModeChanged: @escaping (RecognitionMode) -> Void,
        onReapplyPermissions: @escaping () -> Void,
        fillerBlacklistProvider: @escaping () -> [String],
        onFillerBlacklistChanged: @escaping ([String]) -> Void,
        onClearPersonalLexicon: @escaping () -> Void,
        allLexiconProvider: @escaping () -> [String],
        learnedLexiconProvider: @escaping () -> [String],
        manualLexiconProvider: @escaping () -> [String],
        onAddManualLexiconTerms: @escaping ([String]) -> Void,
        onDeleteManualLexiconTerm: @escaping (String) -> Void,
        onOpenAudioCacheDirectory: @escaping () -> Void,
        onClearAudioCacheFiles: @escaping () -> Int,
        onClearAllHistory: @escaping () -> Void,
        onShortcutSettingsChanged: @escaping () -> Void
    ) {
        self.settings = settings
        self.onModelChanged = onModelChanged
        self.onChineseScriptModeChanged = onChineseScriptModeChanged
        self.onRecognitionModeChanged = onRecognitionModeChanged
        self.onReapplyPermissions = onReapplyPermissions
        self.fillerBlacklistProvider = fillerBlacklistProvider
        self.onFillerBlacklistChanged = onFillerBlacklistChanged
        self.onClearPersonalLexicon = onClearPersonalLexicon
        self.allLexiconProvider = allLexiconProvider
        self.learnedLexiconProvider = learnedLexiconProvider
        self.manualLexiconProvider = manualLexiconProvider
        self.onAddManualLexiconTerms = onAddManualLexiconTerms
        self.onDeleteManualLexiconTerm = onDeleteManualLexiconTerm
        self.onOpenAudioCacheDirectory = onOpenAudioCacheDirectory
        self.onClearAudioCacheFiles = onClearAudioCacheFiles
        self.onClearAllHistory = onClearAllHistory
        self.onShortcutSettingsChanged = onShortcutSettingsChanged

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "MyType 设置"
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 980, height: 640)

        super.init(window: panel)
        panel.delegate = self
        configureUI(in: panel)
        observeLocalASRState()
        syncFromSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPanel(near anchorRect: NSRect?) {
        guard let window else { return }
        syncFromSettings()

        if window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        if let anchorRect {
            let placement = placement(for: window, near: anchorRect)
            animatePresentation(window: window, startOrigin: placement.startOrigin, finalOrigin: placement.finalOrigin)
        } else {
            window.center()
            let final = window.frame.origin
            let start = NSPoint(x: final.x, y: final.y - 12)
            animatePresentation(window: window, startOrigin: start, finalOrigin: final)
        }
    }

    private func animatePresentation(window: NSWindow, startOrigin: NSPoint, finalOrigin: NSPoint) {
        let size = window.frame.size
        let startFrame = NSRect(origin: startOrigin, size: size)
        let finalFrame = NSRect(origin: finalOrigin, size: size)

        window.setFrame(startFrame, display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    private func placement(for window: NSWindow, near anchorRect: NSRect) -> PanelPlacement {
        let screen = screenFor(anchorRect: anchorRect) ?? NSScreen.main
        guard let screen else {
            return PanelPlacement(startOrigin: window.frame.origin, finalOrigin: window.frame.origin)
        }

        let visible = screen.visibleFrame
        let panelSize = window.frame.size
        let margin: CGFloat = 12

        // Prefer placing on the right side of floating ball, fallback to left.
        let rightX = anchorRect.maxX + margin
        let leftX = anchorRect.minX - margin - panelSize.width
        let canPlaceRight = rightX + panelSize.width <= visible.maxX - margin
        let canPlaceLeft = leftX >= visible.minX + margin

        let x: CGFloat
        if canPlaceRight {
            x = rightX
        } else if canPlaceLeft {
            x = leftX
        } else {
            x = clamp(
                anchorRect.midX - panelSize.width / 2,
                min: visible.minX + margin,
                max: visible.maxX - panelSize.width - margin
            )
        }

        let y = clamp(
            anchorRect.midY - panelSize.height / 2,
            min: visible.minY + margin,
            max: visible.maxY - panelSize.height - margin
        )

        let final = NSPoint(x: x, y: y)
        let start = startOrigin(
            finalOrigin: final,
            panelSize: panelSize,
            anchorRect: anchorRect,
            visibleFrame: visible
        )
        return PanelPlacement(startOrigin: start, finalOrigin: final)
    }

    private func screenFor(anchorRect: NSRect) -> NSScreen? {
        let center = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        return NSScreen.screens.first { $0.visibleFrame.contains(center) }
    }

    private func startOrigin(
        finalOrigin: NSPoint,
        panelSize: NSSize,
        anchorRect: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint {
        let panelCenter = NSPoint(
            x: finalOrigin.x + panelSize.width / 2,
            y: finalOrigin.y + panelSize.height / 2
        )
        let anchorCenter = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        var dx = anchorCenter.x - panelCenter.x
        var dy = anchorCenter.y - panelCenter.y
        var length = sqrt(dx * dx + dy * dy)
        if length < 0.001 {
            dx = 0
            dy = -1
            length = 1
        }

        let distance: CGFloat = 16
        let ux = dx / length
        let uy = dy / length
        var start = NSPoint(
            x: finalOrigin.x + ux * distance,
            y: finalOrigin.y + uy * distance
        )

        start.x = clamp(
            start.x,
            min: visibleFrame.minX + 6,
            max: visibleFrame.maxX - panelSize.width - 6
        )
        start.y = clamp(
            start.y,
            min: visibleFrame.minY + 6,
            max: visibleFrame.maxY - panelSize.height - 6
        )
        return start
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private func configureUI(in panel: NSWindow) {
        configureControlTargets()

        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = SettingsPanelPalette.canvas.cgColor
        panel.contentView = root

        let canvas = NSView(frame: .zero)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(canvas)

        let sidebar = makeSidebar()
        let contentArea = makeContentArea()
        let split = NSStackView(views: [sidebar, contentArea])
        split.orientation = .horizontal
        split.alignment = .top
        split.distribution = .fill
        split.spacing = 12
        split.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(split)

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            split.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            split.topAnchor.constraint(equalTo: canvas.topAnchor),
            split.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            sidebar.widthAnchor.constraint(equalToConstant: 244)
        ])

        switchToPage(.home)
    }

    private func configureControlTargets() {
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.segmentStyle = .rounded
        modelPopup.controlSize = .small

        recognitionModePopup.target = self
        recognitionModePopup.action = #selector(recognitionModeChanged)
        recognitionModePopup.segmentStyle = .rounded
        recognitionModePopup.controlSize = .small

        livePreviewEnabledPopup.target = self
        livePreviewEnabledPopup.action = #selector(livePreviewEnabledChanged)
        livePreviewEnabledPopup.segmentStyle = .rounded
        livePreviewEnabledPopup.controlSize = .small
        livePreviewEnabledPopup.toolTip = "录音时在悬浮预览窗显示识别过程；不会提前写入正文。"

        livePreviewSourcePopup.target = self
        livePreviewSourcePopup.action = #selector(livePreviewSourceChanged)
        livePreviewSourcePopup.segmentStyle = .rounded
        livePreviewSourcePopup.controlSize = .small
        livePreviewSourcePopup.toolTip = "仅影响悬浮预览窗里的实时识别来源，不会提前写入正文。"

        liveOutputPopup.target = self
        liveOutputPopup.action = #selector(liveOutputChanged)
        liveOutputPopup.segmentStyle = .rounded
        liveOutputPopup.controlSize = .small
        liveOutputPopup.toolTip = "该实验功能已停用；当前实时预览只显示在悬浮预览窗，不提前写入正文。"

        recordingLimitPopup.target = self
        recordingLimitPopup.action = #selector(recordingLimitChanged)
        recordingLimitPopup.segmentStyle = .rounded
        recordingLimitPopup.controlSize = .small

        apiSettingsButton.target = self
        apiSettingsButton.action = #selector(openAPISettings)
        apiSettingsButton.controlSize = .small
        apiSettingsButton.bezelStyle = .rounded
        styleProminentButton(apiSettingsButton)

        localASRActivityIndicator.style = .spinning
        localASRActivityIndicator.controlSize = .small
        localASRActivityIndicator.isDisplayedWhenStopped = false
        localASRStatusLabel.font = .systemFont(ofSize: 14, weight: .bold)
        localASRStatusLabel.textColor = .labelColor
        localASRDetailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        localASRDetailLabel.textColor = .secondaryLabelColor
        localASRDetailLabel.maximumNumberOfLines = 0

        localASRPrimaryButton.target = self
        localASRPrimaryButton.action = #selector(downloadLocalASRAssets)
        localASRPrimaryButton.controlSize = .small
        localASRPrimaryButton.bezelStyle = .rounded
        styleProminentButton(localASRPrimaryButton)

        localASRDeleteButton.target = self
        localASRDeleteButton.action = #selector(deleteLocalASRAssets)
        localASRDeleteButton.controlSize = .small
        localASRDeleteButton.bezelStyle = .rounded
        styleSecondaryButton(localASRDeleteButton)

        punctuationStylePopup.target = self
        punctuationStylePopup.action = #selector(punctuationStyleChanged)
        punctuationStylePopup.segmentStyle = .rounded
        punctuationStylePopup.controlSize = .small

        sentenceEndingPunctuationPopup.target = self
        sentenceEndingPunctuationPopup.action = #selector(sentenceEndingPunctuationChanged)
        sentenceEndingPunctuationPopup.segmentStyle = .rounded
        sentenceEndingPunctuationPopup.controlSize = .small

        chineseScriptPopup.target = self
        chineseScriptPopup.action = #selector(chineseScriptChanged)
        chineseScriptPopup.segmentStyle = .rounded
        chineseScriptPopup.controlSize = .small

        fillerBlacklistField.placeholderString = "例如：嗯，呃，啊，em"
        fillerBlacklistField.target = self
        fillerBlacklistField.action = #selector(saveBlacklistChanged)
        fillerBlacklistField.font = .systemFont(ofSize: 13)
        fillerBlacklistField.controlSize = .small

        saveBlacklistButton.target = self
        saveBlacklistButton.action = #selector(saveBlacklistChanged)
        saveBlacklistButton.controlSize = .small
        saveBlacklistButton.bezelStyle = .rounded
        styleSecondaryButton(saveBlacklistButton)

        manualLexiconInputField.placeholderString = "例如：豆包，斯莫格"
        manualLexiconInputField.font = .systemFont(ofSize: 13)
        manualLexiconInputField.controlSize = .small
        
        manualLexiconAddButton.target = self
        manualLexiconAddButton.action = #selector(addManualTermsTapped)
        manualLexiconAddButton.controlSize = .small
        manualLexiconAddButton.bezelStyle = .rounded
        styleProminentButton(manualLexiconAddButton)

        lexiconCategoryControl.segmentStyle = .rounded
        lexiconCategoryControl.controlSize = .small
        lexiconCategoryControl.target = self
        lexiconCategoryControl.action = #selector(lexiconCategoryChanged)
        lexiconCategoryControl.selectedSegment = LexiconCategoryFilter.all.rawValue
        
        lexiconGrid.spacing = 8
        lexiconGrid.maxColumns = 4


        reapplyPermissionsButton.target = self
        reapplyPermissionsButton.action = #selector(reapplyPermissionsTapped)
        reapplyPermissionsButton.controlSize = .small
        reapplyPermissionsButton.bezelStyle = .rounded
        styleProminentButton(reapplyPermissionsButton)

        quitButton.target = self
        quitButton.action = #selector(quitApp)
        quitButton.controlSize = .small
        quitButton.bezelStyle = .rounded
        quitButton.keyEquivalent = "q"
        quitButton.keyEquivalentModifierMask = [.command]

        removeFillersButton.target = self
        removeFillersButton.action = #selector(toggleChanged)
        autoPunctuationButton.target = self
        autoPunctuationButton.action = #selector(toggleChanged)
        inputCompletionSoundButton.target = self
        inputCompletionSoundButton.action = #selector(toggleChanged)
        preserveCloudRawPunctuationButton.target = self
        preserveCloudRawPunctuationButton.action = #selector(toggleChanged)
        adaptivePunctuationButton.target = self
        adaptivePunctuationButton.action = #selector(toggleChanged)
        punctuationLearningButton.target = self
        punctuationLearningButton.action = #selector(toggleChanged)
        punctuationDebugLogButton.target = self
        punctuationDebugLogButton.action = #selector(toggleChanged)
        lexiconHitVisibilityButton.target = self
        lexiconHitVisibilityButton.action = #selector(toggleChanged)
        removeFillersButton.controlSize = .small
        autoPunctuationButton.controlSize = .small
        inputCompletionSoundButton.controlSize = .small
        preserveCloudRawPunctuationButton.controlSize = .small
        adaptivePunctuationButton.controlSize = .small
        punctuationLearningButton.controlSize = .small
        punctuationDebugLogButton.controlSize = .small
        lexiconHitVisibilityButton.controlSize = .small
        inputCompletionSoundButton.toolTip = "完成识别并写入文本后播放提示音。"
        preserveCloudRawPunctuationButton.toolTip = "关闭“自动标点和分段”时生效"
        adaptivePunctuationButton.toolTip = "达到学习阈值后，标点决策会使用本地画像参数。"
        punctuationLearningButton.toolTip = "仅本地记录；默认关闭。开启后累计达到阈值才会生效。"
        punctuationDebugLogButton.toolTip = "输出标点修复触发信息到本地控制台。"
        lexiconHitVisibilityButton.toolTip = "仅用于观察词库替换命中，输出到控制台日志。"

        viewCloudLogsButton.target = self
        viewCloudLogsButton.action = #selector(openCloudLogsViewer)
        viewCloudLogsButton.controlSize = .small
        viewCloudLogsButton.bezelStyle = .rounded
        styleSecondaryButton(viewCloudLogsButton)

        historyRetentionPopup.target = self
        historyRetentionPopup.action = #selector(historyRetentionPolicyChanged)
        historyRetentionPopup.segmentStyle = .rounded
        historyRetentionPopup.controlSize = .small

        historyDurationUnitPopup.target = self
        historyDurationUnitPopup.action = #selector(historyDurationUnitChanged)
        historyDurationUnitPopup.segmentStyle = .rounded
        historyDurationUnitPopup.controlSize = .small
        historyDurationValueLabel.font = .systemFont(ofSize: 18, weight: .bold)
        historyDurationValueLabel.textColor = .labelColor
        historyDurationDetailLabel.font = .systemFont(ofSize: 11)
        historyDurationDetailLabel.textColor = .secondaryLabelColor
        historyCharactersValueLabel.font = .systemFont(ofSize: 18, weight: .bold)
        historyCharactersValueLabel.textColor = .labelColor
        historyCharactersDetailLabel.font = .systemFont(ofSize: 11)
        historyCharactersDetailLabel.textColor = .secondaryLabelColor

        historyOpenAudioCacheDirectoryButton.target = self
        historyOpenAudioCacheDirectoryButton.action = #selector(openAudioCacheDirectoryFromHistoryTapped)
        historyOpenAudioCacheDirectoryButton.controlSize = .small
        historyOpenAudioCacheDirectoryButton.bezelStyle = .rounded
        styleSecondaryButton(historyOpenAudioCacheDirectoryButton)
        historyClearAudioCacheButton.target = self
        historyClearAudioCacheButton.action = #selector(clearAudioCacheFromHistoryTapped)
        historyClearAudioCacheButton.controlSize = .small
        historyClearAudioCacheButton.bezelStyle = .rounded
        styleSecondaryButton(historyClearAudioCacheButton)
        historyClearAllRecordsButton.target = self
        historyClearAllRecordsButton.action = #selector(clearAllHistoryTapped)
        historyClearAllRecordsButton.controlSize = .small
        historyClearAllRecordsButton.bezelStyle = .rounded
        styleSecondaryButton(historyClearAllRecordsButton)
        historyPaginationInfoLabel.font = .systemFont(ofSize: 11)
        historyPaginationInfoLabel.textColor = .secondaryLabelColor
        historyPaginationInfoLabel.lineBreakMode = .byTruncatingTail
        historyPreviousPageButton.target = self
        historyPreviousPageButton.action = #selector(showPreviousHistoryInputPage)
        historyPreviousPageButton.controlSize = .small
        historyPreviousPageButton.bezelStyle = .rounded
        styleSecondaryButton(historyPreviousPageButton)
        historyNextPageButton.target = self
        historyNextPageButton.action = #selector(showNextHistoryInputPage)
        historyNextPageButton.controlSize = .small
        historyNextPageButton.bezelStyle = .rounded
        styleSecondaryButton(historyNextPageButton)

        shortcutInputModeControl.segmentStyle = .rounded
        shortcutInputModeControl.target = self
        shortcutInputModeControl.action = #selector(shortcutInputModeChanged)
        shortcutInputModeControl.controlSize = .small

        primaryShortcutSetButton.target = self
        primaryShortcutSetButton.action = #selector(beginCapturePrimaryShortcut)
        primaryShortcutSetButton.controlSize = .small
        primaryShortcutSetButton.bezelStyle = .rounded
        styleProminentButton(primaryShortcutSetButton)
        primaryShortcutClearButton.target = self
        primaryShortcutClearButton.action = #selector(clearPrimaryShortcut)
        primaryShortcutClearButton.controlSize = .small
        primaryShortcutClearButton.bezelStyle = .rounded
        styleSecondaryButton(primaryShortcutClearButton)
        primaryShortcutValueLabel.font = .systemFont(ofSize: 12, weight: .medium)
        primaryShortcutValueLabel.textColor = .labelColor

    }

    private func makeSidebar() -> NSView {
        let sidebar = NSView(frame: .zero)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.cornerRadius = 24
        sidebar.layer?.backgroundColor = SettingsPanelPalette.sidebarFill.cgColor
        sidebar.layer?.borderWidth = 1
        sidebar.layer?.borderColor = SettingsPanelPalette.border.withAlphaComponent(0.78).cgColor
        sidebar.layer?.shadowColor = NSColor.black.withAlphaComponent(0.05).cgColor
        sidebar.layer?.shadowOpacity = 1
        sidebar.layer?.shadowRadius = 18
        sidebar.layer?.shadowOffset = NSSize(width: 0, height: -4)

        let brandTitle = NSTextField(labelWithString: "MyType")
        brandTitle.font = .systemFont(ofSize: 24, weight: .black)
        brandTitle.textColor = .labelColor

        var brandMediaViews: [NSView] = []
        if let logoURL = Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
           let logoImage = NSImage(contentsOf: logoURL) {
            let logoWrap = NSView(frame: .zero)
            logoWrap.translatesAutoresizingMaskIntoConstraints = false
            logoWrap.wantsLayer = true
            logoWrap.layer?.cornerRadius = 18
            logoWrap.layer?.backgroundColor = SettingsPanelPalette.accent.withAlphaComponent(0.12).cgColor

            let logoImageView = NSImageView(image: logoImage)
            logoImageView.translatesAutoresizingMaskIntoConstraints = false
            logoImageView.imageScaling = .scaleProportionallyUpOrDown
            logoWrap.addSubview(logoImageView)

            NSLayoutConstraint.activate([
                logoWrap.widthAnchor.constraint(equalToConstant: 56),
                logoWrap.heightAnchor.constraint(equalToConstant: 56),
                logoImageView.centerXAnchor.constraint(equalTo: logoWrap.centerXAnchor),
                logoImageView.centerYAnchor.constraint(equalTo: logoWrap.centerYAnchor),
                logoImageView.widthAnchor.constraint(equalToConstant: 40),
                logoImageView.heightAnchor.constraint(equalToConstant: 40)
            ])
            brandMediaViews.append(logoWrap)
        }

        var brandRowViews = brandMediaViews
        brandRowViews.append(brandTitle)
        let brandRow = NSStackView(views: brandRowViews)
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 12
        brandRow.translatesAutoresizingMaskIntoConstraints = false

        configureSidebarButton(homeNavButton, page: .home, symbolName: "sparkles")
        configureSidebarButton(historyNavButton, page: .history, symbolName: "clock.arrow.circlepath")
        configureSidebarButton(dictionaryNavButton, page: .dictionary, symbolName: "book.closed")

        let navStack = NSStackView(views: [
            makeSidebarButtonRow(homeNavButton, page: .home),
            makeSidebarButtonRow(historyNavButton, page: .history),
            makeSidebarButtonRow(dictionaryNavButton, page: .dictionary)
        ])
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 12
        navStack.translatesAutoresizingMaskIntoConstraints = false

        let sidebarFootnote = NSTextField(
            wrappingLabelWithString: "概览页会自动汇总最近 7 天输入趋势、快捷键和 API 使用摘要。"
        )
        sidebarFootnote.font = .systemFont(ofSize: 11, weight: .medium)
        sidebarFootnote.textColor = .secondaryLabelColor
        sidebarFootnote.maximumNumberOfLines = 0

        let sidebarStack = NSStackView(views: [brandRow, navStack, NSView(), sidebarFootnote])
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 20
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20)
        ])

        return sidebar
    }

    private func makeContentArea() -> NSView {
        contentTitleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        contentTitleLabel.textColor = .labelColor
        contentSubtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        contentSubtitleLabel.textColor = .secondaryLabelColor

        stylePillLabel(overviewModePillLabel)
        stylePillLabel(overviewShortcutPillLabel)
        stylePillLabel(overviewPreviewPillLabel)

        let overviewStatsRow = makeEqualWidthRow(
            [overviewAPIUsageCard, overviewDurationCard, overviewShortcutCard, overviewConfigCard],
            spacing: 12
        )
        [overviewAPIUsageCard, overviewDurationCard, overviewShortcutCard, overviewConfigCard].forEach {
            $0.heightAnchor.constraint(equalToConstant: 132).isActive = true
        }

        let weeklyChartBody = NSStackView(views: [
            overviewWeeklyChartView,
            makeInfoHintLabel("按本地自然日统计最近 7 天真实使用次数；每次打开设置都会自动刷新，没有数据的日期会显示 0。")
        ])
        weeklyChartBody.orientation = .vertical
        weeklyChartBody.alignment = .leading
        weeklyChartBody.spacing = 10
        weeklyChartBody.translatesAutoresizingMaskIntoConstraints = false
        let weeklyChartSection = makeSectionCard(title: "最近 7 天每日输入次数", content: weeklyChartBody)

        let commonSettingsGrid = makeAdaptiveCardGrid([
            makeSettingTile(title: "输入方式", control: shortcutInputModeControl),
            makeShortcutRow(
                title: "语音输入快捷键",
                valueLabel: primaryShortcutValueLabel,
                setButton: primaryShortcutSetButton,
                clearButton: primaryShortcutClearButton
            ),
            makeToggleTile(
                button: inputCompletionSoundButton,
                detail: "完成识别并写入文本后播放提示音。"
            ),
            makeSettingTile(
                title: "识别模式",
                control: recognitionModePopup,
                detail: "使用本地模式时，识别速度与响应时延会受电脑性能、当前负载和模型档位影响；设备性能越高，通常响应越快。"
            ),
            makeSettingTile(title: "模型档位", control: modelPopup),
            makeSettingTile(title: "中文输出", control: chineseScriptPopup),
            makeSettingTile(title: "实时预览", control: livePreviewEnabledPopup),
            makeSettingTile(title: "预览来源", control: livePreviewSourcePopup),
            makeSettingTile(title: "录音时长", control: recordingLimitPopup),
            makeSettingTile(title: "云端 API", control: apiSettingsButton)
        ])
        let commonSettingsBody = NSStackView(views: [
            commonSettingsGrid,
            makeInfoHintLabel("实时预览只显示在悬浮预览窗里；录音结束后才会真正写入目标输入框。识别模式、预览来源、录音时长和快捷键修改后会立即生效。")
        ])
        commonSettingsBody.orientation = .vertical
        commonSettingsBody.alignment = .leading
        commonSettingsBody.spacing = 12
        commonSettingsBody.translatesAutoresizingMaskIntoConstraints = false
        let commonSettingsSection = makeSectionCard(title: "常用设置", content: commonSettingsBody)
        let localASRSection = makeLocalASRSection()

        let textOptimizationGrid = makeAdaptiveCardGrid([
            makeToggleTile(
                button: removeFillersButton,
                detail: "过滤常见语气词，让输出更干净。"
            ),
            makeToggleTile(
                button: autoPunctuationButton,
                detail: "自动补全标点并做基础分段。"
            ),
            makeSettingTile(title: "句尾标点符号", control: sentenceEndingPunctuationPopup),
            makeSettingTile(title: "标点风格", control: punctuationStylePopup)
        ])
        let textOptimizationBody = NSStackView(views: [
            textOptimizationGrid,
            makeInfoHintLabel("这些文本整理项会直接影响最终输出效果。")
        ])
        textOptimizationBody.orientation = .vertical
        textOptimizationBody.alignment = .leading
        textOptimizationBody.spacing = 12
        textOptimizationBody.translatesAutoresizingMaskIntoConstraints = false
        let textOptimizationSection = makeSectionCard(title: "文本优化", content: textOptimizationBody)

        let systemActionRow = NSStackView(views: [reapplyPermissionsButton, quitButton])
        systemActionRow.orientation = .horizontal
        systemActionRow.alignment = .centerY
        systemActionRow.distribution = .fillEqually
        systemActionRow.spacing = 10
        systemActionRow.translatesAutoresizingMaskIntoConstraints = false

        let systemBody = NSStackView(views: [
            systemActionRow,
            makeInfoHintLabel("麦克风、辅助功能权限和程序退出入口保留在这里。")
        ])
        systemBody.orientation = .vertical
        systemBody.alignment = .leading
        systemBody.spacing = 10
        systemBody.translatesAutoresizingMaskIntoConstraints = false
        let systemSection = makeSectionCard(title: "系统与权限", content: systemBody)

        let durationMetricTile = makeHistoryMetricTile(
            iconName: "clock",
            valueLabel: historyDurationValueLabel,
            title: "总口述时长",
            detailLabel: historyDurationDetailLabel
        )
        let charactersMetricTile = makeHistoryMetricTile(
            iconName: "textformat.abc",
            valueLabel: historyCharactersValueLabel,
            title: "累计口述字数",
            detailLabel: historyCharactersDetailLabel
        )
        durationMetricTile.heightAnchor.constraint(equalToConstant: 90).isActive = true
        charactersMetricTile.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let historyDurationRow = NSStackView(views: [sectionLabel("时长显示单位"), historyDurationUnitPopup, NSView()])
        historyDurationRow.orientation = .horizontal
        historyDurationRow.alignment = .centerY
        historyDurationRow.spacing = 8
        historyDurationRow.translatesAutoresizingMaskIntoConstraints = false

        cloudLogSummaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        cloudLogSummaryLabel.textColor = .secondaryLabelColor
        cloudLogSummaryLabel.lineBreakMode = .byTruncatingTail
        cloudLogSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let logsSpacer = NSView()
        logsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let logsRow = NSStackView(views: [cloudLogSummaryLabel, logsSpacer, viewCloudLogsButton])
        logsRow.orientation = .horizontal
        logsRow.alignment = .centerY
        logsRow.spacing = 8
        logsRow.translatesAutoresizingMaskIntoConstraints = false
        viewCloudLogsButton.setContentHuggingPriority(.required, for: .horizontal)
        viewCloudLogsButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let logsHeaderSpacer = NSView()
        logsHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        logsHeaderSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let logsHeaderRow = NSStackView(views: [
            sectionLabel("云端请求日志"),
            logsHeaderSpacer,
            viewCloudLogsButton
        ])
        logsHeaderRow.orientation = .horizontal
        logsHeaderRow.alignment = .centerY
        logsHeaderRow.spacing = 8
        logsHeaderRow.translatesAutoresizingMaskIntoConstraints = false

        let logsBody = NSStackView(views: [
            logsHeaderRow,
            cloudLogSummaryLabel,
            makeInfoHintLabel("日志明细和统计会继续在独立窗口中查看。")
        ])
        logsBody.orientation = .vertical
        logsBody.alignment = .leading
        logsBody.spacing = 8
        logsBody.translatesAutoresizingMaskIntoConstraints = false
        logsHeaderRow.widthAnchor.constraint(equalTo: logsBody.widthAnchor).isActive = true
        cloudLogSummaryLabel.widthAnchor.constraint(equalTo: logsBody.widthAnchor).isActive = true

        let historyMetricsRow = makeEqualWidthRow([durationMetricTile, charactersMetricTile])
        let historyOverviewBody = NSStackView(views: [historyDurationRow, historyMetricsRow, logsBody])
        historyOverviewBody.orientation = .vertical
        historyOverviewBody.alignment = .leading
        historyOverviewBody.spacing = 14
        historyOverviewBody.translatesAutoresizingMaskIntoConstraints = false
        let historyOverviewSection = makeSectionCard(title: "使用数据统计", content: historyOverviewBody)

        let historyRetentionRow = NSStackView(views: [
            sectionLabel("保存历史记录"),
            historyRetentionPopup,
            NSView()
        ])
        historyRetentionRow.orientation = .horizontal
        historyRetentionRow.alignment = .centerY
        historyRetentionRow.spacing = 8
        historyRetentionRow.translatesAutoresizingMaskIntoConstraints = false

        let historyAudioCacheSpacer = NSView()
        historyAudioCacheSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        historyAudioCacheSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let historyAudioCacheRow = NSStackView(views: [
            historyOpenAudioCacheDirectoryButton,
            historyClearAudioCacheButton,
            historyAudioCacheSpacer
        ])
        historyAudioCacheRow.orientation = .horizontal
        historyAudioCacheRow.alignment = .centerY
        historyAudioCacheRow.spacing = 8
        historyAudioCacheRow.translatesAutoresizingMaskIntoConstraints = false

        let historyControlBody = NSStackView(views: [
            historyRetentionRow,
            historyAudioCacheRow,
            makeInfoHintLabel("“永不”表示不保留输入文字，其余策略会按时间自动清理。")
        ])
        historyControlBody.orientation = .vertical
        historyControlBody.alignment = .leading
        historyControlBody.spacing = 10
        historyControlBody.translatesAutoresizingMaskIntoConstraints = false
        let historyControlSection = makeSectionCard(title: "历史与缓存", content: historyControlBody)
        let historySummaryRow = makeEqualWidthRow([historyOverviewSection, historyControlSection])
        historyControlSection.heightAnchor.constraint(equalTo: historyOverviewSection.heightAnchor).isActive = true

        historyListContainer.orientation = .vertical
        historyListContainer.alignment = .width
        historyListContainer.spacing = 8
        historyListContainer.translatesAutoresizingMaskIntoConstraints = false

        let historyListDocument = FlippedView(frame: .zero)
        historyListDocument.translatesAutoresizingMaskIntoConstraints = false
        historyListDocument.addSubview(historyListContainer)
        NSLayoutConstraint.activate([
            historyListContainer.leadingAnchor.constraint(equalTo: historyListDocument.leadingAnchor),
            historyListContainer.trailingAnchor.constraint(equalTo: historyListDocument.trailingAnchor),
            historyListContainer.topAnchor.constraint(equalTo: historyListDocument.topAnchor),
            historyListContainer.bottomAnchor.constraint(equalTo: historyListDocument.bottomAnchor)
        ])

        let historyListScrollView = NSScrollView(frame: .zero)
        historyListScrollView.translatesAutoresizingMaskIntoConstraints = false
        historyListScrollView.borderType = .noBorder
        historyListScrollView.drawsBackground = false
        historyListScrollView.hasVerticalScroller = true
        historyListScrollView.autohidesScrollers = true
        historyListScrollView.documentView = historyListDocument
        historyListScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        historyListDocument.widthAnchor.constraint(equalTo: historyListScrollView.contentView.widthAnchor).isActive = true

        let historyPaginationSpacer = NSView()
        historyPaginationSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        historyPaginationSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        historyPaginationInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        historyPreviousPageButton.setContentHuggingPriority(.required, for: .horizontal)
        historyPreviousPageButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        historyNextPageButton.setContentHuggingPriority(.required, for: .horizontal)
        historyNextPageButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let historyPaginationRow = NSStackView(views: [
            historyPaginationInfoLabel,
            historyPaginationSpacer,
            historyPreviousPageButton,
            historyNextPageButton
        ])
        historyPaginationRow.orientation = .horizontal
        historyPaginationRow.alignment = .centerY
        historyPaginationRow.spacing = 8
        historyPaginationRow.translatesAutoresizingMaskIntoConstraints = false

        let historyListBody = NSStackView(views: [historyListScrollView, historyPaginationRow])
        historyListBody.orientation = .vertical
        historyListBody.alignment = .leading
        historyListBody.spacing = 10
        historyListBody.translatesAutoresizingMaskIntoConstraints = false
        historyListScrollView.widthAnchor.constraint(equalTo: historyListBody.widthAnchor).isActive = true
        historyPaginationRow.widthAnchor.constraint(equalTo: historyListBody.widthAnchor).isActive = true

        let historyListSection = makeSectionCard(
            title: "最近输入",
            content: historyListBody,
            accessoryView: historyClearAllRecordsButton
        )

        let lowPriority = NSLayoutConstraint.Priority(249)
        historyListScrollView.setContentHuggingPriority(lowPriority, for: .vertical)
        historyListBody.setContentHuggingPriority(lowPriority, for: .vertical)
        historyListSection.setContentHuggingPriority(lowPriority, for: .vertical)

        let blacklistRow = NSStackView(views: [fillerBlacklistField, saveBlacklistButton])
        blacklistRow.orientation = .horizontal
        blacklistRow.alignment = .centerY
        blacklistRow.spacing = 8
        blacklistRow.translatesAutoresizingMaskIntoConstraints = false
        saveBlacklistButton.setContentHuggingPriority(.required, for: .horizontal)

        let fillerSectionBody = NSStackView(views: [
            makeInfoHintLabel("这些词会在“自动删除语气词”启用时参与过滤。"),
            blacklistRow
        ])
        fillerSectionBody.orientation = .vertical
        fillerSectionBody.alignment = .leading
        fillerSectionBody.spacing = 10
        fillerSectionBody.translatesAutoresizingMaskIntoConstraints = false
        let fillerSection = makeSectionCard(title: "语气词过滤", content: fillerSectionBody)

        let addLexiconRow = NSStackView(views: [manualLexiconInputField, manualLexiconAddButton])
        addLexiconRow.orientation = .horizontal
        addLexiconRow.alignment = .centerY
        addLexiconRow.spacing = 8
        addLexiconRow.translatesAutoresizingMaskIntoConstraints = false
        manualLexiconAddButton.setContentHuggingPriority(.required, for: .horizontal)
        manualLexiconInputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let lexiconToolbarRow = NSStackView(views: [
            makeSettingTile(title: "添加新词", control: addLexiconRow),
            makeSettingTile(title: "筛选范围", control: lexiconCategoryControl)
        ])
        lexiconToolbarRow.orientation = .horizontal
        lexiconToolbarRow.alignment = .top
        lexiconToolbarRow.distribution = .fillEqually
        lexiconToolbarRow.spacing = 12
        lexiconToolbarRow.translatesAutoresizingMaskIntoConstraints = false

        let lexiconGridScroll = NSScrollView(frame: .zero)
        lexiconGridScroll.hasVerticalScroller = true
        lexiconGridScroll.autohidesScrollers = true
        lexiconGridScroll.borderType = .noBorder
        lexiconGridScroll.drawsBackground = false
        lexiconGridScroll.documentView = lexiconGrid
        lexiconGridScroll.translatesAutoresizingMaskIntoConstraints = false
        lexiconGridScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        lexiconGrid.translatesAutoresizingMaskIntoConstraints = false
        lexiconGrid.widthAnchor.constraint(equalTo: lexiconGridScroll.contentView.widthAnchor).isActive = true

        let lexiconSectionBody = NSStackView(views: [
            lexiconToolbarRow,
            makeInfoHintLabel("系统自动学习和手动添加的词都会在这里汇总展示。"),
            lexiconGridScroll
        ])
        lexiconSectionBody.orientation = .vertical
        lexiconSectionBody.alignment = .leading
        lexiconSectionBody.spacing = 12
        lexiconSectionBody.translatesAutoresizingMaskIntoConstraints = false
        let lexiconSection = makeSectionCard(title: "个人词库", content: lexiconSectionBody)

        pageTabView.translatesAutoresizingMaskIntoConstraints = false
        pageTabView.tabViewType = .noTabsNoBorder
        pageTabView.drawsBackground = false
        pageTabView.addTabViewItem(
            makeTabItem(
                page: .home,
                sections: [
                    overviewStatsRow,
                    weeklyChartSection,
                    commonSettingsSection,
                    localASRSection,
                    textOptimizationSection,
                    systemSection
                ],
                footerText: nil
            )
        )
        pageTabView.addTabViewItem(
            makeTabItem(
                page: .history,
                sections: [historySummaryRow, historyListSection],
                footerText: nil
            )
        )
        pageTabView.addTabViewItem(
            makeTabItem(page: .dictionary, sections: [fillerSection, lexiconSection], footerText: nil)
        )

        let content = NSView(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = SettingsPanelPalette.contentFill.cgColor
        content.layer?.cornerRadius = 24
        content.layer?.borderWidth = 1
        content.layer?.borderColor = SettingsPanelPalette.border.withAlphaComponent(0.76).cgColor
        content.layer?.shadowColor = NSColor.black.withAlphaComponent(0.07).cgColor
        content.layer?.shadowOpacity = 1
        content.layer?.shadowRadius = 22
        content.layer?.shadowOffset = NSSize(width: 0, height: -4)

        content.addSubview(contentTitleLabel)
        content.addSubview(contentSubtitleLabel)
        content.addSubview(pageTabView)
        contentTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentTitleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            contentTitleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            contentTitleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),

            contentSubtitleLabel.leadingAnchor.constraint(equalTo: contentTitleLabel.leadingAnchor),
            contentSubtitleLabel.trailingAnchor.constraint(equalTo: contentTitleLabel.trailingAnchor),
            contentSubtitleLabel.topAnchor.constraint(equalTo: contentTitleLabel.bottomAnchor, constant: 5),

            pageTabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            pageTabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            pageTabView.topAnchor.constraint(equalTo: contentSubtitleLabel.bottomAnchor, constant: 18),
            pageTabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        return content
    }

    private func makeTabItem(
        page: SettingsPage,
        sections: [NSView],
        footerText: String?
    ) -> NSTabViewItem {
        let scroll = NSScrollView(frame: .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let document = FlippedView(frame: .zero)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        var stackedViews = sections
        if let footerText {
            stackedViews.append(makeInfoHintLabel(footerText))
        }

        let stack = NSStackView(views: stackedViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10)
        ])

        let stackMinHeight = stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor, constant: -18)
        stackMinHeight.priority = .defaultLow
        stackMinHeight.isActive = true

        let stackMinWidth = stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor, constant: -16)
        stackMinWidth.priority = .defaultHigh
        stackMinWidth.isActive = true

        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let item = NSTabViewItem(identifier: page)
        item.view = scroll
        return item
    }

    private func configureSidebarButton(_ button: NSButton, page: SettingsPage, symbolName: String) {
        button.target = self
        button.action = #selector(sidebarPageTapped(_:))
        button.tag = page.rawValue
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbolConfig)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .left
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imageHugsTitle = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.widthAnchor.constraint(equalToConstant: 164).isActive = true
        applySidebarButtonText(button, selected: false, hovered: false)
        pageButtons[page] = button
    }

    private func makeSidebarButtonRow(_ button: NSButton, page: SettingsPage) -> HoverableSidebarRowView {
        let row = HoverableSidebarRowView(frame: .zero)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 14
        row.layer?.backgroundColor = NSColor.clear.cgColor
        row.onHoverChanged = { [weak self] isHovering in
            guard let self else { return }
            if isHovering {
                self.hoveredPage = page
            } else if self.hoveredPage == page {
                self.hoveredPage = nil
            }
            self.refreshSidebarStyles()
        }
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            row.widthAnchor.constraint(equalToConstant: 188),
            row.heightAnchor.constraint(equalToConstant: 46)
        ])
        pageRows[page] = row
        return row
    }

    private func applySidebarButtonText(_ button: NSButton, selected: Bool, hovered: Bool) {
        let title = sidebarLabel(for: button)
        let font = NSFont.systemFont(ofSize: 15, weight: selected ? .semibold : .medium)
        let color: NSColor
        if selected {
            color = SettingsPanelPalette.accentStrong
        } else if hovered {
            color = .labelColor
        } else {
            color = .secondaryLabelColor
        }
        button.attributedTitle = NSAttributedString(
            string: "  \(title)",
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: 0.2
            ]
        )
        button.contentTintColor = color
    }

    private func sidebarLabel(for button: NSButton) -> String {
        guard let page = SettingsPage(rawValue: button.tag) else {
            return button.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch page {
        case .home:
            return "概览"
        case .history:
            return "历史记录"
        case .dictionary:
            return "词库"
        }
    }

    private func switchToPage(_ page: SettingsPage) {
        if currentPage == page, pageTabView.selectedTabViewItem != nil {
            return
        }
        currentPage = page
        pageTabView.selectTabViewItem(withIdentifier: page)
        contentTitleLabel.stringValue = page.title
        contentSubtitleLabel.stringValue = page.subtitle
        if page == .history, historyListNeedsReload {
            reloadHistoryInputList()
            historyListNeedsReload = false
        }
        refreshSidebarStyles()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshSelectedPageLayout()
        }
    }

    private func refreshSelectedPageLayout() {
        guard let selectedView = pageTabView.selectedTabViewItem?.view else { return }
        selectedView.frame = pageTabView.bounds
        selectedView.autoresizingMask = [.width, .height]
        selectedView.needsLayout = true
        selectedView.layoutSubtreeIfNeeded()
        pageTabView.layoutSubtreeIfNeeded()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        refreshSelectedPageLayout()
    }

    private func refreshSidebarStyles() {
        for (buttonPage, button) in pageButtons {
            let selected = buttonPage == currentPage
            let hovered = buttonPage == hoveredPage
            pageRows[buttonPage]?.layer?.backgroundColor = selected
                ? SettingsPanelPalette.accent.withAlphaComponent(0.14).cgColor
                : (hovered ? SettingsPanelPalette.accent.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor)
            pageRows[buttonPage]?.layer?.borderWidth = selected ? 1 : 0
            pageRows[buttonPage]?.layer?.borderColor = SettingsPanelPalette.accent.withAlphaComponent(0.2).cgColor
            applySidebarButtonText(button, selected: selected, hovered: hovered)
        }
    }

    private func clearHoverIfNeeded(for page: SettingsPage) {
        if hoveredPage == page {
            hoveredPage = nil
            refreshSidebarStyles()
        }
    }

    @objc
    private func sidebarPageTapped(_ sender: NSButton) {
        guard let page = SettingsPage(rawValue: sender.tag) else { return }
        clearHoverIfNeeded(for: page)
        switchToPage(page)
    }

    private func pin(
        _ child: NSView,
        to parent: NSView,
        insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    ) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)
        ])
    }

    private func makeSurfaceBox(
        fillColor: NSColor = SettingsPanelPalette.cardFill,
        borderColor: NSColor = SettingsPanelPalette.border,
        cornerRadius: CGFloat = 18
    ) -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.boxType = .custom
        box.cornerRadius = cornerRadius
        box.borderWidth = 1
        box.borderColor = borderColor
        box.fillColor = fillColor
        box.contentViewMargins = NSSize(width: 16, height: 14)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.shadowColor = NSColor.black.withAlphaComponent(0.04).cgColor
        box.layer?.shadowOpacity = 1
        box.layer?.shadowRadius = 12
        box.layer?.shadowOffset = NSSize(width: 0, height: -3)
        return box
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeInfoHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func styleProminentButton(_ button: NSButton) {
        button.bezelColor = SettingsPanelPalette.accentStrong
        button.contentTintColor = .white
    }

    private func styleSecondaryButton(_ button: NSButton) {
        let textColor = NSColor.white
        button.bezelColor = NSColor(calibratedWhite: 0.58, alpha: 1)
        button.contentTintColor = textColor
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: textColor
            ]
        )
    }

    private func stylePillLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
    }

    private func makeStatusPill(_ label: NSTextField, fillColor: NSColor = NSColor.white.withAlphaComponent(0.62)) -> NSBox {
        let box = makeSurfaceBox(
            fillColor: fillColor,
            borderColor: SettingsPanelPalette.border.withAlphaComponent(0.45),
            cornerRadius: 999
        )
        box.contentViewMargins = NSSize(width: 10, height: 6)
        if let contentView = box.contentView {
            contentView.addSubview(label)
            pin(label, to: contentView)
        }
        return box
    }

    private func makeEqualWidthRow(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeAdaptiveCardGrid(_ views: [NSView], spacing: CGFloat = 12) -> AdaptiveCardGridView {
        AdaptiveCardGridView(
            views: views,
            baselineWidth: Self.overviewGridBaselineWidth,
            baselineColumns: 3,
            maxColumns: 6,
            spacing: spacing
        )
    }

    private func makeSectionCard(title: String, content: NSView, accessoryView: NSView? = nil) -> NSBox {
        let box = makeSurfaceBox()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)

        content.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .vertical)

        let titleRow: NSView
        if let accessoryView = accessoryView {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [titleLabel, spacer, accessoryView])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 10
            titleRow = stack
        } else {
            titleRow = titleLabel
        }

        let wrapper = NSStackView(views: [titleRow, content])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 12
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true

        if let contentView = box.contentView {
            contentView.addSubview(wrapper)
            pin(wrapper, to: contentView)
        }
        return box
    }

    private func makeSettingTile(title: String, control: NSView, detail: String? = nil) -> NSBox {
        let titleLabel = sectionLabel(title)
        var bodyViews: [NSView] = [titleLabel, control]
        if let detail, !detail.isEmpty {
            bodyViews.append(makeInfoHintLabel(detail))
        }
        let body = NSStackView(views: bodyViews)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false

        let tile = makeSurfaceBox(
            fillColor: SettingsPanelPalette.secondaryCardFill,
            borderColor: SettingsPanelPalette.border.withAlphaComponent(0.65),
            cornerRadius: 16
        )
        tile.contentViewMargins = NSSize(width: 12, height: 12)
        if let contentView = tile.contentView {
            contentView.addSubview(body)
            pin(body, to: contentView)
        }
        return tile
    }

    private func makeLocalASRSection() -> NSBox {
        localASRActivityIndicator.translatesAutoresizingMaskIntoConstraints = false
        localASRStatusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        localASRStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        localASRPrimaryButton.setContentHuggingPriority(.required, for: .horizontal)
        localASRDeleteButton.setContentHuggingPriority(.required, for: .horizontal)

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusRow = NSStackView(views: [localASRActivityIndicator, localASRStatusLabel, statusSpacer])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [localASRPrimaryButton, localASRDeleteButton, buttonSpacer])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [
            statusRow,
            localASRDetailLabel,
            buttonRow,
            makeInfoHintLabel("本地模型只下载到当前这台 Mac。删除后不会影响你已经保存的云端 API 设置。")
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        statusRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        localASRDetailLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        localASRActivityIndicator.widthAnchor.constraint(equalToConstant: 14).isActive = true
        localASRActivityIndicator.heightAnchor.constraint(equalToConstant: 14).isActive = true

        return makeSectionCard(title: "本地模型", content: body)
    }

    private func observeLocalASRState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLocalASRStateNotification(_:)),
            name: LocalASRAssetManager.stateDidChangeNotification,
            object: LocalASRAssetManager.shared
        )
    }

    @objc
    private func handleLocalASRStateNotification(_ notification: Notification) {
        let snapshot = notification.userInfo?["snapshot"] as? LocalASRAssetManager.Snapshot
            ?? LocalASRAssetManager.shared.snapshot
        updateLocalASRCard(snapshot: snapshot)
    }

    private func updateLocalASRCard(snapshot: LocalASRAssetManager.Snapshot) {
        localASRStatusLabel.stringValue = snapshot.title
        localASRDetailLabel.stringValue = snapshot.detail
        localASRPrimaryButton.title = snapshot.primaryActionTitle
        localASRPrimaryButton.isEnabled = snapshot.canStartInstall
        localASRDeleteButton.isHidden = !snapshot.canDelete
        localASRDeleteButton.isEnabled = snapshot.canDelete && !snapshot.showsActivity

        switch snapshot.kind {
        case .ready:
            localASRStatusLabel.textColor = NSColor(calibratedRed: 0.15, green: 0.58, blue: 0.29, alpha: 1)
            localASRDetailLabel.textColor = .secondaryLabelColor
        case .failed:
            localASRStatusLabel.textColor = NSColor.systemRed
            localASRDetailLabel.textColor = NSColor.systemRed.withAlphaComponent(0.85)
        case .unavailable:
            localASRStatusLabel.textColor = NSColor.systemOrange
            localASRDetailLabel.textColor = .secondaryLabelColor
        case .installing:
            localASRStatusLabel.textColor = SettingsPanelPalette.accentStrong
            localASRDetailLabel.textColor = .secondaryLabelColor
        case .notInstalled:
            localASRStatusLabel.textColor = .labelColor
            localASRDetailLabel.textColor = .secondaryLabelColor
        }

        if snapshot.showsActivity {
            localASRActivityIndicator.startAnimation(nil)
        } else {
            localASRActivityIndicator.stopAnimation(nil)
        }
    }

    private func makeShortcutRow(
        title: String,
        valueLabel: NSTextField,
        setButton: NSButton,
        clearButton: NSButton
    ) -> NSBox {
        let titleLabel = sectionLabel(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [valueLabel, spacer, setButton, clearButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        setButton.setContentHuggingPriority(.required, for: .horizontal)
        setButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        setButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        let row = NSStackView(views: [titleLabel, controls])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let tile = makeSurfaceBox(
            fillColor: SettingsPanelPalette.secondaryCardFill,
            borderColor: SettingsPanelPalette.border.withAlphaComponent(0.65),
            cornerRadius: 16
        )
        tile.contentViewMargins = NSSize(width: 12, height: 12)
        if let contentView = tile.contentView {
            contentView.addSubview(row)
            pin(row, to: contentView)
        }
        return tile
    }

    private func makeToggleTile(button: NSButton, detail: String) -> NSBox {
        let body = NSStackView(views: [button, makeInfoHintLabel(detail)])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false

        let tile = makeSurfaceBox(
            fillColor: SettingsPanelPalette.secondaryCardFill,
            borderColor: SettingsPanelPalette.border.withAlphaComponent(0.65),
            cornerRadius: 16
        )
        tile.contentViewMargins = NSSize(width: 12, height: 12)
        if let contentView = tile.contentView {
            contentView.addSubview(body)
            pin(body, to: contentView)
        }
        return tile
    }

    private func makeHistoryMetricTile(
        iconName: String,
        valueLabel: NSTextField,
        title: String,
        detailLabel: NSTextField
    ) -> NSBox {
        let icon = NSImageView(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.contentTintColor = SettingsPanelPalette.accentStrong

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let valueRow = NSStackView(views: [icon, valueLabel])
        valueRow.orientation = .horizontal
        valueRow.alignment = .centerY
        valueRow.spacing = 6
        valueRow.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [valueRow, titleLabel, detailLabel])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 3
        body.translatesAutoresizingMaskIntoConstraints = false

        let tile = makeSurfaceBox(
            fillColor: SettingsPanelPalette.secondaryCardFill,
            borderColor: SettingsPanelPalette.border.withAlphaComponent(0.65),
            cornerRadius: 16
        )
        tile.contentViewMargins = NSSize(width: 12, height: 12)
        tile.contentView?.addSubview(body)

        if let content = tile.contentView {
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                body.topAnchor.constraint(equalTo: content.topAnchor),
                body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14)
            ])
        }
        return tile
    }

    private func syncFromSettings() {
        LocalASRAssetManager.shared.refreshStatus()
        reloadLexiconGrid()
        
        let removeFillers = settings.bool(forKey: SettingsKeys.removeFillers, default: true)
        let autoPunctuation = settings.bool(forKey: SettingsKeys.autoPunctuation, default: true)
        let inputCompletionSoundEnabled = settings.bool(
            forKey: SettingsKeys.inputCompletionSoundEnabled,
            default: true
        )
        let sentenceEndingPunctuationEnabled = settings.bool(
            forKey: SettingsKeys.sentenceEndingPunctuationEnabled,
            default: true
        )
        let preserveCloudRawPunctuation = settings.bool(
            forKey: SettingsKeys.preserveCloudRawPunctuation,
            default: false
        )
        let adaptivePunctuation = settings.bool(
            forKey: SettingsKeys.enableAdaptivePunctuation,
            default: false
        )
        let punctuationLearning = settings.bool(
            forKey: SettingsKeys.punctuationLearningEnabled,
            default: false
        )
        let punctuationDebugLog = settings.bool(
            forKey: SettingsKeys.punctuationDebugLogEnabled,
            default: false
        )
        let lexiconHitVisibility = settings.bool(
            forKey: SettingsKeys.lexiconHitVisibility,
            default: false
        )
        let modelRawValue = settings.string(forKey: SettingsKeys.asrModel, default: ASRModelSize.small.rawValue)
        let model = ASRModelSize(rawValue: modelRawValue) ?? .small
        let recognitionModeRawValue = settings.string(
            forKey: SettingsKeys.recognitionMode,
            default: RecognitionMode.local.rawValue
        )
        let recognitionMode = resolvedRecognitionMode(from: recognitionModeRawValue)
        let punctuationStyleRawValue = settings.string(forKey: SettingsKeys.punctuationStyle, default: PunctuationStyle.auto.rawValue)
        let punctuationStyle = PunctuationStyle(rawValue: punctuationStyleRawValue) ?? .auto
        let chineseScriptRawValue = settings.string(forKey: SettingsKeys.chineseScriptMode, default: ChineseScriptMode.simplified.rawValue)
        let chineseScript = ChineseScriptMode(rawValue: chineseScriptRawValue) ?? .simplified
        let livePreviewEnabled = settings.bool(forKey: SettingsKeys.livePreviewEnabled, default: false)
        if settings.bool(forKey: SettingsKeys.cloudStablePreviewCommitEnabled, default: false) {
            settings.set(false, forKey: SettingsKeys.cloudStablePreviewCommitEnabled)
        }
        let stableLiveOutputEnabled = false
        let livePreviewSourceRaw = settings.string(
            forKey: SettingsKeys.livePreviewSource,
            default: LivePreviewSource.local.rawValue
        )
        var livePreviewSource = LivePreviewSource(rawValue: livePreviewSourceRaw) ?? .local
        if isPreviewSourceForcedToLocal(for: recognitionMode), livePreviewSource != .local {
            livePreviewSource = .local
            settings.set(LivePreviewSource.local.rawValue, forKey: SettingsKeys.livePreviewSource)
        }
        let recordingLimitRaw = settings.string(
            forKey: SettingsKeys.recordingDurationLimit,
            default: RecordingDurationLimit.s120.rawValue
        )
        let recordingLimit = RecordingDurationLimit(rawValue: recordingLimitRaw) ?? .s120
        let logs = settings.stringArray(forKey: SettingsKeys.cloudRequestLogs, default: [])
        let perfLogs = settings.stringArray(forKey: SettingsKeys.pipelinePerformanceLogs, default: [])
        let historyLines = settings.stringArray(forKey: SettingsKeys.historyInputRecords, default: [])
        let historyDurationUnitRaw = settings.string(
            forKey: SettingsKeys.historyDurationUnit,
            default: HistoryDurationUnit.minutes.rawValue
        )
        let historyDurationUnit = HistoryDurationUnit.fromStored(historyDurationUnitRaw)
        let historyRetentionRaw = settings.string(
            forKey: SettingsKeys.historyRetentionPolicy,
            default: HistoryRetentionPolicy.forever.rawValue
        )
        let historyRetention = HistoryRetentionPolicy.fromStored(historyRetentionRaw)
        let shortcutInputModeRaw = settings.string(
            forKey: SettingsKeys.shortcutInputMode,
            default: ShortcutInputMode.holdToTalk.rawValue
        )
        let shortcutInputMode = ShortcutInputMode.fromStored(shortcutInputModeRaw)

        removeFillersButton.state = removeFillers ? .on : .off
        autoPunctuationButton.state = autoPunctuation ? .on : .off
        inputCompletionSoundButton.state = inputCompletionSoundEnabled ? .on : .off
        preserveCloudRawPunctuationButton.state = preserveCloudRawPunctuation ? .on : .off
        adaptivePunctuationButton.state = adaptivePunctuation ? .on : .off
        punctuationLearningButton.state = punctuationLearning ? .on : .off
        punctuationDebugLogButton.state = punctuationDebugLog ? .on : .off
        lexiconHitVisibilityButton.state = lexiconHitVisibility ? .on : .off
        preserveCloudRawPunctuationButton.isEnabled = !autoPunctuation
        fillerBlacklistField.stringValue = fillerBlacklistProvider().joined(separator: "，")
        modelPopup.selectedSegment = index(for: model)
        recognitionModePopup.selectedSegment = index(for: recognitionMode)
        punctuationStylePopup.selectedSegment = index(for: punctuationStyle)
        sentenceEndingPunctuationPopup.selectedSegment = sentenceEndingPunctuationEnabled ? 0 : 1
        chineseScriptPopup.selectedSegment = index(for: chineseScript)
        lexiconCategoryControl.selectedSegment = currentLexiconFilter.rawValue
        livePreviewEnabledPopup.selectedSegment = livePreviewEnabled ? 0 : 1
        livePreviewSourcePopup.selectedSegment = index(for: livePreviewSource)
        livePreviewSourcePopup.isEnabled = isPreviewSourceConfigurable(for: recognitionMode)
        liveOutputPopup.selectedSegment = stableLiveOutputEnabled ? 1 : 0
        updateLiveOutputAvailability(
            recognitionMode: recognitionMode,
            livePreviewEnabled: livePreviewEnabled,
            livePreviewSource: livePreviewSource
        )
        recordingLimitPopup.selectedSegment = index(for: recordingLimit)
        historyDurationUnitPopup.selectedSegment = historyDurationUnit == .minutes ? 0 : 1
        historyRetentionPopup.selectedSegment = index(for: historyRetention)
        shortcutInputModeControl.selectedSegment = (shortcutInputMode == .continuous) ? 1 : 0
        let entries = CloudRequestLogAnalyzer.parse(lines: logs)
        let todayCount = CloudRequestLogAnalyzer.filteredEntries(from: entries, range: .today).count
        let sevenDayCount = CloudRequestLogAnalyzer.filteredEntries(from: entries, range: .days7).count
        let thirtyDayCount = CloudRequestLogAnalyzer.filteredEntries(from: entries, range: .days30).count
        let durationStats = CloudRequestLogAnalyzer.stats(from: entries)
        let pipelineSummary = summarizePipelineLogs(perfLogs)
        let totalDurationSeconds = pipelineSummary.totalRecordingSeconds > 0
            ? pipelineSummary.totalRecordingSeconds
            : durationStats.totalDurationSeconds
        let durationRecordCount = pipelineSummary.recordingCount > 0
            ? pipelineSummary.recordingCount
            : durationStats.requestCount
        let historyLinesForPanel: [String]
        let didTruncateHistoryLinesForPanel: Bool
        if historyLines.count > Self.maxParsedHistoryRecords {
            historyLinesForPanel = Array(historyLines.suffix(Self.maxParsedHistoryRecords))
            didTruncateHistoryLinesForPanel = true
        } else {
            historyLinesForPanel = historyLines
            didTruncateHistoryLinesForPanel = false
        }

        let parsedHistoryRecords = parseHistoryInputRecords(historyLinesForPanel)
        let prunedHistoryRecords = pruneHistoryInputRecords(parsedHistoryRecords, policy: historyRetention)
        historyInputRecords = prunedHistoryRecords.sorted { $0.timestamp > $1.timestamp }
        if !didTruncateHistoryLinesForPanel, prunedHistoryRecords.count != parsedHistoryRecords.count {
            persistHistoryInputRecords(prunedHistoryRecords)
        }
        updateHistoryOverview(
            totalDurationSeconds: totalDurationSeconds,
            requestCount: durationRecordCount,
            totalCharacters: pipelineSummary.totalTextLength,
            unit: historyDurationUnit
        )
        updateCurrentConfigSummary(
            recognitionMode: recognitionMode,
            model: model,
            chineseScript: chineseScript,
            livePreviewEnabled: livePreviewEnabled
        )
        updateShortcutDisplay()
        updateAnalyticsSummary(
            entries: entries,
            totalDurationSeconds: totalDurationSeconds,
            requestCount: durationRecordCount,
            totalCharacters: pipelineSummary.totalTextLength,
            unit: historyDurationUnit,
            weeklyUsagePoints: weeklyUsageChartPoints(
                fromPerformanceLogs: perfLogs,
                fallbackRecords: historyInputRecords
            )
        )
        historyListNeedsReload = true
        if currentPage == .history {
            reloadHistoryInputList()
            historyListNeedsReload = false
        }
        cloudLogSummaryLabel.stringValue = logs.isEmpty
            ? "暂无请求日志"
            : "共\(logs.count)条（今日\(todayCount) / 近7日\(sevenDayCount) / 近30日\(thirtyDayCount)）"
        cloudLogViewer?.refresh()
        onModelChanged(model)
        onChineseScriptModeChanged(chineseScript)
        onRecognitionModeChanged(recognitionMode)
        updateLocalASRCard(snapshot: LocalASRAssetManager.shared.snapshot)
    }

    private func updateAnalyticsSummary(
        entries: [CloudRequestLogEntry],
        totalDurationSeconds: Double,
        requestCount: Int,
        totalCharacters: Int,
        unit: HistoryDurationUnit,
        weeklyUsagePoints: [WeeklyActivityChartView.Point]
    ) {
        let stats = CloudRequestLogAnalyzer.stats(from: entries)
        let todayCount = CloudRequestLogAnalyzer.filteredEntries(from: entries, range: .today).count
        let sevenDayCount = CloudRequestLogAnalyzer.filteredEntries(from: entries, range: .days7).count

        overviewAPIUsageCard.valueLabel.stringValue = entries.isEmpty ? "暂无请求" : "\(sevenDayCount) 次"
        overviewAPIUsageCard.detailLabel.stringValue = entries.isEmpty
            ? "最近 7 天暂无云端请求记录"
            : "今日 \(todayCount) 次 · 成功 \(stats.successCount)/\(stats.requestCount) · \(formattedCurrency(stats.totalEstimatedCostCNY))"

        overviewDurationCard.valueLabel.stringValue = formattedDuration(totalDurationSeconds, unit: unit)
        overviewDurationCard.detailLabel.stringValue = requestCount > 0
            ? "\(formattedCharacterCount(totalCharacters)) 字 · 共 \(requestCount) 次输入"
            : "暂无语音输入记录"

        overviewWeeklyChartView.points = weeklyUsagePoints
    }

    private func updateCurrentConfigSummary(
        recognitionMode: RecognitionMode,
        model: ASRModelSize,
        chineseScript: ChineseScriptMode,
        livePreviewEnabled: Bool
    ) {
        overviewConfigCard.valueLabel.stringValue = "\(displayTitle(for: recognitionMode)) · \(model.rawValue)"
        overviewConfigCard.detailLabel.stringValue =
            "\(displayTitle(for: chineseScript)) · "
            + (livePreviewEnabled ? "悬浮预览已开启（不提前写入）" : "实时预览已关闭")
        overviewModePillLabel.stringValue = "识别模式：\(displayTitle(for: recognitionMode))"
        overviewPreviewPillLabel.stringValue =
            livePreviewEnabled ? "实时预览：仅悬浮显示" : "实时预览：已关闭"
    }

    private func updateShortcutDisplay() {
        let primary = ShortcutBinding.load(target: .primary, settings: settings)
        let rawMode = settings.string(
            forKey: SettingsKeys.shortcutInputMode,
            default: ShortcutInputMode.holdToTalk.rawValue
        )
        let shortcutMode = ShortcutInputMode.fromStored(rawMode)
        let displayValue = primary?.displayString() ?? "未设置"
        primaryShortcutValueLabel.stringValue = displayValue
        overviewShortcutCard.valueLabel.stringValue = displayValue
        overviewShortcutCard.detailLabel.stringValue = "输入方式：\(shortcutMode.title)"
        overviewShortcutPillLabel.stringValue = "快捷键：\(displayValue)"
    }

    private func weeklyInputChartPoints(from records: [HistoryInputRecord]) -> [WeeklyActivityChartView.Point] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        let groupedCounts = Dictionary(grouping: records.filter { $0.timestamp != .distantPast }) {
            calendar.startOfDay(for: $0.timestamp)
        }.mapValues(\.count)

        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -(6 - offset), to: today) else { return nil }
            return WeeklyActivityChartView.Point(
                label: formatter.string(from: day),
                count: groupedCounts[day] ?? 0
            )
        }
    }

    private func weeklyUsageChartPoints(
        fromPerformanceLogs lines: [String],
        fallbackRecords: [HistoryInputRecord]
    ) -> [WeeklyActivityChartView.Point] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"

        var groupedCounts: [Date: Int] = [:]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let timestampRaw = json["timestamp"] as? String,
                  let timestamp = Self.pipelinePerformanceDateFormatter.date(from: timestampRaw) else {
                continue
            }
            let day = calendar.startOfDay(for: timestamp)
            groupedCounts[day, default: 0] += 1
        }

        if groupedCounts.isEmpty {
            groupedCounts = Dictionary(grouping: fallbackRecords.filter { $0.timestamp != .distantPast }) {
                calendar.startOfDay(for: $0.timestamp)
            }.mapValues(\.count)
        }

        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -(6 - offset), to: today) else { return nil }
            return WeeklyActivityChartView.Point(
                label: formatter.string(from: day),
                count: groupedCounts[day] ?? 0
            )
        }
    }

    private func refreshWeeklyUsageChart() {
        let perfLogs = settings.stringArray(forKey: SettingsKeys.pipelinePerformanceLogs, default: [])
        overviewWeeklyChartView.points = weeklyUsageChartPoints(
            fromPerformanceLogs: perfLogs,
            fallbackRecords: historyInputRecords
        )
    }

    private func displayTitle(for mode: RecognitionMode) -> String {
        switch mode {
        case .local:
            return "本地"
        case .cloud:
            return "云端"
        case .hybrid, .auto:
            return "混合"
        }
    }

    private func displayTitle(for mode: ChineseScriptMode) -> String {
        switch mode {
        case .simplified:
            return "简体中文"
        case .traditional:
            return "繁体中文"
        }
    }

    private func formattedCurrency(_ value: Double) -> String {
        String(format: "估算 ¥%.2f", max(0, value))
    }

    @objc
    private func toggleChanged() {
        settings.set(removeFillersButton.state == .on, forKey: SettingsKeys.removeFillers)
        settings.set(autoPunctuationButton.state == .on, forKey: SettingsKeys.autoPunctuation)
        settings.set(
            inputCompletionSoundButton.state == .on,
            forKey: SettingsKeys.inputCompletionSoundEnabled
        )
        settings.set(
            preserveCloudRawPunctuationButton.state == .on,
            forKey: SettingsKeys.preserveCloudRawPunctuation
        )
        settings.set(
            adaptivePunctuationButton.state == .on,
            forKey: SettingsKeys.enableAdaptivePunctuation
        )
        settings.set(
            punctuationLearningButton.state == .on,
            forKey: SettingsKeys.punctuationLearningEnabled
        )
        settings.set(
            punctuationDebugLogButton.state == .on,
            forKey: SettingsKeys.punctuationDebugLogEnabled
        )
        settings.set(
            lexiconHitVisibilityButton.state == .on,
            forKey: SettingsKeys.lexiconHitVisibility
        )
        preserveCloudRawPunctuationButton.isEnabled = autoPunctuationButton.state == .off
    }

    @objc
    private func modelChanged() {
        let model = modelSize(for: modelPopup.selectedSegment)
        settings.set(model.rawValue, forKey: SettingsKeys.asrModel)
        onModelChanged(model)
        updateCurrentConfigSummary(
            recognitionMode: recognitionMode(for: recognitionModePopup.selectedSegment),
            model: model,
            chineseScript: chineseScriptMode(for: chineseScriptPopup.selectedSegment),
            livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0
        )
    }

    @objc
    private func recognitionModeChanged() {
        let mode = recognitionMode(for: recognitionModePopup.selectedSegment)
        settings.set(mode.rawValue, forKey: SettingsKeys.recognitionMode)
        if isPreviewSourceForcedToLocal(for: mode) {
            settings.set(LivePreviewSource.local.rawValue, forKey: SettingsKeys.livePreviewSource)
            livePreviewSourcePopup.selectedSegment = index(for: LivePreviewSource.local)
        }
        livePreviewSourcePopup.isEnabled = isPreviewSourceConfigurable(for: mode)
        updateLiveOutputAvailability(
            recognitionMode: mode,
            livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0,
            livePreviewSource: isPreviewSourceForcedToLocal(for: mode)
                ? .local
                : livePreviewSource(for: livePreviewSourcePopup.selectedSegment)
        )
        onRecognitionModeChanged(mode)
        updateCurrentConfigSummary(
            recognitionMode: mode,
            model: modelSize(for: modelPopup.selectedSegment),
            chineseScript: chineseScriptMode(for: chineseScriptPopup.selectedSegment),
            livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0
        )
    }

    @objc
    private func livePreviewEnabledChanged() {
        settings.set(livePreviewEnabledPopup.selectedSegment == 0, forKey: SettingsKeys.livePreviewEnabled)
        updateLiveOutputAvailability(
            recognitionMode: recognitionMode(for: recognitionModePopup.selectedSegment),
            livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0,
            livePreviewSource: livePreviewSource(for: livePreviewSourcePopup.selectedSegment)
        )
        updateCurrentConfigSummary(
            recognitionMode: recognitionMode(for: recognitionModePopup.selectedSegment),
            model: modelSize(for: modelPopup.selectedSegment),
            chineseScript: chineseScriptMode(for: chineseScriptPopup.selectedSegment),
            livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0
        )
    }

    @objc
    private func livePreviewSourceChanged() {
        let mode = recognitionMode(for: recognitionModePopup.selectedSegment)
        if isPreviewSourceForcedToLocal(for: mode) {
            settings.set(LivePreviewSource.local.rawValue, forKey: SettingsKeys.livePreviewSource)
            livePreviewSourcePopup.selectedSegment = index(for: LivePreviewSource.local)
            updateLiveOutputAvailability(
                recognitionMode: mode,
                livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0,
                livePreviewSource: .local
            )
            return
        }
        let source = livePreviewSource(for: livePreviewSourcePopup.selectedSegment)
        settings.set(source.rawValue, forKey: SettingsKeys.livePreviewSource)
        updateLiveOutputAvailability(
            recognitionMode: mode,
            livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0,
            livePreviewSource: source
        )
    }

    @objc
    private func liveOutputChanged() {
        liveOutputPopup.selectedSegment = 0
        settings.set(false, forKey: SettingsKeys.cloudStablePreviewCommitEnabled)
    }

    @objc
    private func recordingLimitChanged() {
        let limit = recordingLimit(for: recordingLimitPopup.selectedSegment)
        settings.set(limit.rawValue, forKey: SettingsKeys.recordingDurationLimit)
    }

    @objc
    private func punctuationStyleChanged() {
        let selectedStyle = style(for: punctuationStylePopup.selectedSegment)
        settings.set(selectedStyle.rawValue, forKey: SettingsKeys.punctuationStyle)
    }

    @objc
    private func sentenceEndingPunctuationChanged() {
        settings.set(
            sentenceEndingPunctuationPopup.selectedSegment == 0,
            forKey: SettingsKeys.sentenceEndingPunctuationEnabled
        )
    }

    @objc
    private func chineseScriptChanged() {
        let mode = chineseScriptMode(for: chineseScriptPopup.selectedSegment)
        settings.set(mode.rawValue, forKey: SettingsKeys.chineseScriptMode)
        onChineseScriptModeChanged(mode)
        updateCurrentConfigSummary(
            recognitionMode: recognitionMode(for: recognitionModePopup.selectedSegment),
            model: modelSize(for: modelPopup.selectedSegment),
            chineseScript: mode,
            livePreviewEnabled: livePreviewEnabledPopup.selectedSegment == 0
        )
    }

    @objc
    private func historyDurationUnitChanged() {
        let unit: HistoryDurationUnit = historyDurationUnitPopup.selectedSegment == 1 ? .hours : .minutes
        settings.set(unit.rawValue, forKey: SettingsKeys.historyDurationUnit)
        syncFromSettings()
    }

    @objc
    private func shortcutInputModeChanged() {
        let mode: ShortcutInputMode = shortcutInputModeControl.selectedSegment == 1 ? .continuous : .holdToTalk
        settings.set(mode.rawValue, forKey: SettingsKeys.shortcutInputMode)
        onShortcutSettingsChanged()
        syncFromSettings()
    }

    @objc
    private func historyRetentionPolicyChanged() {
        let policy = historyRetentionPolicy(for: historyRetentionPopup.selectedSegment)
        settings.set(policy.rawValue, forKey: SettingsKeys.historyRetentionPolicy)
        syncFromSettings()
    }

    @objc
    private func saveBlacklistChanged() {
        let parsed = parseBlacklistInput(fillerBlacklistField.stringValue)
        onFillerBlacklistChanged(parsed)
        fillerBlacklistField.stringValue = parsed.joined(separator: "，")
    }

    @objc
    private func lexiconCategoryChanged() {
        let selected = LexiconCategoryFilter(rawValue: lexiconCategoryControl.selectedSegment) ?? .all
        currentLexiconFilter = selected
        reloadLexiconGrid()
    }

    @objc
    private func addManualTermsTapped() {
        let input = manualLexiconInputField.stringValue
        let parsed = parseTermsInput(input)
        guard !parsed.isEmpty else { return }
        onAddManualLexiconTerms(parsed)
        manualLexiconInputField.stringValue = ""
        reloadLexiconGrid()
        showTransientSuccessMessage("已添加 \(parsed.count) 个词库词", anchorView: manualLexiconAddButton)
    }

    private func parseTermsInput(_ input: String) -> [String] {
        let normalized = input
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: "、", with: ",")
        let parts = normalized
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var output: [String] = []
        var seen: Set<String> = []
        for part in parts where !seen.contains(part) {
            seen.insert(part)
            output.append(part)
        }
        return output
    }

    private func reloadLexiconGrid() {
        for view in lexiconGrid.subviews {
            view.removeFromSuperview()
        }
        let terms: [String]
        switch currentLexiconFilter {
        case .all:
            terms = allLexiconProvider()
        case .learned:
            terms = learnedLexiconProvider()
        case .manual:
            terms = manualLexiconProvider()
        }
        for term in terms {
            let cell = LexiconTermCellView(term: term, delegate: self)
            lexiconGrid.addSubview(cell)
        }
        lexiconGrid.needsLayout = true
    }

    @objc
    private func reapplyPermissionsTapped() {
        onReapplyPermissions()
        showTransientSuccessMessage("已触发权限申请", anchorView: reapplyPermissionsButton)
    }

    @objc
    private func downloadLocalASRAssets() {
        let snapshot = LocalASRAssetManager.shared.snapshot
        guard snapshot.canStartInstall else { return }

        LocalASRAssetManager.shared.beginInstall { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let updatedSnapshot):
                self.updateLocalASRCard(snapshot: updatedSnapshot)
                if updatedSnapshot.kind == .ready, self.window?.isVisible == true {
                    self.showTransientSuccessMessage("本地模型已经准备好了", anchorView: self.localASRPrimaryButton)
                }
            case .failure:
                self.presentLocalASRActionAlert(
                    title: "本地模型下载失败",
                    message: LocalASRAssetManager.shared.snapshot.detail
                )
            }
        }
    }

    @objc
    private func deleteLocalASRAssets() {
        let snapshot = LocalASRAssetManager.shared.snapshot
        guard snapshot.canDelete else { return }

        let alert = NSAlert()
        alert.messageText = "删除本地模型"
        alert.informativeText = "删除后，本地识别和本地实时预览会立即不可用；云端 API 设置不会受影响。确认继续吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        LocalASRAssetManager.shared.removeUserManagedAssets { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let updatedSnapshot):
                self.updateLocalASRCard(snapshot: updatedSnapshot)
                if self.window?.isVisible == true {
                    self.showTransientSuccessMessage("本地模型已删除", anchorView: self.localASRPrimaryButton)
                }
            case .failure:
                self.presentLocalASRActionAlert(
                    title: "删除本地模型失败",
                    message: LocalASRAssetManager.shared.snapshot.detail
                )
            }
        }
    }

    @objc
    private func clearAllHistoryTapped() {
        let alert = NSAlert()
        alert.messageText = "清除所有历史"
        alert.informativeText = "确认要清除所有输入历史吗？此操作无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return }
        
        onClearAllHistory()
        historyInputRecords = []
        historyInputPageIndex = 0
        reloadHistoryInputList()
        refreshWeeklyUsageChart()
        showTransientSuccessMessage("已清除所有历史", anchorView: historyListContainer)
    }

    @objc
    private func openAudioCacheDirectoryFromHistoryTapped() {
        onOpenAudioCacheDirectory()
    }


    @objc
    private func clearAudioCacheFromHistoryTapped() {
        showAudioCacheClearResult(anchorView: historyClearAudioCacheButton)
    }

    @objc
    private func showPreviousHistoryInputPage() {
        guard historyInputPageIndex > 0 else { return }
        historyInputPageIndex -= 1
        reloadHistoryInputList()
    }

    @objc
    private func showNextHistoryInputPage() {
        let nextPageIndex = historyInputPageIndex + 1
        guard nextPageIndex < historyInputPageCount() else { return }
        historyInputPageIndex = nextPageIndex
        reloadHistoryInputList()
    }

    @objc
    private func copyHistoryInputRecord(_ sender: NSButton) {
        guard let recordID = sender.identifier?.rawValue,
              let record = historyInputRecords.first(where: { $0.id == recordID }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
        showTransientSuccessMessage("已复制", anchorView: sender)
    }

    @objc
    private func deleteHistoryInputRecord(_ sender: NSButton) {
        guard let recordID = sender.identifier?.rawValue else { return }
        historyInputRecords.removeAll { $0.id == recordID }
        persistHistoryInputRecords(historyInputRecords)
        reloadHistoryInputList()
        refreshWeeklyUsageChart()
    }

    private func showAudioCacheClearResult(anchorView: NSView) {
        let removed = onClearAudioCacheFiles()
        let message = removed > 0 ? "已清理 \(removed) 个缓存文件" : "无可清理缓存（或录音中）"
        showTransientSuccessMessage(message, anchorView: anchorView)
    }

    private func presentLocalASRActionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc
    private func openCloudLogsViewer() {
        if cloudLogViewer == nil {
            cloudLogViewer = CloudLogViewerWindowController(
                logsProvider: { [weak self] in
                    self?.settings.stringArray(forKey: SettingsKeys.cloudRequestLogs, default: []) ?? []
                },
                onLogsUpdated: { [weak self] logs in
                    self?.settings.set(logs, forKey: SettingsKeys.cloudRequestLogs)
                    self?.syncFromSettings()
                }
            )
        }
        cloudLogViewer?.showPanel(relativeTo: window)
    }

    @objc
    private func beginCapturePrimaryShortcut() {
        beginShortcutCapture(target: .primary)
    }

    @objc
    private func clearPrimaryShortcut() {
        settings.set(ShortcutBinding.disabledToken, forKey: SettingsKeys.shortcutHoldToTalk)
        onShortcutSettingsChanged()
        updateShortcutDisplay()
        showTransientSuccessMessage("已关闭语音输入快捷键", anchorView: primaryShortcutClearButton)
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func beginShortcutCapture(target: ShortcutCaptureTarget) {
        finishShortcutCapture(cancelled: true)
        shortcutCaptureTarget = target
        primaryShortcutValueLabel.stringValue = "按下快捷键..."
        overviewShortcutCard.valueLabel.stringValue = "按下快捷键..."
        overviewShortcutPillLabel.stringValue = "快捷键：录制中"

        shortcutCaptureLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.shortcutCaptureTarget != nil else { return event }
            if self.handleShortcutCaptureEvent(event) {
                return nil
            }
            return event
        }
    }

    private func finishShortcutCapture(cancelled: Bool) {
        if let shortcutCaptureLocalMonitor {
            NSEvent.removeMonitor(shortcutCaptureLocalMonitor)
            self.shortcutCaptureLocalMonitor = nil
        }
        if cancelled {
            updateShortcutDisplay()
        }
        shortcutCaptureTarget = nil
    }

    private func handleShortcutCaptureEvent(_ event: NSEvent) -> Bool {
        guard let target = shortcutCaptureTarget else { return false }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { // Esc
                finishShortcutCapture(cancelled: true)
                return true
            }
            let binding = ShortcutBinding(
                kind: .combo,
                keyCode: event.keyCode,
                modifiers: normalizedShortcutFlags(event.modifierFlags)
            )
            commitShortcutCapture(binding, target: target)
            return true
        case .flagsChanged:
            guard let modifierFlag = modifierFlag(forKeyCode: event.keyCode) else {
                return false
            }
            let isDown = normalizedShortcutFlags(event.modifierFlags).contains(modifierFlag)
            guard isDown else { return true }
            let binding = ShortcutBinding(kind: .modifier, keyCode: event.keyCode, modifiers: [])
            commitShortcutCapture(binding, target: target)
            return true
        default:
            return false
        }
    }

    private func commitShortcutCapture(_ binding: ShortcutBinding, target: ShortcutCaptureTarget) {
        guard target == .primary else { return }
        settings.set(binding.serialized(), forKey: SettingsKeys.shortcutHoldToTalk)
        onShortcutSettingsChanged()
        finishShortcutCapture(cancelled: false)
        updateShortcutDisplay()
    }

    private func index(for style: PunctuationStyle) -> Int {
        switch style {
        case .auto:
            return 0
        case .chinese:
            return 1
        case .english:
            return 2
        }
    }

    private func style(for index: Int) -> PunctuationStyle {
        switch index {
        case 1:
            return .chinese
        case 2:
            return .english
        default:
            return .auto
        }
    }

    private func index(for model: ASRModelSize) -> Int {
        switch model {
        case .tiny:
            return 0
        case .small:
            return 1
        }
    }

    private func modelSize(for index: Int) -> ASRModelSize {
        switch index {
        case 0:
            return .tiny
        default:
            return .small
        }
    }

    private func index(for mode: RecognitionMode) -> Int {
        switch mode {
        case .local:
            return 0
        case .cloud:
            return 1
        case .hybrid, .auto:
            return 2
        }
    }

    private func recognitionMode(for index: Int) -> RecognitionMode {
        switch index {
        case 1:
            return .cloud
        case 2:
            return .hybrid
        default:
            return .local
        }
    }

    private func resolvedRecognitionMode(from rawValue: String) -> RecognitionMode {
        let mode = RecognitionMode(rawValue: rawValue) ?? .local
        if mode == .auto {
            settings.set(RecognitionMode.hybrid.rawValue, forKey: SettingsKeys.recognitionMode)
            return .hybrid
        }
        return mode
    }

    private func isPreviewSourceForcedToLocal(for mode: RecognitionMode) -> Bool {
        mode == .local || mode == .hybrid || mode == .auto
    }

    private func isPreviewSourceConfigurable(for mode: RecognitionMode) -> Bool {
        mode == .cloud
    }

    private func updateLiveOutputAvailability(
        recognitionMode: RecognitionMode,
        livePreviewEnabled: Bool,
        livePreviewSource: LivePreviewSource
    ) {
        _ = recognitionMode
        _ = livePreviewEnabled
        _ = livePreviewSource
        liveOutputPopup.selectedSegment = 0
        liveOutputPopup.isEnabled = false
    }

    private func index(for source: LivePreviewSource) -> Int {
        switch source {
        case .local:
            return 0
        case .cloud:
            return 1
        }
    }

    private func livePreviewSource(for index: Int) -> LivePreviewSource {
        switch index {
        case 1:
            return .cloud
        default:
            return .local
        }
    }

    private func index(for limit: RecordingDurationLimit) -> Int {
        switch limit {
        case .s60:
            return 0
        case .s120:
            return 1
        case .s180:
            return 2
        case .unlimited:
            return 3
        }
    }

    private func recordingLimit(for index: Int) -> RecordingDurationLimit {
        switch index {
        case 0:
            return .s60
        case 1:
            return .s120
        case 2:
            return .s180
        default:
            return .unlimited
        }
    }

    private func index(for mode: ChineseScriptMode) -> Int {
        switch mode {
        case .simplified:
            return 0
        case .traditional:
            return 1
        }
    }

    private func chineseScriptMode(for index: Int) -> ChineseScriptMode {
        switch index {
        case 1:
            return .traditional
        default:
            return .simplified
        }
    }

    private func index(for policy: HistoryRetentionPolicy) -> Int {
        switch policy {
        case .never:
            return 0
        case .h24:
            return 1
        case .w1:
            return 2
        case .m1:
            return 3
        case .forever:
            return 4
        }
    }

    private func historyRetentionPolicy(for index: Int) -> HistoryRetentionPolicy {
        switch index {
        case 0:
            return .never
        case 1:
            return .h24
        case 2:
            return .w1
        case 3:
            return .m1
        default:
            return .forever
        }
    }

    private func parseBlacklistInput(_ input: String) -> [String] {
        let pieces = input
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var output: [String] = []
        var seen: Set<String> = []
        for piece in pieces where !seen.contains(piece) {
            seen.insert(piece)
            output.append(piece)
        }
        return output
    }

    private func parseHistoryInputRecords(_ lines: [String]) -> [HistoryInputRecord] {
        var records: [HistoryInputRecord] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let text = json["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let id = (json["id"] as? String) ?? UUID().uuidString
            let timestampText = (json["timestamp"] as? String) ?? ""
            let timestamp = Self.historyDateFormatter.date(from: timestampText) ?? Date.distantPast
            records.append(HistoryInputRecord(id: id, timestamp: timestamp, text: text))
        }
        return records
    }

    private func pruneHistoryInputRecords(
        _ records: [HistoryInputRecord],
        policy: HistoryRetentionPolicy
    ) -> [HistoryInputRecord] {
        guard let days = policy.retentionDays else { return records }
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        return records.filter { $0.timestamp >= cutoff }
    }

    private func persistHistoryInputRecords(_ records: [HistoryInputRecord]) {
        let lines = records.compactMap { record -> String? in
            let payload: [String: String] = [
                "id": record.id,
                "timestamp": Self.historyDateFormatter.string(from: record.timestamp),
                "text": record.text
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let line = String(data: data, encoding: .utf8) else {
                return nil
            }
            return line
        }
        settings.set(lines, forKey: SettingsKeys.historyInputRecords)
    }

    private func reloadHistoryInputList() {
        for view in historyListContainer.arrangedSubviews {
            historyListContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        clampHistoryInputPageIndex()

        guard !historyInputRecords.isEmpty else {
            let emptyLabel = NSTextField(labelWithString: "暂无历史输入记录")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .secondaryLabelColor
            historyListContainer.addArrangedSubview(emptyLabel)
            updateHistoryPaginationControls()
            return
        }

        let startIndex = historyInputPageIndex * Self.historyInputRecordsPerPage
        let endIndex = min(startIndex + Self.historyInputRecordsPerPage, historyInputRecords.count)
        let recordsToRender = Array(historyInputRecords[startIndex..<endIndex])
        for record in recordsToRender {
            let row = makeHistoryInputRow(record)
            historyListContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: historyListContainer.widthAnchor).isActive = true
        }

        updateHistoryPaginationControls()
    }

    private func historyInputPageCount() -> Int {
        guard !historyInputRecords.isEmpty else { return 0 }
        return (historyInputRecords.count + Self.historyInputRecordsPerPage - 1) / Self.historyInputRecordsPerPage
    }

    private func clampHistoryInputPageIndex() {
        let lastPageIndex = max(historyInputPageCount() - 1, 0)
        historyInputPageIndex = min(max(historyInputPageIndex, 0), lastPageIndex)
    }

    private func updateHistoryPaginationControls() {
        let pageCount = historyInputPageCount()
        let totalCount = historyInputRecords.count
        let hasRecords = totalCount > 0

        historyPreviousPageButton.isEnabled = hasRecords && historyInputPageIndex > 0
        historyNextPageButton.isEnabled = hasRecords && historyInputPageIndex < pageCount - 1

        guard hasRecords else {
            historyPaginationInfoLabel.stringValue = "共 0 条"
            return
        }

        let startNumber = historyInputPageIndex * Self.historyInputRecordsPerPage + 1
        let endNumber = min(startNumber + Self.historyInputRecordsPerPage - 1, totalCount)
        historyPaginationInfoLabel.stringValue = "第 \(historyInputPageIndex + 1) / \(pageCount) 页，显示 \(startNumber)-\(endNumber) 条，共 \(totalCount) 条"
    }

    private func makeHistoryInputRow(_ record: HistoryInputRecord) -> NSView {
        let timestampLabel = NSTextField(labelWithString: formattedHistoryTimestamp(record.timestamp))
        timestampLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timestampLabel.textColor = .secondaryLabelColor

        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyHistoryInputRecord(_:)))
        copyButton.controlSize = .small
        copyButton.bezelStyle = .rounded
        copyButton.identifier = NSUserInterfaceItemIdentifier(record.id)
        styleSecondaryButton(copyButton)
        copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteHistoryInputRecord(_:)))
        deleteButton.controlSize = .small
        deleteButton.bezelStyle = .rounded
        deleteButton.identifier = NSUserInterfaceItemIdentifier(record.id)
        styleSecondaryButton(deleteButton)
        deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [timestampLabel, spacer, copyButton, deleteButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 6
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let textLabel = NSTextField(wrappingLabelWithString: record.text)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .labelColor
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping

        let body = NSStackView(views: [topRow, textLabel])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false

        topRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let row = NSBox()
        row.titlePosition = .noTitle
        row.boxType = .custom
        row.cornerRadius = 8
        row.borderWidth = 1
        row.borderColor = NSColor.separatorColor.withAlphaComponent(0.25)
        row.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        row.contentViewMargins = NSSize(width: 10, height: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.contentView?.addSubview(body)

        if let content = row.contentView {
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                body.topAnchor.constraint(equalTo: content.topAnchor),
                body.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        return row
    }

    private func formattedHistoryTimestamp(_ date: Date) -> String {
        guard date != .distantPast else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func updateHistoryOverview(
        totalDurationSeconds: Double,
        requestCount: Int,
        totalCharacters: Int,
        unit: HistoryDurationUnit
    ) {
        historyDurationValueLabel.stringValue = formattedDuration(totalDurationSeconds, unit: unit)
        if requestCount > 0 {
            let avgSeconds = totalDurationSeconds / Double(requestCount)
            historyDurationDetailLabel.stringValue = "共\(requestCount)次，单次平均\(String(format: "%.1f", avgSeconds))秒"
        } else {
            historyDurationDetailLabel.stringValue = "暂无语音时长记录"
        }

        historyCharactersValueLabel.stringValue = "\(formattedCharacterCount(totalCharacters)) 字"
        historyCharactersDetailLabel.stringValue = totalCharacters > 0
            ? "累计口述字符"
            : "暂无口述字数记录"
    }

    private func formattedDuration(_ totalSeconds: Double, unit: HistoryDurationUnit) -> String {
        let seconds = max(0, totalSeconds)
        switch unit {
        case .minutes:
            return "\(Int((seconds / 60.0).rounded())) 分"
        case .hours:
            return String(format: "%.1f 小时", seconds / 3600.0)
        }
    }

    private func formattedCharacterCount(_ count: Int) -> String {
        let value = max(0, count)
        guard value >= 1000 else { return "\(value)" }
        let kilo = Double(value) / 1000.0
        let formatted = String(format: "%.1fk", kilo)
        return formatted.replacingOccurrences(of: ".0k", with: "k")
    }

    private func summarizePipelineLogs(_ lines: [String]) -> (totalTextLength: Int, totalRecordingSeconds: Double, recordingCount: Int) {
        var totalTextLength = 0
        var totalRecordingSeconds = 0.0
        var recordingCount = 0

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                continue
            }
            if let value = json["textLength"] as? Int {
                totalTextLength += max(0, value)
            } else if let value = json["textLength"] as? NSNumber {
                totalTextLength += max(0, value.intValue)
            }

            if let value = json["recordingSeconds"] as? Double {
                totalRecordingSeconds += max(0, value)
                recordingCount += 1
            } else if let value = json["recordingSeconds"] as? NSNumber {
                totalRecordingSeconds += max(0, value.doubleValue)
                recordingCount += 1
            }
        }

        return (totalTextLength, totalRecordingSeconds, recordingCount)
    }

    @objc
    private func openAPISettings() {
        let dialog = APISettingsModalController(
            initialDraft: currentAPISettingsDraft(),
            validateDraft: { [weak self] draft, allowEmptyEndpoint in
                self?.validateAPISettingsDraft(draft, allowEmptyEndpoint: allowEmptyEndpoint)
            },
            runConnectionTest: { [weak self] draft, completion in
                self?.performAPIConnectionTest(with: draft, completion: completion)
            }
        )

        switch dialog.runModal() {
        case .cancel:
            return
        case .save(let draft):
            applyAPISettingsDraft(draft)
            showTransientSuccessMessage("API设置已保存", anchorView: apiSettingsButton)
        }
    }

    private func currentAPISettingsDraft() -> APISettingsDraft {
        APISettingsDraft(
            endpoint: settings.string(forKey: SettingsKeys.cloudAPIEndpoint, default: ""),
            appKey: settings.string(forKey: SettingsKeys.cloudAPIAppKey, default: ""),
            apiKey: settings.string(forKey: SettingsKeys.cloudAPIKey, default: ""),
            model: settings.string(forKey: SettingsKeys.cloudAPIModel, default: "whisper-1"),
            resourceID: settings.string(forKey: SettingsKeys.cloudAPIResourceID, default: "volc.bigasr.auc_turbo"),
            pricePerMinute: settings.string(forKey: SettingsKeys.cloudAPIPricePerMinute, default: "0")
        )
    }

    private func applyAPISettingsDraft(_ draft: APISettingsDraft) {
        settings.set(draft.endpoint, forKey: SettingsKeys.cloudAPIEndpoint)
        settings.set(draft.appKey, forKey: SettingsKeys.cloudAPIAppKey)
        settings.set(draft.apiKey, forKey: SettingsKeys.cloudAPIKey)
        settings.set(draft.model, forKey: SettingsKeys.cloudAPIModel)
        settings.set(draft.resourceID, forKey: SettingsKeys.cloudAPIResourceID)
        settings.set(draft.pricePerMinute, forKey: SettingsKeys.cloudAPIPricePerMinute)
    }

    private func validateAPISettingsDraft(_ draft: APISettingsDraft, allowEmptyEndpoint: Bool) -> String? {
        let endpointValue = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpointValue.isEmpty {
            return allowEmptyEndpoint ? nil : "请先填写接口 URL。"
        }

        guard let url = URL(string: endpointValue),
              let scheme = url.scheme?.lowercased() else {
            return "接口 URL 格式不正确。请检查是否带了完整的协议头，例如 http://、https:// 或 wss://。"
        }

        if scheme == "ws" || scheme == "wss" {
            guard isDoubaoWebSocketEndpoint(url) else {
                return "当前只有豆包流式接口支持 ws / wss。请填写 openspeech.bytedance.com 下的 /api/v3/sauc/bigmodel 或 bigmodel_async 地址。"
            }
            if draft.appKey.isEmpty {
                return "这是豆包流式接口，请填写 APP ID（AppKey）。"
            }
            if draft.apiKey.isEmpty {
                return "这是豆包流式接口，请填写 Access Key / API Key。"
            }
            return nil
        }

        guard scheme == "http" || scheme == "https" else {
            return "接口协议暂不支持。当前可用的是 http / https，以及豆包专用的 wss。"
        }

        if isDoubaoHost(url) {
            guard isSupportedDoubaoHTTPPath(url) else {
                return "豆包 HTTP 地址暂只支持 /api/v3/auc/bigmodel/* 或 /api/v3/sauc/bigmodel*。"
            }
            if draft.appKey.isEmpty {
                return "这是豆包接口，请填写 APP ID（AppKey）。"
            }
            if draft.apiKey.isEmpty {
                return "这是豆包接口，请填写 Access Key / API Key。"
            }
        }

        return nil
    }

    private func performAPIConnectionTest(
        with draft: APISettingsDraft,
        completion: @Sendable @escaping (APIConnectionTestFeedback) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let audioURL: URL
            do {
                audioURL = try self.createAPITestAudioFileURL()
            } catch {
                completion(
                    APIConnectionTestFeedback(
                        kind: .failure,
                        title: "测试没有跑起来",
                        detail: self.userFacingAudioGenerationMessage(for: error)
                    )
                )
                return
            }

            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            let tempSettings = InMemorySettingsStore()
            tempSettings.set(draft.endpoint, forKey: SettingsKeys.cloudAPIEndpoint)
            tempSettings.set(draft.appKey, forKey: SettingsKeys.cloudAPIAppKey)
            tempSettings.set(draft.apiKey, forKey: SettingsKeys.cloudAPIKey)
            tempSettings.set(draft.model, forKey: SettingsKeys.cloudAPIModel)
            tempSettings.set(draft.resourceID, forKey: SettingsKeys.cloudAPIResourceID)
            tempSettings.set(draft.pricePerMinute, forKey: SettingsKeys.cloudAPIPricePerMinute)

            let engine = CloudASREngine(settings: tempSettings)
            do {
                let result = try engine.transcribe(audioFileURL: audioURL)
                let route = self.userFacingConnectionRoute(for: result.engineRoute)
                let preview = self.compactStatusSnippet(from: result.rawText, limit: 44)
                let detail = preview.isEmpty
                    ? "已按\(route)完成连通性验证，接口返回正常。现在可以保存设置开始使用。"
                    : "已按\(route)完成连通性验证，接口返回正常，测试识别结果是“\(preview)”（约 \(result.latencyMs) ms）。现在可以保存设置开始使用。"
                completion(
                    APIConnectionTestFeedback(
                        kind: .success,
                        title: "恭喜，连接成功",
                        detail: detail
                    )
                )
            } catch {
                completion(self.userFacingConnectionFailure(for: error, draft: draft))
            }
        }
    }

    private nonisolated func createAPITestAudioFileURL() throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mytype-api-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            "-o", outputURL.path,
            "This is a MyType connection test."
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw NSError(
                domain: "MyType.APISettings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
            )
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MyType.APISettings",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderrText?.isEmpty == false ? stderrText! : "系统语音合成返回了非 0 状态。"]
            )
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw NSError(
                domain: "MyType.APISettings",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "系统没有生成测试音频文件。"]
            )
        }

        return outputURL
    }

    private nonisolated func userFacingAudioGenerationMessage(for error: Error) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "系统没有成功生成测试语音，所以这次还没开始真正连 API。请稍后再试。"
        }
        return "系统没有成功生成测试语音，所以这次还没开始真正连 API。原始原因：\(raw)"
    }

    private nonisolated func userFacingConnectionRoute(for route: String) -> String {
        let lower = route.lowercased()
        if lower.contains("doubao") && lower.contains("sauc") {
            return "豆包流式接口"
        }
        if lower.contains("doubao") && lower.contains("flash") {
            return "豆包文件识别接口"
        }
        if lower == "cloud_http_post" {
            return "通用 HTTP 接口"
        }
        return "云端接口"
    }

    private nonisolated func compactStatusSnippet(from text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<index]) + "…"
    }

    private nonisolated func userFacingConnectionFailure(
        for error: Error,
        draft: APISettingsDraft
    ) -> APIConnectionTestFeedback {
        if let cloudError = error as? CloudASREngineError {
            switch cloudError {
            case .invalidEndpoint:
                return APIConnectionTestFeedback(
                    kind: .failure,
                    title: "接口 URL 写错了",
                    detail: "请检查地址是否完整，是否带了 http://、https:// 或 wss://。"
                )
            case .unsupportedEndpointScheme:
                return APIConnectionTestFeedback(
                    kind: .failure,
                    title: "接口协议暂不支持",
                    detail: "当前只支持 http / https，以及豆包专用的 wss 流式地址。"
                )
            case .missingConfiguration(let message):
                return APIConnectionTestFeedback(
                    kind: .failure,
                    title: "配置还没填完整",
                    detail: userFacingMissingConfigurationMessage(message, endpoint: draft.endpoint)
                )
            case .audioReadFailed(let details):
                return APIConnectionTestFeedback(
                    kind: .failure,
                    title: "测试音频读取失败",
                    detail: "系统生成了测试语音，但读取时失败了：\(details)"
                )
            case .requestFailed(let details):
                return userFacingRequestFailure(details, endpoint: draft.endpoint)
            case .httpStatus(let code, let body):
                return userFacingHTTPFailure(code: code, body: body, endpoint: draft.endpoint)
            case .invalidResponse(let details):
                return userFacingInvalidResponse(details)
            }
        }

        let raw = compactStatusSnippet(from: error.localizedDescription, limit: 180)
        return APIConnectionTestFeedback(
            kind: .failure,
            title: "连接测试失败",
            detail: raw.isEmpty ? "发生了一个未预期的问题，请稍后重试。" : raw
        )
    }

    private nonisolated func userFacingMissingConfigurationMessage(_ raw: String, endpoint: String) -> String {
        let lowered = raw.lowercased()
        if lowered.contains("endpoint") {
            return "请先填写接口 URL。"
        }
        if lowered.contains("app_key") || lowered.contains("app key") {
            return isDoubaoEndpointString(endpoint)
                ? "这是豆包接口，请填写 APP ID（AppKey）。"
                : "当前接口要求额外的 App Key，但你还没填。"
        }
        if lowered.contains("access_key") || lowered.contains("access key") {
            return isDoubaoEndpointString(endpoint)
                ? "这是豆包接口，请填写 Access Key。"
                : "请先填写 Access Key / API Key。"
        }
        return "还有必要配置项没填完整：\(raw)"
    }

    private nonisolated func userFacingRequestFailure(_ details: String, endpoint: String) -> APIConnectionTestFeedback {
        let lower = details.lowercased()
        if lower.contains("timed out") || lower.contains("超时") {
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "连接超时了",
                detail: "接口地址可能可达，但响应太慢，或者当前网络不稳定。请检查网络、代理或服务端状态。"
            )
        }
        if lower.contains("host could not be found")
            || lower.contains("could not resolve")
            || lower.contains("找不到")
            || lower.contains("解析") {
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "域名没找到",
                detail: "这个地址看起来像是写错了，或者当前网络无法解析它。请重点检查接口 URL。"
            )
        }
        if lower.contains("not connected to the internet")
            || lower.contains("network connection was lost")
            || lower.contains("offline")
            || lower.contains("无法连接到互联网") {
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "网络没有连上",
                detail: "MyType 没能把请求发出去。请检查本机网络、VPN 或代理设置。"
            )
        }
        if lower.contains("ssl")
            || lower.contains("tls")
            || lower.contains("secure connection")
            || lower.contains("证书") {
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "HTTPS 连接有问题",
                detail: "目标服务的证书或 TLS 握手失败了。请检查是不是内网证书、自签名证书，或地址协议写错。"
            )
        }

        let authHint = isDoubaoEndpointString(endpoint)
            ? "如果你填的是豆包，请检查 APP ID、Access Key 和 resource_id 是否对应同一个已开通资源。"
            : "如果这不是标准 Bearer Token 鉴权接口，当前通用模式可能还不兼容它的鉴权方式。"
        return APIConnectionTestFeedback(
            kind: .failure,
            title: "请求没发成功",
            detail: "\(authHint) 原始错误：\(compactStatusSnippet(from: details, limit: 150))"
        )
    }

    private nonisolated func userFacingHTTPFailure(code: Int, body: String, endpoint: String) -> APIConnectionTestFeedback {
        let snippet = compactStatusSnippet(from: body, limit: 170)
        let lower = body.lowercased()

        if code == 400 || code == 403 {
            let resourceMentioned = lower.contains("resourceid")
                || lower.contains("resource id")
                || lower.contains("resource_id")
                || lower.contains("resource")
            let deniedSemantics = lower.contains("not allowed")
                || lower.contains("is not allowed")
                || lower.contains("not granted")
                || lower.contains("未开通")
                || lower.contains("无权限")
            if lower.contains("requested resource not granted") || (resourceMentioned && deniedSemantics) {
                return APIConnectionTestFeedback(
                    kind: .failure,
                    title: "豆包资源权限不对",
                    detail: "接口地址和鉴权大概率已经通了，但当前 resource_id 没开通，或者它和账号不匹配。请到豆包/火山控制台检查资源权限。"
                )
            }
        }

        switch code {
        case 400:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口收到了请求，但不接受这种格式",
                detail: isDoubaoEndpointString(endpoint)
                    ? "豆包已经响应了请求，但参数不被当前接口接受。请检查地址路径、模型名和 resource_id。服务端返回：\(snippet)"
                    : "接口已经连通，但当前请求格式不被它接受。MyType 的通用模式会发送 JSON 字段 model、audio_base64、audio_format。服务端返回：\(snippet)"
            )
        case 401:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "鉴权失败了",
                detail: isDoubaoEndpointString(endpoint)
                    ? "请检查 APP ID、Access Key 和 resource_id 是否正确。服务端返回：\(snippet)"
                    : "请检查 API Key 是否正确；如果你的接口不是 Bearer Token 鉴权，当前通用模式可能不兼容。服务端返回：\(snippet)"
            )
        case 403:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口拒绝了这次调用",
                detail: "通常是权限、账号范围或资源授权问题。服务端返回：\(snippet)"
            )
        case 404:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口地址不存在",
                detail: "这个 URL 的路径大概率写错了。请重点检查 endpoint 的 host 和 path。"
            )
        case 405:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口不接受当前请求方法",
                detail: "MyType 会用 POST 请求发起识别。这个地址返回 405，说明它可能不是正确的转写入口。"
            )
        case 415:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口不接受当前内容类型",
                detail: "MyType 当前会发送 JSON。这个接口似乎要求别的内容类型，比如 multipart/form-data。"
            )
        case 429:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口限流了",
                detail: "账号额度、并发或频率限制触发了。请稍后再试，或检查服务端配额。"
            )
        case 500...599:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "服务端暂时异常",
                detail: "网络已经通了，但服务端返回了 \(code)。可以稍后重试。服务端返回：\(snippet)"
            )
        default:
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口返回了异常状态",
                detail: "HTTP \(code)。服务端返回：\(snippet)"
            )
        }
    }

    private nonisolated func userFacingInvalidResponse(_ details: String) -> APIConnectionTestFeedback {
        let lower = details.lowercased()
        if lower.contains("response is not json object") {
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口通了，但返回的不是 JSON",
                detail: "MyType 当前通用模式要求接口返回 JSON。请检查这个地址是不是正确的识别 API，而不是网页或别的服务。"
            )
        }
        if lower.contains("missing 'text' field") {
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口通了，但返回格式暂不兼容",
                detail: "MyType 当前读取 `text`、`result.text` 或 `choices[0].text`。这个接口虽然响应了，但返回里没有这些字段。"
            )
        }
        if lower.contains("non-http response") {
            return APIConnectionTestFeedback(
                kind: .failure,
                title: "接口响应格式异常",
                detail: "这次返回不是标准的 HTTP 响应。请检查是不是把 ws / wss 地址填到了通用 HTTP 模式里。"
            )
        }
        return APIConnectionTestFeedback(
            kind: .failure,
            title: "接口返回了无法识别的内容",
            detail: "MyType 收到了响应，但还读不懂它的格式。原始说明：\(compactStatusSnippet(from: details, limit: 150))"
        )
    }

    private nonisolated func isDoubaoEndpointString(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        return isDoubaoHost(url)
    }

    private nonisolated func isDoubaoWebSocketEndpoint(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host.contains("openspeech.bytedance.com")
            && (path.contains("/api/v3/sauc/bigmodel") || path.contains("/api/v3/sauc/bigmodel_async"))
    }

    private nonisolated func isDoubaoHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("openspeech.bytedance.com")
    }

    private nonisolated func isSupportedDoubaoHTTPPath(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/api/v3/auc/bigmodel/")
            || path.contains("/api/v3/sauc/bigmodel")
    }

    private func showAPIEndpointValidationAlert(_ endpoint: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "接口 URL 不可用"
        alert.informativeText = "当前支持：\n1) http/https 的 POST JSON 接口\n2) 豆包 wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async\n3) 豆包 https://openspeech.bytedance.com/api/v3/auc/bigmodel/*\n你输入的是：\(endpoint)"
        alert.addButton(withTitle: "我知道了")
        alert.runModal()
    }

    private func showTransientSuccessMessage(_ text: String, anchorView: NSView) {
        transientSuccessPopover?.close()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 44))
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let controller = NSViewController()
        controller.view = container

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = container.frame.size
        popover.contentViewController = controller
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)

        transientSuccessPopover = popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.transientSuccessPopover?.close()
            self?.transientSuccessPopover = nil
        }
    }
}

extension SettingsPanelController: LexiconTermCellDelegate {
    func didTapDelete(for term: String) {
        onDeleteManualLexiconTerm(term)
        reloadLexiconGrid()
    }
}
