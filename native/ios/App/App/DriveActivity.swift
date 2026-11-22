import Foundation
import AppIntents
import ActivityKit

// The drive on the lock screen and in the Dynamic Island (a Live Activity). This file is in both targets: the app
// (DriveRecorder starts, updates and ends the activity through LiveDrive) and the DriveWidget extension (draws it).
// Waking a locked phone shows the drive's time and distance with a Finish button, with no unlock.

@available(iOS 16.2, *)
struct DriveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var distance: String        // "12.3 mi", or "" for a Bluetooth drive the page records
        var source: String          // "Phone GPS", "RaceBox", "Bluetooth GPS"
        var canFinish: Bool         // false for a page drive: the Finish button would need the app open
    }
    var start: Date
}

// The lock screen's Finish button. iOS runs a LiveActivityIntent in the app's process, even with the phone locked,
// so it reaches the recorder through the same notification the car screen uses (no import of DriveRecorder here,
// because the widget extension compiles this file too).
@available(iOS 17.0, *)
struct FinishFromLockScreenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish recording"
    static var description = IntentDescription("Finishes and saves the drive you're recording.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: Notification.Name("DDRecorderCommand"), object: nil,
                                            userInfo: ["action": "finish", "origin": "lockscreen"])
        }
        return .result()
    }
}

#if !WIDGET_EXTENSION
// App side: one activity at a time, following the recorder's state.
@available(iOS 16.2, *)
final class LiveDrive {
    static let shared = LiveDrive()
    private var activity: Activity<DriveActivityAttributes>?
    private var last: DriveActivityAttributes.ContentState?
    private var lastAt = Date.distantPast

    // on: a drive is recording (here or in the page). Called on every recorder state change and every 5 s.
    func sync(on: Bool, start: Date, state: DriveActivityAttributes.ContentState) {
        DispatchQueue.main.async { self.apply(on: on, start: start, state: state) }
    }

    private func apply(on: Bool, start: Date, state: DriveActivityAttributes.ContentState) {
        if !on {
            guard let a = activity else { return endStray() }
            activity = nil; last = nil
            Task { await a.end(nil, dismissalPolicy: .immediate) }
            return
        }
        if let a = activity {
            // Swiped away from the lock screen: it stays away for this drive.
            guard a.activityState == .active || a.activityState == .stale else { return }
            // Distance moves in 0.1 steps; iOS budgets updates, so send one only when it changed, at most every 15 s.
            if state != last && Date().timeIntervalSince(lastAt) >= 15 {
                last = state; lastAt = Date()
                Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Started from the background this can fail (iOS lets an app start one from the background only from an
        // App Intent, such as Siri's start); the next call, at the latest when the app comes on screen, tries again.
        endStray()
        if let a = try? Activity.request(attributes: DriveActivityAttributes(start: start),
                                         content: ActivityContent(state: state, staleDate: nil)) {
            activity = a; last = state; lastAt = Date()
        }
    }

    // An activity left over from an earlier launch (the app was closed mid-drive) is ended.
    private func endStray() {
        for a in Activity<DriveActivityAttributes>.activities where a.id != activity?.id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
#endif
