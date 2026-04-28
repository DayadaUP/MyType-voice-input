import Foundation
import AppKit
import ApplicationServices
import Darwin

public struct TextInsertionOptions: Sendable {
    public var restoreClipboard: Bool
    public var restoreDelay: TimeInterval
    public var prePasteDelay: TimeInterval
    public var pasteAttempts: Int
    public var pasteAttemptInterval: TimeInterval
    public var stopRetryWhenTextChanged: Bool
    public var postPasteSettleDelay: TimeInterval

    public init(
        restoreClipboard: Bool = true,
        restoreDelay: TimeInterval = 0.8,
        prePasteDelay: TimeInterval = 0.025,
        pasteAttempts: Int = 1,
        pasteAttemptInterval: TimeInterval = 0.25,
        stopRetryWhenTextChanged: Bool = true,
        postPasteSettleDelay: TimeInterval = 0.12
    ) {
        self.restoreClipboard = restoreClipboard
        self.restoreDelay = restoreDelay
        self.prePasteDelay = prePasteDelay
        self.pasteAttempts = max(1, pasteAttempts)
        self.pasteAttemptInterval = max(0, pasteAttemptInterval)
        self.stopRetryWhenTextChanged = stopRetryWhenTextChanged
        self.postPasteSettleDelay = max(0, postPasteSettleDelay)
    }
}

public extension TextInsertionOptions {
    static func compatibilityPreset(_ profile: AppCompatibilityProfile) -> TextInsertionOptions {
        switch profile {
        case .iPhoneMirroring:
            return TextInsertionOptions(
                restoreClipboard: true,
                restoreDelay: 20.0,
                prePasteDelay: 0.5,
                pasteAttempts: 1,
                pasteAttemptInterval: 0
            )
        case .notion:
            return TextInsertionOptions(
                restoreClipboard: true,
                restoreDelay: 1.2,
                prePasteDelay: 0.06,
                pasteAttempts: 2,
                pasteAttemptInterval: 0.18
            )
        case .browser, .electronLike:
            return TextInsertionOptions(
                restoreClipboard: true,
                restoreDelay: 1.1,
                prePasteDelay: 0.05,
                pasteAttempts: 2,
                pasteAttemptInterval: 0.18
            )
        case .wechat:
            return TextInsertionOptions(
                restoreClipboard: true,
                restoreDelay: 0.9,
                prePasteDelay: 0.08,
                pasteAttempts: 1,
                pasteAttemptInterval: 0
            )
        case .generic:
            return TextInsertionOptions()
        }
    }
}

public enum TextInjectionError: LocalizedError {
    case accessibilityPermissionDenied
    case failedToWritePasteboard
    case failedToCreateKeyboardEvents
    case failedAllStrategies(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required for text insertion."
        case .failedToWritePasteboard:
            return "Failed to write recognized text into the pasteboard."
        case .failedToCreateKeyboardEvents:
            return "Failed to create keyboard events for Command+V."
        case .failedAllStrategies(let details):
            return "Text insertion failed for all strategies: \(details)"
        }
    }
}

public struct FocusedTextSnapshot: Sendable {
    public let appPID: pid_t
    public let text: String

    public init(appPID: pid_t, text: String) {
        self.appPID = appPID
        self.text = text
    }
}

private struct PasteboardSnapshot {
    let items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            return nil
        }

        let clones = pasteboardItems.map { item in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        }
        return PasteboardSnapshot(items: clones)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}

@MainActor
public final class FocusedTextInjector {
    public init() {}

    @discardableResult
    public func insertAccessibilityOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return true }
        guard Self.isAccessibilityTrusted(promptIfNeeded: false) else {
            return false
        }
        return (try? insertViaAccessibility(trimmed)) ?? false
    }

    public func focusedTextSnapshot() -> FocusedTextSnapshot? {
        guard Self.isAccessibilityTrusted(promptIfNeeded: false) else {
            return nil
        }
        guard let applicationElement = focusedApplicationElement(),
              let focusedElement = focusedAXElement() else {
            return nil
        }

        var pid: pid_t = 0
        AXUIElementGetPid(applicationElement, &pid)
        guard pid > 0 else { return nil }

        var valueObject: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            focusedElement,
            "AXValue" as CFString,
            &valueObject
        )
        guard valueResult == .success, let text = valueObject as? String else {
            return nil
        }

        return FocusedTextSnapshot(appPID: pid, text: text)
    }

    public func insert(
        _ text: String,
        options: TextInsertionOptions = TextInsertionOptions()
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard Self.isAccessibilityTrusted(promptIfNeeded: true) else {
            throw TextInjectionError.accessibilityPermissionDenied
        }

        var errors: [String] = []

        do {
            try insertViaPasteboard(
                trimmed,
                options: options
            )
            return
        } catch {
            errors.append(error.localizedDescription)
        }

        if try insertViaAccessibility(trimmed) {
            return
        }
        errors.append("AX insertion failed")
        throw TextInjectionError.failedAllStrategies(errors.joined(separator: "; "))
    }

    private func insertViaAccessibility(_ text: String) throws -> Bool {
        guard let focusedElement = focusedAXElement() else {
            return false
        }

        let selectedTextResult = AXUIElementSetAttributeValue(
            focusedElement,
            "AXSelectedText" as CFString,
            text as CFTypeRef
        )
        if selectedTextResult == .success {
            return true
        }

        // Fallback: replace kAXValue by selected range when supported.
        var valueObject: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            focusedElement,
            "AXValue" as CFString,
            &valueObject
        )
        guard valueResult == .success, let currentText = valueObject as? String else {
            return false
        }
        guard let replaced = replaceSelectedRange(in: currentText, by: text, element: focusedElement) else {
            return false
        }

        let setValueResult = AXUIElementSetAttributeValue(
            focusedElement,
            "AXValue" as CFString,
            replaced as CFTypeRef
        )
        return setValueResult == .success
    }

    private func focusedAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            "AXFocusedUIElement" as CFString,
            &focusedObject
        )
        guard result == .success, let focusedObject else { return nil }
        guard CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else { return nil }
        return (focusedObject as! AXUIElement)
    }

    private func focusedApplicationElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            "AXFocusedApplication" as CFString,
            &focusedObject
        )
        guard result == .success, let focusedObject else { return nil }
        guard CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else { return nil }
        return (focusedObject as! AXUIElement)
    }

    private func replaceSelectedRange(in currentText: String, by replacement: String, element: AXUIElement) -> String? {
        var rangeObject: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextRange" as CFString,
            &rangeObject
        )
        guard result == .success,
              let rangeValueObject = rangeObject,
              CFGetTypeID(rangeValueObject) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = rangeValueObject as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else {
            return nil
        }

        let start = max(0, selectedRange.location)
        let safeStart = min(start, currentText.count)
        let maxLength = max(0, currentText.count - safeStart)
        let safeLength = min(max(0, selectedRange.length), maxLength)

        guard let startIndex = currentText.index(currentText.startIndex, offsetBy: safeStart, limitedBy: currentText.endIndex),
              let endIndex = currentText.index(startIndex, offsetBy: safeLength, limitedBy: currentText.endIndex) else {
            return nil
        }

        let prefix = String(currentText[..<startIndex])
        let suffix = String(currentText[endIndex...])
        return prefix + replacement + suffix
    }

    private func insertViaPasteboard(
        _ text: String,
        options: TextInsertionOptions
    ) throws {
        let pasteboard = NSPasteboard.general
        let snapshot = options.restoreClipboard ? PasteboardSnapshot.capture(from: pasteboard) : nil

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInjectionError.failedToWritePasteboard
        }

        // Give cross-process clipboard readers a brief moment to observe fresh content.
        if options.prePasteDelay > 0 {
            usleep(useconds_t(options.prePasteDelay * 1_000_000))
        }

        for attempt in 0..<options.pasteAttempts {
            let baselineSnapshot = options.stopRetryWhenTextChanged ? focusedTextSnapshot() : nil
            try postCommandV()

            if options.stopRetryWhenTextChanged && attempt < options.pasteAttempts - 1 {
                if options.postPasteSettleDelay > 0 {
                    usleep(useconds_t(options.postPasteSettleDelay * 1_000_000))
                }
                if didFocusedTextChange(from: baselineSnapshot) {
                    break
                }
            }

            if attempt < options.pasteAttempts - 1, options.pasteAttemptInterval > 0 {
                usleep(useconds_t(options.pasteAttemptInterval * 1_000_000))
            }
        }

        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.restoreDelay) {
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private func didFocusedTextChange(from baseline: FocusedTextSnapshot?) -> Bool {
        guard let baseline else { return false }
        guard let current = focusedTextSnapshot() else { return false }
        guard current.appPID == baseline.appPID else { return false }
        return current.text != baseline.text
    }

    public static func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func postCommandV() throws {
        let vKeyCode: CGKeyCode = 9
        let commandKeyCode: CGKeyCode = 55
        let eventSource = CGEventSource(stateID: .combinedSessionState)

        guard let commandDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: commandKeyCode,
            keyDown: true
        ),
        let vDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: vKeyCode,
            keyDown: true
        ),
        let vUp = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: vKeyCode,
            keyDown: false
        ),
        let commandUp = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: commandKeyCode,
            keyDown: false
        ) else {
            throw TextInjectionError.failedToCreateKeyboardEvents
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
    }
}
