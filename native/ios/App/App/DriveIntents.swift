import AppIntents
import UIKit
import Capacitor
import WebKit

// Siri and Shortcuts: "Start Dragon Drive" and "Dragon, I'm done". "Dragon" is the app's Siri synonym (INAlternativeAppNames in
// Info.plist), so every \(.applicationName) phrase works with "Dragon" as well as "Dragon Drive". The short name matters
// for finishing: anything with "drive" in it, said while driving, Siri may hand to Apple Maps. They need no setup and no
// entitlement: App Shortcuts appear in Siri, Spotlight and the Shortcuts app as soon as the app is installed, so a
// Shortcuts automation such as "when my iPhone connects to CarPlay, start a drive" can start one with no tap.
//
// The drive is recorded by native code (DriveRecorder.swift), so these intents run without opening the app:
// openAppWhenRun is false and authenticationPolicy is alwaysAllowed, so with "Allow Siri When Locked" on (Settings,
// Siri) they work on a locked phone with no Face ID. These cases need the app itself on screen, and then the intent
// asks iOS to bring the app up (needsToContinueInForegroundError: iOS shows an Open button, plus Face ID or the
// passcode if the phone is locked) and carries on there. Siri runs intents with the app off screen even when the phone
// is unlocked, so they happen unlocked too, which is why the dialogs say "open Dragon Drive", not "unlock":
// - starting a Phone GPS drive without "Always" location permission (iOS lets a "While Using" app start GPS only on screen);
// - a Dragy or other Bluetooth GPS drive, which lives in the web app, whose JavaScript is paused off screen;
// - a RaceBox drive before the RaceBox has been connected once in the app (iOS asks for Bluetooth only on screen).
// A RaceBox drive needs no location permission: the recorder connects the remembered RaceBox itself.

@available(iOS 16.4, *)
struct StartDriveIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Start a drive"
    static var description = IntentDescription("Starts recording a drive with Phone GPS or your RaceBox, even with the phone locked.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rec = DriveRecorder.shared
        rec.boot()
        // The Bluetooth state is not known for a moment after the app launches in the background.
        if rec.config.source == "racebox" { _ = await RaceBoxLink.shared.whenReady(timeout: 3) }
        switch rec.start(origin: "siri") {
        case .started:
            if rec.source == "racebox" {
                if await rec.waitForRaceBox(seconds: 8) {
                    return .result(dialog: "Recording your drive from your RaceBox. Say \"Dragon, I'm done\" when you finish.")
                }
                return .result(dialog: "Your drive will record as soon as your RaceBox connects. Make sure it's on.")
            }
            return .result(dialog: "Recording your drive. Say \"Dragon, I'm done\" when you finish.")
        case .already:
            return .result(dialog: "You're already recording a drive.")
        case .denied:
            return .result(dialog: "Location is off for Dragon Drive. Turn it on in Settings, then try again.")
        case .needsPage:
            throw needsToContinueInForegroundError("Your Bluetooth GPS runs inside Dragon Drive, so I need to open the app to start.") {
                PageCommand.send("siri-start")
            }
        case .needsDevice:
            throw needsToContinueInForegroundError("I need to open Dragon Drive once to connect your RaceBox. After that, I can start RaceBox drives without opening it.") {
                PageCommand.send("siri-start")
            }
        case .bluetoothOff:
            return .result(dialog: "Bluetooth is off. Turn it on to record from your RaceBox, then try again.")
        case .needsForeground:
            throw needsToContinueInForegroundError("I need to open Dragon Drive to start, because its location is set to While Using. Set it to Always on the Drive screen and I can start drives without opening it.") {
                DriveRecorder.shared.start(origin: "siri", force: true)
                PageCommand.send("show")
            }
        }
    }
}

// Lets Siri's start put the drive on the lock screen (a Live Activity, DriveActivity.swift) with the phone locked:
// iOS lets an app start one from the background only from an intent that says it does.
@available(iOS 17.0, *)
extension StartDriveIntent: LiveActivityStartingIntent {}

// "Start filming with Dragon Drive": a drive with the phone camera on. A plain start never films; filming has to be
// asked for. iOS lets an app use the camera only on screen, so this one always needs the phone unlocked and the app
// open (it asks iOS to unlock if needed). Said during a drive, it turns the camera on for that drive.
@available(iOS 16.4, *)
struct FilmDriveIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Start filming"
    static var description = IntentDescription("Starts recording a drive and films the road with the phone camera. Needs the phone unlocked.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    static func go() {
        let rec = DriveRecorder.shared
        if (rec.config.source == "phone" || rec.config.source == "racebox") && !rec.pageDrive { rec.start(origin: "siri", force: true) }
        PageCommand.send("film")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DriveRecorder.shared.boot()
        if DriveRecorder.shared.appActive {
            FilmDriveIntent.go()
            return .result(dialog: "Filming your drive.")
        }
        throw needsToContinueInForegroundError("iPhone only lets apps film while they're open on screen, so I need to open Dragon Drive to film. For video with the phone locked, pair a GoPro on the Drive screen.") {
            FilmDriveIntent.go()
        }
    }
}

@available(iOS 16.4, *)
struct FinishDriveIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Finish recording"
    static var description = IntentDescription("Finishes and saves the drive you're recording, even with the phone locked.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rec = DriveRecorder.shared
        rec.boot()
        switch rec.finish(origin: "siri") {
        case .saved(let meters):
            return .result(dialog: IntentDialog(stringLiteral: "Saved your " + rec.spoken(meters) + " drive."))
        case .tooShort:
            return .result(dialog: "That drive was too short to save.")
        case .notRecording:
            if rec.pageDrive {
                throw needsToContinueInForegroundError("Your Bluetooth GPS drive runs inside Dragon Drive, so I need to open the app to finish it.") {
                    PageCommand.send("finish")
                }
            }
            return .result(dialog: "You're not recording a drive.")
        }
    }
}

@available(iOS 16.4, *)
struct DriveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDriveIntent(), phrases: [
            "Start \(.applicationName)",
            "\(.applicationName) start",
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
            "Let's drive with \(.applicationName)",
            "\(.applicationName) let's ride",
            "\(.applicationName) let's go",
            "Let's ride with \(.applicationName)"
        ])
        AppShortcut(intent: FilmDriveIntent(), phrases: [
            "Start driving with \(.applicationName) and film it",
            "Start driving in \(.applicationName) and film it",
            "Start a drive with \(.applicationName) and film it",
            "Start \(.applicationName) and film it",
            "Start filming with \(.applicationName)",
            "Start filming in \(.applicationName)",
            "\(.applicationName) start filming",
            "\(.applicationName) film",
            "Film with \(.applicationName)",
            "Film my drive with \(.applicationName)",
            "Film my drive in \(.applicationName)",
            "Record video with \(.applicationName)",
            "Record video in \(.applicationName)"
        ])
        // Finishing. Keep "drive", "route", "trip" and "navigation" out of these: said while driving, Siri sent "End my
        // drive in Dragon Drive" to Apple Maps. "Dragon, I'm done" (the synonym, no "drive" at all) is the one to teach.
        AppShortcut(intent: FinishDriveIntent(), phrases: [
            "\(.applicationName) I'm done",
            "\(.applicationName) done",
            "\(.applicationName) all done",
            "\(.applicationName) we're done",
            "I'm done with \(.applicationName)",
            "Done with \(.applicationName)",
            "\(.applicationName) stop",
            "Stop \(.applicationName)",
            "\(.applicationName) end",
            "End \(.applicationName)",
            "\(.applicationName) finish",
            "Finish \(.applicationName)",
            "\(.applicationName) stop recording",
            "\(.applicationName) finish recording",
            "\(.applicationName) save it",
            "\(.applicationName) wrap it up",
            "Stop recording with \(.applicationName)",
            "Finish recording with \(.applicationName)",
            "Done recording with \(.applicationName)",
            "Wrap it up with \(.applicationName)",
            "Save my recording with \(.applicationName)",
            "Finish up with \(.applicationName)"
        ])
    }
}

// Hands a command ("start", "siri-start", "film", "finish", "show") to the page. The app may have just been launched and the page still loading,
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
