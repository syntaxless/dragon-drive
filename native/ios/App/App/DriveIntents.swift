import AppIntents
import UIKit
import Capacitor
import WebKit

// Siri and Shortcuts: "Start a drive with Dragon Drive" and "End my drive with Dragon Drive" ("in" works too). They need no setup and no
// entitlement: App Shortcuts appear in Siri, Spotlight and the Shortcuts app as soon as the app is installed, so a
// Shortcuts automation such as "when my iPhone connects to CarPlay, start a drive" can start one with no tap.
//
// The drive itself lives in the web app (app.html), whose JavaScript iOS pauses in the background, so each intent
// opens the app and hands the command to the page through PageCommand, the same path as the Home Screen Quick Action.

@available(iOS 16.0, *)
struct StartDriveIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a drive"
    static var description = IntentDescription("Starts recording a drive with your usual data source, vehicle and camera setting.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PageCommand.send("start")
        return .result(dialog: "Starting your drive.")
    }
}

@available(iOS 16.0, *)
struct FinishDriveIntent: AppIntent {
    static var title: LocalizedStringResource = "End my drive"
    static var description = IntentDescription("Finishes and saves the drive you're recording.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PageCommand.send("finish")
        return .result(dialog: "Ending your drive.")
    }
}

@available(iOS 16.0, *)
struct DriveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDriveIntent(), phrases: [
            "Start a drive with \(.applicationName)",
            "Start a drive in \(.applicationName)",
            "Start my drive with \(.applicationName)",
            "Start my drive in \(.applicationName)",
            "Start driving with \(.applicationName)",
            "Start driving in \(.applicationName)",
            "Begin a drive with \(.applicationName)",
            "Begin a drive in \(.applicationName)",
            "Begin my drive with \(.applicationName)",
            "Begin my drive in \(.applicationName)",
            "Record a drive with \(.applicationName)",
            "Record a drive in \(.applicationName)",
            "Record my drive with \(.applicationName)",
            "Record my drive in \(.applicationName)",
            "Start recording with \(.applicationName)",
            "Start recording in \(.applicationName)",
            "Start logging with \(.applicationName)",
            "Start logging in \(.applicationName)",
            "Log a drive with \(.applicationName)",
            "Log a drive in \(.applicationName)",
            "Track my drive with \(.applicationName)",
            "Track my drive in \(.applicationName)",
            "New drive with \(.applicationName)",
            "New drive in \(.applicationName)",
            "\(.applicationName) start a drive",
            "\(.applicationName) start my drive",
            "\(.applicationName) start recording",
            "\(.applicationName) let's drive",
            "Let's drive with \(.applicationName)"
        ])
        AppShortcut(intent: FinishDriveIntent(), phrases: [
            "End my drive with \(.applicationName)",
            "End my drive in \(.applicationName)",
            "End the drive with \(.applicationName)",
            "End the drive in \(.applicationName)",
            "End a drive with \(.applicationName)",
            "End a drive in \(.applicationName)",
            "Finish my drive with \(.applicationName)",
            "Finish my drive in \(.applicationName)",
            "Finish the drive with \(.applicationName)",
            "Finish the drive in \(.applicationName)",
            "Stop my drive with \(.applicationName)",
            "Stop my drive in \(.applicationName)",
            "Stop the drive with \(.applicationName)",
            "Stop the drive in \(.applicationName)",
            "Stop driving with \(.applicationName)",
            "Stop driving in \(.applicationName)",
            "Stop recording with \(.applicationName)",
            "Stop recording in \(.applicationName)",
            "Stop logging with \(.applicationName)",
            "Stop logging in \(.applicationName)",
            "Save my drive with \(.applicationName)",
            "Save my drive in \(.applicationName)",
            "\(.applicationName) end my drive",
            "\(.applicationName) finish my drive",
            "\(.applicationName) stop my drive",
            "\(.applicationName) stop recording",
            "I'm done driving with \(.applicationName)",
            "I'm done driving in \(.applicationName)"
        ])
    }
}

// Hands a command ("start", "finish") to the page. The app may have just been launched and the page still loading,
// so ask every 0.3 s, for up to 20 s, until window.ddQuick (app.html) answers true.
enum PageCommand {
    private static var pending: String?
    private static var timer: Timer?
    private static var tries = 0

    static func send(_ action: String) {
        DispatchQueue.main.async {
            pending = action
            tries = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in tick() }
            tick()
        }
    }

    private static func tick() {
        guard let action = pending, tries < 66 else { stop(); return }
        tries += 1
        guard let webView = bridgeWebView() else { return }
        webView.evaluateJavaScript("window.ddQuick ? window.ddQuick('\(action)') : false") { result, _ in
            if (result as? Bool) == true, pending == action { stop() }
        }
    }

    private static func stop() {
        pending = nil
        timer?.invalidate()
        timer = nil
    }

    private static func bridgeWebView() -> WKWebView? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows {
                if let vc = w.rootViewController as? CAPBridgeViewController, let wv = vc.webView { return wv }
            }
        }
        return nil
    }
}
