import Foundation
import IOKit.pwr_mgt

/// Stops the Mac from going to sleep while switched on. The screen may still dim.
@MainActor final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    private var assertion: IOPMAssertionID = 0

    @Published var on = false {
        didSet {
            guard on != oldValue else { return }
            if on {
                let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), "Deck: keep awake" as CFString, &assertion)
                if ok != kIOReturnSuccess { on = false }
            } else {
                IOPMAssertionRelease(assertion)
            }
        }
    }
}
