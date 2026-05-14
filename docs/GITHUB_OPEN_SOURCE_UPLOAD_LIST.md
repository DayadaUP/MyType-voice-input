# GitHub 开源上传文件列表

仓库：`DayadaUP/MyType-voice-input`  
远端基准：`origin/main`  
快照日期：`2026-05-14`  
当前 GitHub 已公开文件数：`74`  
本次软件相关整理后的目标公开文件数：`70`

## 用途

这份文档是 MyType 开源仓库的上传白名单。以后更新 GitHub 仓库时，以这份列表为准；不在列表中的文件，默认不上传。

## 上传规则

1. 只更新本文已经列出的公开文件。
2. 如果要首次公开一个新文件，先更新本文，把新路径加入清单，再上传该文件。
3. 图片、截图、设计稿、临时素材、日志、模型文件、虚拟环境、打包产物默认不上传。
4. 下面按目录分组只是为了更好阅读，不表示该目录下新增文件可以自动上传。新增文件仍然需要先补进这份白名单。

## 本次整理后保留的公开文件

### 根目录

```text
.gitignore
LICENSE
README.md
```

### `apps/mac-ime`

```text
apps/mac-ime/Package.swift
apps/mac-ime/README.md
apps/mac-ime/Scripts/faster_whisper_transcribe.py
apps/mac-ime/Scripts/package_demo_app.sh
apps/mac-ime/Scripts/setup_local_asr.sh
apps/mac-ime/Sources/ASRAdapter/ASREngine.swift
apps/mac-ime/Sources/ASRAdapter/CloudLivePreviewStreamer.swift
apps/mac-ime/Sources/AudioEngine/AudioRecorder.swift
apps/mac-ime/Sources/BaselineEvaluator/main.swift
apps/mac-ime/Sources/Common/AudioCacheStore.swift
apps/mac-ime/Sources/Common/MyTypeAppearance.swift
apps/mac-ime/Sources/Common/MyTypePermissionSupport.swift
apps/mac-ime/Sources/Common/Types.swift
apps/mac-ime/Sources/FloatingUI/FloatingBallWindow.swift
apps/mac-ime/Sources/IMEHost/AppCompatibilityProfile.swift
apps/mac-ime/Sources/IMEHost/CloudStreamingFinalizationGuard.swift
apps/mac-ime/Sources/IMEHost/CloudStreamingStableCommitGuard.swift
apps/mac-ime/Sources/IMEHost/FinalInsertionGuard.swift
apps/mac-ime/Sources/IMEHost/FocusedTextInjector.swift
apps/mac-ime/Sources/IMEHost/IMEOrchestrator.swift
apps/mac-ime/Sources/IMEHost/InsertionStabilityGuard.swift
apps/mac-ime/Sources/IMEHost/LivePreviewCommitPolicy.swift
apps/mac-ime/Sources/IMEHost/MyTypeInputController.swift
apps/mac-ime/Sources/Lexicon/CorrectionDiffDetector.swift
apps/mac-ime/Sources/Lexicon/LexiconSQLiteStore.swift
apps/mac-ime/Sources/Lexicon/LexiconService.swift
apps/mac-ime/Sources/MyTypeIMEDemo/AppResourceLocator.swift
apps/mac-ime/Sources/MyTypeIMEDemo/CloudLogViewerWindowController.swift
apps/mac-ime/Sources/MyTypeIMEDemo/FirstRunSetupWizardController.swift
apps/mac-ime/Sources/MyTypeIMEDemo/LexiconFlowLayout.swift
apps/mac-ime/Sources/MyTypeIMEDemo/LexiconTermCellView.swift
apps/mac-ime/Sources/MyTypeIMEDemo/LivePreviewWindow.swift
apps/mac-ime/Sources/MyTypeIMEDemo/LocalASRAssetManager.swift
apps/mac-ime/Sources/MyTypeIMEDemo/RecordingCountdownWindow.swift
apps/mac-ime/Sources/MyTypeIMEDemo/Resources/AppLogo.png
apps/mac-ime/Sources/MyTypeIMEDemo/Resources/NOTICE.txt
apps/mac-ime/Sources/MyTypeIMEDemo/SettingsPanelController.swift
apps/mac-ime/Sources/MyTypeIMEDemo/SetupReadinessSupport.swift
apps/mac-ime/Sources/MyTypeIMEDemo/ShortcutSupport.swift
apps/mac-ime/Sources/MyTypeIMEDemo/main.swift
apps/mac-ime/Sources/Settings/FillerBlacklistStore.swift
apps/mac-ime/Sources/Settings/PunctuationLearningStore.swift
apps/mac-ime/Sources/Settings/PunctuationResetCoordinator.swift
apps/mac-ime/Sources/Settings/SettingsStore.swift
apps/mac-ime/Sources/TextProcessor/TextProcessor.swift
apps/mac-ime/Tests/TextProcessorTests/ASRAdapterTests.swift
apps/mac-ime/Tests/TextProcessorTests/AppCompatibilityProfileTests.swift
apps/mac-ime/Tests/TextProcessorTests/CloudStreamingFinalizationGuardTests.swift
apps/mac-ime/Tests/TextProcessorTests/CloudStreamingStableCommitGuardTests.swift
apps/mac-ime/Tests/TextProcessorTests/CorrectionDiffDetectorTests.swift
apps/mac-ime/Tests/TextProcessorTests/FillerBlacklistStoreTests.swift
apps/mac-ime/Tests/TextProcessorTests/FinalInsertionGuardTests.swift
apps/mac-ime/Tests/TextProcessorTests/InsertionStabilityGuardTests.swift
apps/mac-ime/Tests/TextProcessorTests/LexiconPersistenceTests.swift
apps/mac-ime/Tests/TextProcessorTests/LexiconServiceTests.swift
apps/mac-ime/Tests/TextProcessorTests/LivePreviewCommitPolicyTests.swift
apps/mac-ime/Tests/TextProcessorTests/PermissionSupportTests.swift
apps/mac-ime/Tests/TextProcessorTests/PunctuationLearningStoreTests.swift
apps/mac-ime/Tests/TextProcessorTests/PunctuationResetCoordinatorTests.swift
apps/mac-ime/Tests/TextProcessorTests/TextProcessorTests.swift
```

### `core`

```text
core/asr/README.md
core/lexicon/README.md
core/text-processor/README.md
```

### `docs`

```text
docs/GITHUB_OPEN_SOURCE_UPLOAD_LIST.md
docs/PRODUCT_OVERVIEW.md
docs/RUNTIME_MODES.md
docs/TECHNICAL_ARCHITECTURE.md
```

## 本地更新检查结果

### 这次本地已修改并继续同步的文件

```text
.gitignore
README.md
apps/mac-ime/Package.swift
apps/mac-ime/Scripts/package_demo_app.sh
apps/mac-ime/Sources/MyTypeIMEDemo/LocalASRAssetManager.swift
apps/mac-ime/Sources/MyTypeIMEDemo/main.swift
docs/GITHUB_OPEN_SOURCE_UPLOAD_LIST.md
```

这些文件都属于本次继续保留的软件相关公开范围。

### 这次本地新增，并纳入本次同步范围的源码文件

```text
apps/mac-ime/Sources/Common/MyTypePermissionSupport.swift
apps/mac-ime/Sources/MyTypeIMEDemo/FirstRunSetupWizardController.swift
apps/mac-ime/Sources/MyTypeIMEDemo/SetupReadinessSupport.swift
apps/mac-ime/Tests/TextProcessorTests/PermissionSupportTests.swift
```

这些文件已经加入本文白名单，可以跟随本次软件更新一起上传。

### 本次会从 GitHub 移除的非软件相关公开文件

```text
docs/MyType语音输入法-API设置教程.md
docs/assets/MyType语音输入法-API设置教程/file-20260429140027397.png
docs/assets/MyType语音输入法-API设置教程/file-20260429140027399 1.png
docs/assets/MyType语音输入法-API设置教程/file-20260429140027399.png
docs/assets/MyType语音输入法-API设置教程/file-20260429140027401.png
docs/assets/MyType语音输入法-API设置教程/file-20260429140027402.png
docs/assets/MyType语音输入法-API设置教程/file-20260429140027404.png
docs/assets/MyType语音输入法-API设置教程/file-20260429140027405.png
docs/assets/MyType语音输入法-API设置教程/file-20260429140027408.png
```

这些内容不再属于软件仓库公开范围，本次更新后应从 GitHub 仓库中删除。

### 这次本地存在、但不应上传到 GitHub 的素材文件

```text
1.jpg
ChatGPT Image 2026年4月18日 14_20_30.png
app logo new.png
app截图/iShot_2026-04-28_15.25.59.png
app截图/iShot_2026-04-28_15.26.14.png
app截图/iShot_2026-04-28_15.26.21.png
ig_0cc4b60ebb3923de0169ee376579f08191b8392c491b0ddbea.png
ig_0cc4b60ebb3923de0169ee37eb16848191a3e3bc5b94887e7d.png
ig_0cc4b60ebb3923de0169ee394520988191927aa3c2443d2a14.png
mytype app logov2.psd
```

这些文件已经不符合当前公开仓库范围，我已经把它们加入 `.gitignore`，降低后续误传风险。

## 每次上传前的最小检查流程

1. 先执行 `git fetch origin`，确保本地看到的是最新远端状态。
2. 看一眼 `git status --short`，确认准备上传的文件范围。
3. 只 `git add` 白名单里的路径。
4. 上传前再检查一次 `git diff --cached --name-only`。
5. 如果出现白名单外的新文件，先决定是否真的要开源；若要开源，先更新本文，再上传。
