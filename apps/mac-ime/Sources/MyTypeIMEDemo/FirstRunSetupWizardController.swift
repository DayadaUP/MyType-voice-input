import AppKit
import Common

@MainActor
final class FirstRunSetupWizardController: NSObject, NSWindowDelegate {
    enum EntryPoint {
        case fullLaunch
        case resume
        case localPackSelection
    }

    private enum Step {
        case welcome
        case permissions
        case localChoice
        case packSelection
        case installing
        case completion
    }

    private let permissionStateProvider: () -> MyTypePermissionState
    private let requestAccessibilityPermission: () -> Void
    private let requestInputMonitoringPermission: () -> Void
    private let requestMicrophonePermission: () -> Void
    private let shortcutNeedsAttentionProvider: () -> Bool
    private let routeReadinessProvider: () -> MyTypeRecognitionRouteReadiness
    private let onSetupStateChanged: (MyTypeSetupState) -> Void
    private let onLocalPackInstalled: (LocalModelPack) -> Void
    private let onFinish: () -> Void

    private let panel: NSPanel
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyContainer = NSView(frame: .zero)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    private let welcomeBody = NSStackView(frame: .zero)
    private let permissionBody = NSStackView(frame: .zero)
    private let localChoiceBody = NSStackView(frame: .zero)
    private let packSelectionBody = NSStackView(frame: .zero)
    private let installingBody = NSStackView(frame: .zero)
    private let completionBody = NSStackView(frame: .zero)

    private let permissionHintLabel = NSTextField(wrappingLabelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let inputMonitoringStatusLabel = NSTextField(labelWithString: "")
    private let microphoneStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityButton = NSButton(title: "去授权", target: nil, action: nil)
    private let inputMonitoringButton = NSButton(title: "去授权", target: nil, action: nil)
    private let microphoneButton = NSButton(title: "去授权", target: nil, action: nil)

    private let quickPackButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let recommendedPackButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let installProgressIndicator = NSProgressIndicator(frame: .zero)
    private let installStatusLabel = NSTextField(labelWithString: "")
    private let installDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let completionHintLabel = NSTextField(wrappingLabelWithString: "")

    private let entryPoint: EntryPoint
    private var currentStep: Step
    private var selectedPack: LocalModelPack = .recommended
    private var installFailed = false
    private var installRunning = false
    private var shouldDeferAfterCancellation = false
    private var shouldCloseAfterCancellation = false

    init(
        entryPoint: EntryPoint,
        permissionStateProvider: @escaping () -> MyTypePermissionState,
        requestAccessibilityPermission: @escaping () -> Void,
        requestInputMonitoringPermission: @escaping () -> Void,
        requestMicrophonePermission: @escaping () -> Void,
        shortcutNeedsAttentionProvider: @escaping () -> Bool,
        routeReadinessProvider: @escaping () -> MyTypeRecognitionRouteReadiness,
        onSetupStateChanged: @escaping (MyTypeSetupState) -> Void,
        onLocalPackInstalled: @escaping (LocalModelPack) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.entryPoint = entryPoint
        self.permissionStateProvider = permissionStateProvider
        self.requestAccessibilityPermission = requestAccessibilityPermission
        self.requestInputMonitoringPermission = requestInputMonitoringPermission
        self.requestMicrophonePermission = requestMicrophonePermission
        self.shortcutNeedsAttentionProvider = shortcutNeedsAttentionProvider
        self.routeReadinessProvider = routeReadinessProvider
        self.onSetupStateChanged = onSetupStateChanged
        self.onLocalPackInstalled = onLocalPackInstalled
        self.onFinish = onFinish
        self.currentStep = FirstRunSetupWizardController.initialStep(
            for: entryPoint,
            permissionState: permissionStateProvider(),
            routeReadiness: routeReadinessProvider()
        )

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        MyTypeAppearance.applyFixedLightAppearance(to: panel)
        panel.title = "MyType 初始化设置"
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        super.init()

        panel.delegate = self
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        configureUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLocalASRStateNotification(_:)),
            name: LocalASRAssetManager.stateDidChangeNotification,
            object: LocalASRAssetManager.shared
        )

        renderCurrentStep()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        panel.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onFinish()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if currentStep == .installing, installRunning {
            shouldCloseAfterCancellation = true
            shouldDeferAfterCancellation = true
            LocalASRAssetManager.shared.cancelActiveInstall()
            return false
        }
        return true
    }

    private static func initialStep(
        for entryPoint: EntryPoint,
        permissionState: MyTypePermissionState,
        routeReadiness: MyTypeRecognitionRouteReadiness
    ) -> Step {
        switch entryPoint {
        case .fullLaunch:
            return .welcome
        case .resume:
            if !permissionState.hasAllRequiredPermissions {
                return .permissions
            }
            return routeReadiness.localReady ? .completion : .localChoice
        case .localPackSelection:
            return .packSelection
        }
    }

    private func configureUI() {
        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        panel.contentView = root

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: "waveform.badge.mic",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 34, weight: .semibold))
        iconView.contentTintColor = NSColor(calibratedRed: 0.12, green: 0.47, blue: 0.86, alpha: 1)

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        let bodyViews = [
            welcomeBody,
            permissionBody,
            localChoiceBody,
            packSelectionBody,
            installingBody,
            completionBody
        ]
        bodyViews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addSubview($0)
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                $0.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
                $0.bottomAnchor.constraint(lessThanOrEqualTo: bodyContainer.bottomAnchor)
            ])
        }

        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondaryButton)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.controlSize = .regular

        primaryButton.target = self
        primaryButton.action = #selector(handlePrimaryButton)
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .regular
        primaryButton.bezelColor = NSColor(calibratedRed: 0.12, green: 0.47, blue: 0.86, alpha: 1)
        primaryButton.contentTintColor = .white

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [secondaryButton, buttonSpacer, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, bodyContainer, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])

        configureWelcomeBody()
        configurePermissionBody()
        configureLocalChoiceBody()
        configurePackSelectionBody()
        configureInstallingBody()
        configureCompletionBody()
    }

    private func configureWelcomeBody() {
        let hints = [
            "完成系统授权，确保录音、快捷键和文本写入都能正常工作。",
            "如果你想离线使用，可以继续准备本地识别模型。",
            "云端 API 配置不放在这里，之后仍然可以在设置里单独完成。"
        ].map(makeHintLabel)

        welcomeBody.orientation = .vertical
        welcomeBody.alignment = .leading
        welcomeBody.spacing = 12
        hints.forEach { welcomeBody.addArrangedSubview($0) }
    }

    private func configurePermissionBody() {
        permissionBody.orientation = .vertical
        permissionBody.alignment = .leading
        permissionBody.spacing = 12

        accessibilityButton.target = self
        accessibilityButton.action = #selector(handleAccessibilityPermission)
        inputMonitoringButton.target = self
        inputMonitoringButton.action = #selector(handleInputMonitoringPermission)
        microphoneButton.target = self
        microphoneButton.action = #selector(handleMicrophonePermission)

        permissionBody.addArrangedSubview(
            makePermissionRow(
                title: "麦克风",
                statusLabel: microphoneStatusLabel,
                actionButton: microphoneButton
            )
        )
        permissionBody.addArrangedSubview(
            makePermissionRow(
                title: "辅助功能",
                statusLabel: accessibilityStatusLabel,
                actionButton: accessibilityButton
            )
        )
        permissionBody.addArrangedSubview(
            makePermissionRow(
                title: "输入监控",
                statusLabel: inputMonitoringStatusLabel,
                actionButton: inputMonitoringButton
            )
        )

        permissionHintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        permissionHintLabel.textColor = .secondaryLabelColor
        permissionHintLabel.maximumNumberOfLines = 0
        permissionBody.addArrangedSubview(permissionHintLabel)
    }

    private func configureLocalChoiceBody() {
        localChoiceBody.orientation = .vertical
        localChoiceBody.alignment = .leading
        localChoiceBody.spacing = 12

        localChoiceBody.addArrangedSubview(
            makeHintLabel("本地识别准备完成后，这台 Mac 可以直接离线使用。")
        )
        localChoiceBody.addArrangedSubview(
            makeHintLabel("如果你暂时不想下载，也可以先跳过；之后录音前我们会继续提醒你补齐设置。")
        )
        localChoiceBody.addArrangedSubview(
            makeHintLabel("云端 API 可在设置中稍后配置。")
        )
    }

    private func configurePackSelectionBody() {
        packSelectionBody.orientation = .vertical
        packSelectionBody.alignment = .leading
        packSelectionBody.spacing = 12

        quickPackButton.target = self
        quickPackButton.action = #selector(handlePackSelectionChanged)
        recommendedPackButton.target = self
        recommendedPackButton.action = #selector(handlePackSelectionChanged)

        quickPackButton.title = LocalModelPack.quick.title
        recommendedPackButton.title = LocalModelPack.recommended.title
        recommendedPackButton.state = .on

        packSelectionBody.addArrangedSubview(
            makePackChoiceCard(button: quickPackButton, pack: .quick)
        )
        packSelectionBody.addArrangedSubview(
            makePackChoiceCard(button: recommendedPackButton, pack: .recommended)
        )
    }

    private func configureInstallingBody() {
        installingBody.orientation = .vertical
        installingBody.alignment = .centerX
        installingBody.spacing = 14

        installProgressIndicator.style = .spinning
        installProgressIndicator.controlSize = .regular
        installProgressIndicator.isDisplayedWhenStopped = false

        installStatusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        installStatusLabel.textColor = .labelColor
        installStatusLabel.alignment = .center

        installDetailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        installDetailLabel.textColor = .secondaryLabelColor
        installDetailLabel.maximumNumberOfLines = 0
        installDetailLabel.alignment = .center

        installingBody.addArrangedSubview(installProgressIndicator)
        installingBody.addArrangedSubview(installStatusLabel)
        installingBody.addArrangedSubview(installDetailLabel)
    }

    private func configureCompletionBody() {
        completionBody.orientation = .vertical
        completionBody.alignment = .leading
        completionBody.spacing = 12

        completionHintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        completionHintLabel.textColor = .secondaryLabelColor
        completionHintLabel.maximumNumberOfLines = 0

        completionBody.addArrangedSubview(
            makeHintLabel("你之后仍然可以在设置页里重新打开这套引导，或直接调整本地模型与权限。")
        )
        completionBody.addArrangedSubview(completionHintLabel)
    }

    private func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func makePermissionRow(
        title: String,
        statusLabel: NSTextField,
        actionButton: NSButton
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [titleLabel, spacer, statusLabel, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makePackChoiceCard(button: NSButton, pack: LocalModelPack) -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 16
        box.borderColor = NSColor(calibratedWhite: 0.84, alpha: 1)
        box.fillColor = NSColor.white.withAlphaComponent(0.92)
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(wrappingLabelWithString: pack.detail)
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0

        let sizeLabel = NSTextField(wrappingLabelWithString: pack.sizeEstimate)
        sizeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [button, detailLabel, sizeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)

        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        return box
    }

    @objc
    private func handleAppDidBecomeActive() {
        if currentStep == .permissions {
            refreshPermissionBody()
        }
    }

    @objc
    private func handleLocalASRStateNotification(_ notification: Notification) {
        guard currentStep == .installing else { return }
        let snapshot = notification.userInfo?[LocalASRAssetManager.snapshotUserInfoKey] as? LocalASRAssetManager.Snapshot
            ?? LocalASRAssetManager.shared.snapshot
        installStatusLabel.stringValue = snapshot.title
        installDetailLabel.stringValue = snapshot.detail
    }

    @objc
    private func handlePrimaryButton() {
        switch currentStep {
        case .welcome:
            currentStep = .permissions
            renderCurrentStep()
        case .permissions:
            currentStep = shouldSkipLocalChoiceStep() ? .completion : .localChoice
            renderCurrentStep()
        case .localChoice:
            currentStep = .packSelection
            renderCurrentStep()
        case .packSelection:
            startInstall()
        case .installing:
            if installFailed {
                startInstall()
            }
        case .completion:
            closePanel()
        }
    }

    @objc
    private func handleSecondaryButton() {
        switch currentStep {
        case .welcome:
            onSetupStateChanged(currentCompletionState())
            currentStep = .completion
            renderCurrentStep()
        case .permissions:
            currentStep = shouldSkipLocalChoiceStep() ? .completion : .localChoice
            renderCurrentStep()
        case .localChoice:
            onSetupStateChanged(currentCompletionState())
            currentStep = .completion
            renderCurrentStep()
        case .packSelection:
            if entryPoint == .localPackSelection {
                closePanel()
            } else {
                currentStep = .localChoice
                renderCurrentStep()
            }
        case .installing:
            if installRunning {
                shouldDeferAfterCancellation = true
                LocalASRAssetManager.shared.cancelActiveInstall()
            } else {
                onSetupStateChanged(currentCompletionState())
                currentStep = .completion
                renderCurrentStep()
            }
        case .completion:
            closePanel()
        }
    }

    @objc
    private func handleAccessibilityPermission() {
        requestAccessibilityPermission()
        refreshPermissionBody()
    }

    @objc
    private func handleInputMonitoringPermission() {
        requestInputMonitoringPermission()
        refreshPermissionBody()
    }

    @objc
    private func handleMicrophonePermission() {
        requestMicrophonePermission()
        refreshPermissionBody()
    }

    @objc
    private func handlePackSelectionChanged() {
        selectedPack = quickPackButton.state == .on ? .quick : .recommended
        if selectedPack == .quick {
            recommendedPackButton.state = .off
            quickPackButton.state = .on
        } else {
            quickPackButton.state = .off
            recommendedPackButton.state = .on
        }
    }

    private func startInstall() {
        selectedPack = quickPackButton.state == .on ? .quick : .recommended
        installFailed = false
        installRunning = true
        shouldDeferAfterCancellation = false
        installProgressIndicator.startAnimation(nil)
        currentStep = .installing
        renderCurrentStep()

        LocalASRAssetManager.shared.beginInstall(pack: selectedPack) { [weak self] result in
            guard let self else { return }
            self.installRunning = false
            self.installProgressIndicator.stopAnimation(nil)

            switch result {
            case .success:
                self.onLocalPackInstalled(self.selectedPack)
                self.onSetupStateChanged(.ready)
                self.currentStep = .completion
                self.renderCurrentStep()
            case .failure(let error):
                if case .cancelled = error {
                    if self.shouldCloseAfterCancellation {
                        self.shouldCloseAfterCancellation = false
                        self.onSetupStateChanged(self.currentCompletionState())
                        self.closePanel()
                        return
                    }

                    if self.shouldDeferAfterCancellation {
                        self.shouldDeferAfterCancellation = false
                        self.onSetupStateChanged(self.currentCompletionState())
                        self.currentStep = .completion
                        self.renderCurrentStep()
                        return
                    }
                }

                self.installFailed = true
                self.installStatusLabel.stringValue = "本地识别准备失败"
                self.installDetailLabel.stringValue = LocalASRAssetManager.shared.snapshot.detail
                self.renderCurrentStep()
            }
        }
    }

    private func currentCompletionState() -> MyTypeSetupState {
        let permissionState = permissionStateProvider()
        return routeReadinessProvider().anyReady && permissionState.hasAllRequiredPermissions
            ? .ready
            : .deferred
    }

    private func shouldSkipLocalChoiceStep() -> Bool {
        routeReadinessProvider().localReady
    }

    private func refreshPermissionBody() {
        let state = permissionStateProvider()
        configurePermissionStatus(
            state: state.accessibilityTrusted,
            label: accessibilityStatusLabel,
            button: accessibilityButton
        )
        configurePermissionStatus(
            state: state.listenEventTrusted,
            label: inputMonitoringStatusLabel,
            button: inputMonitoringButton
        )
        configurePermissionStatus(
            state: state.microphoneAuthorized,
            label: microphoneStatusLabel,
            button: microphoneButton
        )

        if state.hasAllRequiredPermissions {
            permissionHintLabel.stringValue = "三项系统授权都已经具备，后面只要决定是否现在准备本地识别即可。"
        } else {
            permissionHintLabel.stringValue = "你可以先继续往下走，缺少的系统授权之后也能在设置页重新补齐。"
        }
    }

    private func configurePermissionStatus(
        state: Bool,
        label: NSTextField,
        button: NSButton
    ) {
        label.stringValue = state ? "已授权" : "未授权"
        label.textColor = state
            ? NSColor(calibratedRed: 0.15, green: 0.58, blue: 0.29, alpha: 1)
            : NSColor.systemOrange
        button.title = state ? "已完成" : "去授权"
        button.isEnabled = !state
    }

    private func renderCurrentStep() {
        let allBodies = [
            welcomeBody,
            permissionBody,
            localChoiceBody,
            packSelectionBody,
            installingBody,
            completionBody
        ]
        allBodies.forEach { $0.isHidden = true }
        secondaryButton.isHidden = false
        primaryButton.isHidden = false

        switch currentStep {
        case .welcome:
            titleLabel.stringValue = "欢迎使用 MyType"
            subtitleLabel.stringValue = "首次使用前还需要几个简单步骤，完成后就能更顺畅地开始语音输入。"
            welcomeBody.isHidden = false
            primaryButton.title = "继续"
            secondaryButton.title = "稍后再说"
        case .permissions:
            titleLabel.stringValue = "完成系统授权"
            subtitleLabel.stringValue = "请检查麦克风、辅助功能和输入监控三项权限。"
            refreshPermissionBody()
            permissionBody.isHidden = false
            primaryButton.title = "继续"
            secondaryButton.title = "稍后处理"
        case .localChoice:
            titleLabel.stringValue = "是否现在启用本地识别"
            subtitleLabel.stringValue = "本地识别准备完成后，即使没有网络也能继续在这台 Mac 上使用。"
            localChoiceBody.isHidden = false
            primaryButton.title = "立即设置本地识别"
            secondaryButton.title = "稍后再说"
        case .packSelection:
            titleLabel.stringValue = "选择本地模型档位"
            subtitleLabel.stringValue = "你可以先从轻量档位开始，也可以一次准备好更平衡的本地识别体验。"
            packSelectionBody.isHidden = false
            primaryButton.title = "开始准备"
            secondaryButton.title = entryPoint == .localPackSelection ? "取消" : "返回"
        case .installing:
            titleLabel.stringValue = installFailed ? "正在准备本地识别" : "正在准备本地识别"
            subtitleLabel.stringValue = installFailed
                ? "这次准备没有完成，你可以直接重试，或者先稍后继续。"
                : "运行时和所选模型档位会准备到当前这台 Mac。"
            installingBody.isHidden = false
            if !installFailed {
                installStatusLabel.stringValue = LocalASRAssetManager.shared.snapshot.title
                installDetailLabel.stringValue = LocalASRAssetManager.shared.snapshot.detail
            }
            primaryButton.title = installFailed ? "重试" : "正在准备…"
            primaryButton.isEnabled = installFailed
            secondaryButton.title = "稍后继续"
        case .completion:
            let readiness = routeReadinessProvider()
            let completionState = currentCompletionState()
            let ready = completionState == .ready
            if ready, shortcutNeedsAttentionProvider() {
                titleLabel.stringValue = "建议先自定义快捷键"
                subtitleLabel.stringValue =
                    "识别路径和系统授权都已经具备，但当前如果仍是默认 Fn，实际使用时很容易被系统功能抢走。"
                completionHintLabel.stringValue =
                    "先去设置页把快捷键改成自定义组合键，会比继续使用默认 Fn 更稳定。"
            } else if ready {
                titleLabel.stringValue = "已可使用"
                subtitleLabel.stringValue = "识别路径和系统授权都已经具备，你现在可以直接开始使用 MyType。"
                completionHintLabel.stringValue =
                    "如果之后想切换档位、重下模型或补齐系统授权，都可以在设置页里继续调整。"
            } else if readiness.anyReady {
                titleLabel.stringValue = "识别已准备好，还差系统授权"
                subtitleLabel.stringValue =
                    "至少已经有一条识别路径可用，但你还需要补齐麦克风、辅助功能或输入监控权限。"
                completionHintLabel.stringValue =
                    "当你准备好了，可以从设置页或菜单栏里的“继续完成设置”重新打开这套引导。"
            } else {
                titleLabel.stringValue = "稍后继续配置"
                subtitleLabel.stringValue =
                    "你这次先跳过了本地识别。应用仍然可以正常打开，但录音前会继续提醒你补齐设置。"
                completionHintLabel.stringValue =
                    "当你准备好了，可以从设置页或菜单栏里的“继续完成设置”重新打开这套引导。"
            }
            completionBody.isHidden = false
            primaryButton.isEnabled = true
            primaryButton.title = "完成"
            secondaryButton.isHidden = true
        }

        if currentStep != .installing {
            primaryButton.isEnabled = true
        }
        bodyContainer.layoutSubtreeIfNeeded()
    }

    private func closePanel() {
        panel.close()
    }
}
