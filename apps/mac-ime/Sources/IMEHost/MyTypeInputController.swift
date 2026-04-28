#if canImport(InputMethodKit)
import InputMethodKit
import AppKit

public final class MyTypeInputController: IMKInputController {
    public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // TODO: Integrate composition/candidate handling.
        return false
    }
}
#else
public final class MyTypeInputController {
    public init() {}
}
#endif
