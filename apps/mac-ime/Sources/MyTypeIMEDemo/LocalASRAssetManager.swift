import Foundation
import ASRAdapter
import Settings

@MainActor
final class LocalASRAssetManager {
    enum SnapshotKind: Equatable {
        case notInstalled
        case installing
        case ready
        case unavailable
        case failed
    }

    enum AssetSource: String, Equatable {
        case applicationSupport
        case bundled
        case sourcePackage
    }

    struct Snapshot: Equatable {
        let kind: SnapshotKind
        let source: AssetSource?
        let title: String
        let detail: String
        let primaryActionTitle: String
        let canStartInstall: Bool
        let canDelete: Bool
        let showsActivity: Bool
    }

    enum AssetError: LocalizedError {
        case busy
        case cancelled
        case unsupported(String)
        case scriptMissing(URL)
        case commandFailed(step: String, command: String, details: String)
        case fileOperation(String)

        var errorDescription: String? {
            switch self {
            case .busy:
                return "本地模型任务正在进行中。"
            case .cancelled:
                return "本地模型安装已取消。"
            case .unsupported(let message):
                return message
            case .scriptMissing(let url):
                return "本地识别脚本缺失：\(url.path)"
            case .commandFailed(let step, _, let details):
                return "\(step)失败：\(details)"
            case .fileOperation(let message):
                return message
            }
        }
    }

    static let shared = LocalASRAssetManager()
    static let stateDidChangeNotification = Notification.Name("LocalASRAssetManager.stateDidChange")
    static let snapshotUserInfoKey = "snapshot"

    private static let initialPromptSettingKey = SettingsKeys.didRunInitialLocalASRPrompt
    private static let initialPromptMarkerName = "initial_local_asr_prompt_done.flag"
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private let settingsStore = UserDefaultsSettingsStore()
    private let fileManager = FileManager.default
    private var activeOperationID: UUID?
    private var activeStepTitle: String?
    private var lastFailureMessage: String?
    private var pendingCompletion: ((Result<Snapshot, AssetError>) -> Void)?
    private(set) var snapshot = Snapshot(
        kind: .notInstalled,
        source: nil,
        title: "本地模型尚未安装",
        detail: "首次准备会下载本地语音识别运行时，并安装 tiny + small 模型。",
        primaryActionTitle: "下载本地模型",
        canStartInstall: true,
        canDelete: false,
        showsActivity: false
    )

    private init() {
        refreshStatus()
    }

    func refreshStatus() {
        publish(makeSnapshot())
    }

    func shouldPromptForInitialDownload() -> Bool {
        guard !hasInitialPromptMarker() else { return false }
        let current = makeSnapshot()
        return current.kind == .notInstalled || current.kind == .failed
    }

    func markInitialDownloadPromptHandled() {
        settingsStore.set(true, forKey: Self.initialPromptSettingKey)
        guard let markerURL = initialPromptMarkerURL() else { return }
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: markerURL.path) {
                try Data("1".utf8).write(to: markerURL, options: .atomic)
            }
        } catch {
            fputs("Persist local ASR prompt marker failed: \(error)\n", stderr)
        }
    }

    func cancelActiveInstall() {
        guard activeOperationID != nil else { return }
        activeOperationID = nil
        activeStepTitle = nil
        let completion = pendingCompletion
        pendingCompletion = nil
        refreshStatus()
        completion?(.failure(.cancelled))
    }

    func beginInstall(pack: LocalModelPack? = nil, completion: ((Result<Snapshot, AssetError>) -> Void)? = nil) {
        guard activeOperationID == nil else {
            completion?(.failure(.busy))
            return
        }

        lastFailureMessage = nil
        let operationID = UUID()
        activeOperationID = operationID
        pendingCompletion = completion
        setActiveStep("正在准备本地识别环境…")

        let requestedModels = pack?.requestedModels ?? ASRModelSize.allCases
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                try self.installAssets(operationID: operationID, models: requestedModels)
                DispatchQueue.main.async {
                    guard self.activeOperationID == operationID else { return }
                    self.activeOperationID = nil
                    self.activeStepTitle = nil
                    self.lastFailureMessage = nil
                    self.pendingCompletion = nil
                    self.refreshStatus()
                    completion?(.success(self.snapshot))
                }
            } catch let error as AssetError {
                DispatchQueue.main.async {
                    guard self.activeOperationID == operationID else { return }
                    self.activeOperationID = nil
                    self.activeStepTitle = nil
                    self.pendingCompletion = nil
                    self.lastFailureMessage = self.userFacingMessage(for: error)
                    self.refreshStatus()
                    completion?(.failure(error))
                }
            } catch {
                let wrapped = AssetError.fileOperation(error.localizedDescription)
                DispatchQueue.main.async {
                    guard self.activeOperationID == operationID else { return }
                    self.activeOperationID = nil
                    self.activeStepTitle = nil
                    self.pendingCompletion = nil
                    self.lastFailureMessage = self.userFacingMessage(for: wrapped)
                    self.refreshStatus()
                    completion?(.failure(wrapped))
                }
            }
        }
    }

    func removeUserManagedAssets(completion: ((Result<Snapshot, AssetError>) -> Void)? = nil) {
        guard activeOperationID == nil else {
            completion?(.failure(.busy))
            return
        }
        guard let rootURL = userManagedRootURL() else {
            completion?(.failure(.unsupported("找不到 MyType 的本地数据目录。")))
            return
        }

        let operationID = UUID()
        activeOperationID = operationID
        lastFailureMessage = nil
        setActiveStep("正在删除本地模型…")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                if self.fileManager.fileExists(atPath: rootURL.path) {
                    try self.fileManager.removeItem(at: rootURL)
                }
                DispatchQueue.main.async {
                    guard self.activeOperationID == operationID else { return }
                    self.activeOperationID = nil
                    self.activeStepTitle = nil
                    self.lastFailureMessage = nil
                    self.refreshStatus()
                    completion?(.success(self.snapshot))
                }
            } catch {
                let wrapped = AssetError.fileOperation(error.localizedDescription)
                DispatchQueue.main.async {
                    guard self.activeOperationID == operationID else { return }
                    self.activeOperationID = nil
                    self.activeStepTitle = nil
                    self.lastFailureMessage = self.userFacingMessage(for: wrapped)
                    self.refreshStatus()
                    completion?(.failure(wrapped))
                }
            }
        }
    }

    private func installAssets(operationID: UUID, models: [ASRModelSize] = ASRModelSize.allCases) throws {
        guard let rootURL = userManagedRootURL() else {
            throw AssetError.unsupported("无法定位“应用程序支持”目录，暂时不能下载本地模型。")
        }

        let scriptURL = FasterWhisperConfiguration.defaultForPackage().scriptURL
        guard fileManager.fileExists(atPath: scriptURL.path) else {
            throw AssetError.scriptMissing(scriptURL)
        }

        let venvURL = rootURL.appendingPathComponent(".venv", isDirectory: true)
        let modelsURL = rootURL.appendingPathComponent(".models", isDirectory: true)
        let venvPython = venvURL.appendingPathComponent("bin/python3")

        reportInstallStep("正在清理旧的本地模型…", operationID: operationID)
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        if let seedRootURL = preferredSeedAssetRootURL() {
            reportInstallStep("正在把现有本地模型部署到本机目录…", operationID: operationID)
            try copyDeployableAssets(from: seedRootURL, to: rootURL)
            guard isReady(rootURL: rootURL) else {
                throw AssetError.fileOperation("本地模型复制完成了，但部署后的文件不完整。")
            }
            return
        }

        guard let bootstrapPython = bootstrapPythonPath() else {
            throw AssetError.unsupported("这台 Mac 没有可用的 Python 3，暂时不能自动准备本地识别环境。")
        }

        reportInstallStep("正在创建本地运行环境…", operationID: operationID)
        try runCommand(
            executablePath: bootstrapPython,
            arguments: ["-m", "venv", venvURL.path],
            step: "创建本地运行环境"
        )

        guard fileManager.isExecutableFile(atPath: venvPython.path) else {
            throw AssetError.fileOperation("本地 Python 环境创建完成后，没有生成可执行的 python3。")
        }

        reportInstallStep("正在安装语音识别依赖…", operationID: operationID)
        try runCommand(
            executablePath: venvPython.path,
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            step: "升级 pip"
        )
        try runCommand(
            executablePath: venvPython.path,
            arguments: ["-m", "pip", "install", "faster-whisper", "opencc-python-reimplemented"],
            step: "安装本地识别依赖"
        )

        try fileManager.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        let probeAudioURL = try createProbeAudioFile()
        defer { try? fileManager.removeItem(at: probeAudioURL) }

        for model in models {
            reportInstallStep("正在下载 \(model.rawValue) 模型…", operationID: operationID)
            try runCommand(
                executablePath: venvPython.path,
                arguments: [
                    scriptURL.path,
                    "--audio", probeAudioURL.path,
                    "--model", model.rawValue,
                    "--device", "auto",
                    "--compute-type", "int8",
                    "--beam-size", "1",
                    "--model-dir", modelsURL.path,
                    "--chinese-script", "simplified"
                ],
                step: "下载 \(model.rawValue) 模型"
            )
        }
    }

    private func preferredSeedAssetRootURL() -> URL? {
        let sourceRootURL = FasterWhisperConfiguration.sourcePackageRootURL()
        if isReady(rootURL: sourceRootURL) {
            return sourceRootURL
        }
        if let bundledRootURL = FasterWhisperConfiguration.bundledASRRootURL(),
           isReady(rootURL: bundledRootURL) {
            return bundledRootURL
        }
        return nil
    }

    private func copyDeployableAssets(from sourceRootURL: URL, to destinationRootURL: URL) throws {
        let sourceVenvURL = sourceRootURL.appendingPathComponent(".venv", isDirectory: true)
        let sourceModelsURL = sourceRootURL.appendingPathComponent(".models", isDirectory: true)
        let destinationVenvURL = destinationRootURL.appendingPathComponent(".venv", isDirectory: true)
        let destinationModelsURL = destinationRootURL.appendingPathComponent(".models", isDirectory: true)

        guard fileManager.fileExists(atPath: sourceVenvURL.path),
              fileManager.fileExists(atPath: sourceModelsURL.path) else {
            throw AssetError.fileOperation("本地模型源目录不完整，没法部署到当前 Mac。")
        }

        do {
            try fileManager.copyItem(at: sourceVenvURL, to: destinationVenvURL)
            try fileManager.copyItem(at: sourceModelsURL, to: destinationModelsURL)
        } catch {
            throw AssetError.fileOperation("复制本地模型到本机目录失败：\(error.localizedDescription)")
        }
    }

    private func publish(_ snapshot: Snapshot) {
        let didChange = self.snapshot != snapshot
        self.snapshot = snapshot
        guard didChange else { return }
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: self,
            userInfo: [Self.snapshotUserInfoKey: snapshot]
        )
    }

    private func makeSnapshot() -> Snapshot {
        if let activeStepTitle {
            return Snapshot(
                kind: .installing,
                source: .applicationSupport,
                title: activeStepTitle,
                detail: "本地运行时和 tiny + small 模型会下载到这台 Mac，上线后本地识别和本地实时预览都能直接使用。",
                primaryActionTitle: "准备中…",
                canStartInstall: false,
                canDelete: false,
                showsActivity: true
            )
        }

        guard hasUsableScript() else {
            return Snapshot(
                kind: .unavailable,
                source: nil,
                title: "当前安装包缺少本地识别脚本",
                detail: "请重新安装 MyType，或重新打包包含 ASR 脚本的版本。",
                primaryActionTitle: "暂不可用",
                canStartInstall: false,
                canDelete: hasUserManagedAssets(),
                showsActivity: false
            )
        }

        if isUserManagedReady() {
            let sizeText = formattedSize(at: userManagedRootURL())
            return Snapshot(
                kind: .ready,
                source: .applicationSupport,
                title: "本地模型已安装",
                detail: "当前优先使用本机已部署的本地运行时和模型。\(sizeText.map { "已占用 \($0)。" } ?? "可离线使用本地识别和本地实时预览。")",
                primaryActionTitle: "重新下载",
                canStartInstall: true,
                canDelete: true,
                showsActivity: false
            )
        }

        if isBundledReady() {
            let sizeText = formattedSize(at: FasterWhisperConfiguration.bundledASRRootURL())
            return Snapshot(
                kind: .ready,
                source: .bundled,
                title: "本地模型已随应用内置",
                detail: sizeText.map { "当前安装包已经自带本地运行时和模型，约占用 \($0)。" }
                    ?? "当前安装包已经自带本地运行时和模型，无需额外下载。",
                primaryActionTitle: "已内置",
                canStartInstall: false,
                canDelete: hasUserManagedAssets(),
                showsActivity: false
            )
        }

        if isSourcePackageReady() {
            return Snapshot(
                kind: .ready,
                source: .sourcePackage,
                title: "本地模型已部署",
                detail: "当前开发环境里的本地识别环境已经可用。若你想模拟普通用户安装后的独立部署，可以点下面的按钮，把现有模型复制到当前 Mac 的应用数据目录。",
                primaryActionTitle: "部署到本机目录",
                canStartInstall: true,
                canDelete: hasUserManagedAssets(),
                showsActivity: false
            )
        }

        if let lastFailureMessage {
            return Snapshot(
                kind: .failed,
                source: nil,
                title: "本地模型准备失败",
                detail: lastFailureMessage,
                primaryActionTitle: "重新下载",
                canStartInstall: true,
                canDelete: hasUserManagedAssets(),
                showsActivity: false
            )
        }

        guard bootstrapPythonPath() != nil else {
            return Snapshot(
                kind: .unavailable,
                source: nil,
                title: "这台 Mac 暂时不能自动准备本地模型",
                detail: "没有找到可用的 Python 3。安装 Python 3 后，再回来点“下载本地模型”即可。",
                primaryActionTitle: "暂不可用",
                canStartInstall: false,
                canDelete: hasUserManagedAssets(),
                showsActivity: false
            )
        }

        return Snapshot(
            kind: .notInstalled,
            source: nil,
            title: "本地模型尚未安装",
            detail: "下载后会安装本地语音识别运行时，并准备 tiny + small 模型。首次可能需要几分钟，完成后本地和混合模式都能直接使用。",
            primaryActionTitle: "下载本地模型",
            canStartInstall: true,
            canDelete: hasUserManagedAssets(),
            showsActivity: false
        )
    }

    private func setActiveStep(_ title: String) {
        activeStepTitle = title
        publish(makeSnapshot())
    }

    private func reportInstallStep(_ title: String, operationID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeOperationID == operationID else { return }
            self.setActiveStep(title)
        }
    }

    private func runCommand(
        executablePath: String,
        arguments: [String],
        step: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AssetError.commandFailed(
                step: step,
                command: ([executablePath] + arguments).joined(separator: " "),
                details: error.localizedDescription
            )
        }

        process.waitUntilExit()
        let stdoutText = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderrText = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let merged = ([stderrText, stdoutText])
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw AssetError.commandFailed(
                step: step,
                command: ([executablePath] + arguments).joined(separator: " "),
                details: merged.isEmpty ? "退出码 \(process.terminationStatus)" : merged
            )
        }
    }

    private func hasUsableScript() -> Bool {
        fileManager.fileExists(atPath: FasterWhisperConfiguration.defaultForPackage().scriptURL.path)
    }

    private func bootstrapPythonPath() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private func hasInitialPromptMarker() -> Bool {
        if settingsStore.bool(forKey: Self.initialPromptSettingKey, default: false) {
            return true
        }
        guard let markerURL = initialPromptMarkerURL() else { return false }
        return fileManager.fileExists(atPath: markerURL.path)
    }

    private func initialPromptMarkerURL() -> URL? {
        guard let rootURL = FasterWhisperConfiguration.applicationSupportASRRootURL(fileManager: fileManager)?
            .deletingLastPathComponent() else {
            return nil
        }
        return rootURL.appendingPathComponent(Self.initialPromptMarkerName)
    }

    private func userManagedRootURL() -> URL? {
        FasterWhisperConfiguration.applicationSupportASRRootURL(fileManager: fileManager)
    }

    private func hasUserManagedAssets() -> Bool {
        guard let rootURL = userManagedRootURL() else { return false }
        return fileManager.fileExists(atPath: rootURL.path)
    }

    private func isUserManagedReady() -> Bool {
        guard let rootURL = userManagedRootURL() else { return false }
        return isReady(rootURL: rootURL)
    }

    private func isBundledReady() -> Bool {
        guard let rootURL = FasterWhisperConfiguration.bundledASRRootURL() else { return false }
        return isReady(rootURL: rootURL)
    }

    private func isSourcePackageReady() -> Bool {
        let rootURL = FasterWhisperConfiguration.sourcePackageRootURL()
        return isReady(rootURL: rootURL)
    }

    private func isReady(rootURL: URL) -> Bool {
        let pythonPath = rootURL.appendingPathComponent(".venv/bin/python3").path
        let modelsURL = rootURL.appendingPathComponent(".models", isDirectory: true)
        return fileManager.isExecutableFile(atPath: pythonPath) && directoryHasContents(modelsURL)
    }

    private func directoryHasContents(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return enumerator.nextObject() != nil
    }

    private func formattedSize(at rootURL: URL?) -> String? {
        guard let rootURL else { return nil }
        guard let size = directorySize(at: rootURL) else { return nil }
        return Self.byteCountFormatter.string(fromByteCount: size)
    }

    private func directorySize(at rootURL: URL) -> Int64? {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            ) else {
                continue
            }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func createProbeAudioFile() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "mytype-local-asr-probe-\(UUID().uuidString).wav"
        )
        let sampleRate = 16_000
        let durationSeconds = 1
        let channelCount = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let sampleCount = sampleRate * durationSeconds
        let pcmByteCount = sampleCount * channelCount * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + pcmByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + pcmByteCount), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(UInt16(channelCount), to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(sampleRate * channelCount * bytesPerSample), to: &data)
        appendUInt16(UInt16(channelCount * bytesPerSample), to: &data)
        appendUInt16(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(pcmByteCount), to: &data)
        data.append(Data(count: pcmByteCount))

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AssetError.fileOperation("生成本地模型下载测试音频失败：\(error.localizedDescription)")
        }
        return url
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func userFacingMessage(for error: AssetError) -> String {
        switch error {
        case .busy:
            return "已经有一个本地模型任务在执行了，等它完成后再试一次。"
        case .cancelled:
            return "本地模型安装已取消。"
        case .unsupported(let message):
            return message
        case .scriptMissing:
            return "当前安装包缺少本地识别脚本，请重新安装一个完整的 MyType 版本。"
        case .fileOperation(let message):
            return "本地文件处理失败：\(compact(message))"
        case .commandFailed(let step, _, let details):
            let normalized = details.lowercased()
            if normalized.contains("temporary failure in name resolution")
                || normalized.contains("name or service not known")
                || normalized.contains("nodename nor servname provided") {
                return "\(step)失败：网络连接不可用，没法下载本地依赖或模型。"
            }
            if normalized.contains("ssl")
                || normalized.contains("certificate")
                || normalized.contains("tls") {
                return "\(step)失败：和下载源建立安全连接时出错，请稍后重试。"
            }
            if normalized.contains("no matching distribution found")
                || normalized.contains("could not find a version") {
                return "\(step)失败：当前 Python 环境无法安装所需依赖，请检查 Python 版本后重试。"
            }
            if normalized.contains("read timed out")
                || normalized.contains("timed out") {
                return "\(step)失败：下载超时了，请换个网络后再试。"
            }
            return "\(step)失败：\(compact(details))"
        }
    }

    private func compact(_ text: String, limit: Int = 220) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return "\(trimmed[..<endIndex])…"
    }
}
