import AppKit
import Settings

enum ShortcutTargetAction {
    case primary
}

enum ShortcutInputMode: String {
    case holdToTalk = "hold"
    case continuous = "continuous"

    var title: String {
        switch self {
        case .holdToTalk:
            return "按住说话"
        case .continuous:
            return "持续说话"
        }
    }

    static func fromStored(_ raw: String) -> ShortcutInputMode {
        switch raw {
        case ShortcutInputMode.continuous.rawValue:
            return .continuous
        default:
            return .holdToTalk
        }
    }
}

struct ShortcutBinding: Equatable {
    enum Kind: String {
        case modifier
        case combo
    }

    let kind: Kind
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static let disabledToken = "disabled"
    static let defaultPrimary = ShortcutBinding(kind: .modifier, keyCode: 63, modifiers: [])

    func serialized() -> String {
        "\(kind.rawValue):\(keyCode):\(modifiers.rawValue)"
    }

    static func parse(_ raw: String) -> ShortcutBinding? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != disabledToken else { return nil }
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3 else { return nil }
        guard let kind = Kind(rawValue: pieces[0]),
              let keyCodeValue = UInt16(pieces[1]),
              let modifierRaw = UInt(pieces[2]) else {
            return nil
        }
        return ShortcutBinding(kind: kind, keyCode: keyCodeValue, modifiers: normalizedShortcutFlags(.init(rawValue: modifierRaw)))
    }

    static func load(
        target _: ShortcutTargetAction,
        settings: SettingsStore
    ) -> ShortcutBinding? {
        let raw = settings.string(forKey: SettingsKeys.shortcutHoldToTalk, default: "")
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .defaultPrimary
        }
        return ShortcutBinding.parse(raw)
    }

    func displayString() -> String {
        switch kind {
        case .modifier:
            return modifierName(forKeyCode: keyCode) ?? "Key \(keyCode)"
        case .combo:
            let modifierText = modifierNames(from: modifiers).joined(separator: " + ")
            let keyName = keyDisplayName(forKeyCode: keyCode)
            if modifierText.isEmpty {
                return keyName
            }
            return "\(modifierText) + \(keyName)"
        }
    }
}

final class GlobalShortcutManager {
    enum EventAction {
        case holdPressed
        case holdReleased
        case handsFreeToggle
    }

    var onAction: ((EventAction) -> Void)?

    private let settings: SettingsStore
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var primaryBinding: ShortcutBinding?
    private var inputMode: ShortcutInputMode = .holdToTalk
    private var holdComboActive = false
    private var holdModifierIsDown = false
    private var holdModifierActive = false
    private var pendingHoldModifierPress: DispatchWorkItem?
    private let holdModifierDebounceSeconds: TimeInterval = 0.14

    init(settings: SettingsStore) {
        self.settings = settings
    }

    deinit {
        stop()
    }

    func start() {
        reloadBindings()
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        cancelPendingHoldModifierPress()
        holdComboActive = false
        holdModifierIsDown = false
        holdModifierActive = false
    }

    func reloadBindings() {
        primaryBinding = ShortcutBinding.load(target: .primary, settings: settings)
        let rawMode = settings.string(
            forKey: SettingsKeys.shortcutInputMode,
            default: ShortcutInputMode.holdToTalk.rawValue
        )
        inputMode = ShortcutInputMode.fromStored(rawMode)
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown(event)
        case .keyUp:
            handleKeyUp(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard let primaryBinding, primaryBinding.kind == .combo else { return }
        guard matchesCombo(binding: primaryBinding, event: event), !event.isARepeat else { return }
        switch inputMode {
        case .continuous:
            cancelPendingHoldModifierPress()
            onAction?(.handsFreeToggle)
        case .holdToTalk:
            guard !holdComboActive else { return }
            holdComboActive = true
            onAction?(.holdPressed)
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard inputMode == .holdToTalk else { return }
        guard let primaryBinding, primaryBinding.kind == .combo else { return }
        guard holdComboActive else { return }
        guard event.keyCode == primaryBinding.keyCode else { return }
        holdComboActive = false
        onAction?(.holdReleased)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let primaryBinding,
              primaryBinding.kind == .modifier,
              event.keyCode == primaryBinding.keyCode,
              let expectedFlag = modifierFlag(forKeyCode: primaryBinding.keyCode) else {
            return
        }

        let nowDown = normalizedShortcutFlags(event.modifierFlags).contains(expectedFlag)
        if inputMode == .continuous {
            if nowDown && !holdModifierIsDown {
                cancelPendingHoldModifierPress()
                onAction?(.handsFreeToggle)
            }
            holdModifierIsDown = nowDown
            return
        }

        holdModifierIsDown = nowDown
        if nowDown {
            guard !holdModifierActive else { return }
            schedulePendingHoldModifierPress()
        } else {
            cancelPendingHoldModifierPress()
            if holdModifierActive {
                holdModifierActive = false
                onAction?(.holdReleased)
            }
        }
    }

    private func schedulePendingHoldModifierPress() {
        cancelPendingHoldModifierPress()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.holdModifierIsDown, !self.holdModifierActive else { return }
            self.holdModifierActive = true
            self.onAction?(.holdPressed)
        }
        pendingHoldModifierPress = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdModifierDebounceSeconds, execute: workItem)
    }

    private func cancelPendingHoldModifierPress() {
        pendingHoldModifierPress?.cancel()
        pendingHoldModifierPress = nil
    }

    private func matchesCombo(binding: ShortcutBinding?, event: NSEvent) -> Bool {
        guard let binding, binding.kind == .combo else { return false }
        guard event.keyCode == binding.keyCode else { return false }
        let flags = normalizedShortcutFlags(event.modifierFlags)
        return flags == binding.modifiers
    }
}

func normalizedShortcutFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags.intersection(relevantShortcutModifierFlags)
}

private let relevantShortcutModifierFlags: NSEvent.ModifierFlags = [
    .command, .control, .option, .shift, .function
]

func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
    switch keyCode {
    case 54:
        return .command
    case 55:
        return .command
    case 56:
        return .shift
    case 58:
        return .option
    case 59:
        return .control
    case 60:
        return .shift
    case 61:
        return .option
    case 62:
        return .control
    case 63:
        return .function
    default:
        return nil
    }
}

func modifierName(forKeyCode keyCode: UInt16) -> String? {
    switch keyCode {
    case 54:
        return "Right Command"
    case 55:
        return "Left Command"
    case 56:
        return "Left Shift"
    case 58:
        return "Left Alt"
    case 59:
        return "Left Control"
    case 60:
        return "Right Shift"
    case 61:
        return "Right Alt"
    case 62:
        return "Right Control"
    case 63:
        return "Fn"
    default:
        return nil
    }
}

func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
    var names: [String] = []
    if flags.contains(.command) {
        names.append("Command")
    }

    if flags.contains(.control) {
        names.append("Control")
    }

    if flags.contains(.option) {
        names.append("Alt")
    }

    if flags.contains(.shift) {
        names.append("Shift")
    }

    if flags.contains(.function) {
        names.append("Fn")
    }
    return names
}

func keyDisplayName(forKeyCode keyCode: UInt16) -> String {
    switch keyCode {
    case 36: return "Return"
    case 48: return "Tab"
    case 49: return "Space"
    case 51: return "Delete"
    case 53: return "Esc"
    case 123: return "Left Arrow"
    case 124: return "Right Arrow"
    case 125: return "Down Arrow"
    case 126: return "Up Arrow"
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "O"
    case 32: return "U"
    case 33: return "["
    case 34: return "I"
    case 35: return "P"
    case 37: return "L"
    case 38: return "J"
    case 39: return "'"
    case 40: return "K"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "N"
    case 46: return "M"
    case 47: return "."
    case 50: return "`"
    default:
        return "Key \(keyCode)"
    }
}
