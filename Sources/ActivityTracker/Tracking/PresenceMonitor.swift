import AppKit
import IOKit.pwr_mgt

/// Knows whether someone is at the Mac: screen unlocked, awake, and either giving input or watching/meeting.
@MainActor
final class PresenceMonitor {
    private(set) var isScreenLocked = false
    private(set) var isAsleep = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = true }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScreenLocked = false }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = true }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = false }
            })
        }
    }

    var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func isPresent(idleThreshold: TimeInterval) -> Bool {
        guard !isScreenLocked, !isAsleep else { return false }
        return secondsSinceLastInput < idleThreshold || isDisplaySleepBlocked
    }

    /// Video players and call apps hold this assertion, so passive watching or meetings still count as present.
    private var isDisplaySleepBlocked: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let assertions = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (assertions[kIOPMAssertionTypePreventUserIdleDisplaySleep as String] ?? 0) > 0
    }
}
