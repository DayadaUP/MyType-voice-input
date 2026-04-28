#if canImport(AppKit)
import AppKit

public enum MyTypeAppearance {
    public static var fixedLightMode: NSAppearance? {
        NSAppearance(named: .aqua)
    }

    public static func isDark(_ appearance: NSAppearance?) -> Bool {
        guard let appearance else { return false }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    public static func dynamicColor(
        light: @autoclosure @escaping () -> NSColor,
        dark: @autoclosure @escaping () -> NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? dark() : light()
        }
    }

    public static func resolvedColor(_ color: NSColor, for appearance: NSAppearance?) -> NSColor {
        _ = appearance
        return color
    }

    public static func resolvedCGColor(_ color: NSColor, for appearance: NSAppearance?) -> CGColor {
        resolvedColor(color, for: appearance).cgColor
    }

    @MainActor
    public static func applyFixedLightAppearance(to window: NSWindow) {
        window.appearance = fixedLightMode
    }
}
#endif
