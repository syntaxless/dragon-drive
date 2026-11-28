import Foundation
import UIKit
import CoreLocation
import CoreMotion
import Capacitor

// The drive recorder: native code that owns starting, logging and finishing a Phone GPS drive in the iOS app.
//
// Why it is native: iOS pauses the web app's JavaScript whenever the app is not on screen, and a Siri request or a
// CarPlay tap with the phone locked never brings it on screen. So the recorder runs without the web view: Siri
// ("Start Dragon Drive", "Dragon, I'm done"), CarPlay and the page all drive this one object.
//
// - Every fix is kept in memory and appended to a file as it arrives (Application Support/DriveRecorder), so a drive
//   survives the app being closed or crashing: the next launch finishes it from the file.
// - A drive finished while the page is not running (Siri, CarPlay) is written to finished/<id>.json with its raw fixes.
//   The page collects those when it next runs (DriveRecorderPlugin.finished), builds the drive with the same code as
//   a drive finished on screen (naming, thinning, stats, the home privacy zone when it is shared), and then acks them.
// - A drive the page started, or picked up, the page finishes itself from the fixes it drained, and tells the
//   recorder to drop its copy (cancel).
// - The page tells the recorder the settings it needs (config): data source, vehicle, units and the g-force setting.
//
// Starting location in the background: with "While Using" permission iOS lets an app start location only while it is
// on screen, so a start with the phone locked needs "Always". canStartHere() checks that; without it the Siri intent
// asks iOS to unlock and open the app (and starts there), and the car screen tries anyway and gives up after 20 s with
// no fix, saying why. Finishing needs no permission at all.
//
// RaceBox drives are recorded here too (RaceBoxLink.swift), so they start and finish with the phone locked as well.
// They need no location permission: the readings come from the RaceBox, and the "bluetooth-central" background mode
// keeps them coming with the app off screen. They do need the RaceBox to have been connected once in the app (iOS
// asks for Bluetooth permission only on screen, and the device is reconnected by the id the page remembered).
// Dragy and other Bluetooth GPS still live in the page (pageDrive).

// One reading, kept compact: a RaceBox drive is 25 a second, so a long ride holds hundreds of thousands of these.
// Missing values are NaN.
struct DriveFix {
    var seq = 0
    var t: Double = 0
    var lat: Double = 0
    var lon: Double = 0
    var acc: Double = .nan
    var alt: Double = .nan
    var v: Double = .nan
    var hdg: Double = .nan
    var g: Double = .nan
    var gx: Double = .nan
    var gy: Double = .nan
    var bg = false

    var dict: [String: Any] {
        var r: [String: Any] = ["seq": seq, "t": t, "lat": lat, "lon": lon]
        if !acc.isNaN { r["acc"] = acc }
        if !alt.isNaN { r["alt"] = alt }
        if !v.isNaN { r["v"] = v }
        if !hdg.isNaN { r["hdg"] = hdg }
        if !g.isNaN { r["g"] = g }
        if !gx.isNaN { r["gx"] = gx }
        if !gy.isNaN { r["gy"] = gy }
        return r
    }

    init() {}
    init?(_ d: [String: Any]) {
        guard let la = d["lat"] as? Double, let lo = d["lon"] as? Double, let tt = d["t"] as? Double else { return nil }
        lat = la; lon = lo; t = tt
        seq = d["seq"] as? Int ?? 0
        acc = d["acc"] as? Double ?? .nan
        alt = d["alt"] as? Double ?? .nan
        v = d["v"] as? Double ?? .nan
        hdg = d["hdg"] as? Double ?? .nan
        g = d["g"] as? Double ?? .nan
        gx = d["gx"] as? Double ?? .nan
        gy = d["gy"] as? Double ?? .nan
    }
}

final class DriveRecorder: NSObject, CLLocationManagerDelegate {
    static let shared = DriveRecorder()

    // For DriveRecorderPlugin (same target).
    static let changed = Notification.Name("DDRecorderChanged")
    // Shared with plugins/carplay by name, so neither imports the other.
    // command: userInfo ["action": "start"|"finish"|"state", "origin": String, "reply": ([String: Any]) -> Void]
    // state:   userInfo ["available", "recording", "time", "dist", "notice", "noticeId"]
    static let commandName = Notification.Name("DDRecorderCommand")
    static let stateName = Notification.Name("DDRecorderState")

    // needsDevice: a RaceBox drive with no RaceBox connected in the app yet, or Bluetooth not allowed (iOS asks only
    // on screen). bluetoothOff: Bluetooth is turned off on the phone.
    enum StartResult { case started, already, denied, needsForeground, needsPage, needsDevice, bluetoothOff }
    enum FinishResult { case saved(meters: Double), tooShort, notRecording }

    private(set) var recording = false { didSet { if recording != oldValue { stayAwake() } } }
    private(set) var driveId = ""
    private(set) var startMs: Double = 0
    private(set) var origin = ""
    // "phone" or "racebox": what this drive is recorded from.
    private(set) var source = "phone"
    private(set) var deviceName = ""
    // The page is recording from a Bluetooth device (RaceBox, Dragy): that drive lives in the page, not here.
    var pageDrive = false { didSet { if pageDrive != oldValue { pageSince = Date(); GoPros.shared.drive(on: recording || pageDrive); stayAwake() } } }
    private var pageSince = Date()

    // The screen doesn't dim or lock while any drive is recording and the app is on screen (iOS ignores this off
    // screen). Set here as well as by the page's keep-awake, so a drive Siri or the car screen started counts too.
    private func stayAwake() {
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = self.recording || self.pageDrive }
        liveActivity()
    }

    // The lock screen and Dynamic Island show the drive (DriveActivity.swift) while one records.
    private func liveActivity() {
        guard #available(iOS 16.2, *) else { return }
        let on = recording || pageDrive
        let src = recording ? (source == "racebox" ? "RaceBox" : "Phone GPS") : "Bluetooth GPS"
        LiveDrive.shared.sync(on: on, start: recording ? startedAt : pageSince,
                              state: .init(distance: recording ? distText() : "", source: src, canFinish: recording))
    }

    private var manager: CLLocationManager?
    private var session: AnyObject?          // CLBackgroundActivitySession on iOS 17+
    private let motion = CMMotionManager()
    private var gPeak: Double = 0
    private var fixes: [DriveFix] = []
    private var seq = 0
    private var meters: Double = 0
    private var good = 0                     // fixes that pass the page's accuracy and speed checks
    private var lastGood: DriveFix?
    private var startedAt = Date()
    private var watchdog: Timer?
    private var stateTimer: Timer?
    private var booted = false
    private var file: FileHandle?
    private var unflushed = 0
    private var diagBackground = 0
    private var badRun = 0                   // fixes turned down (accuracy) since the last good one, and the best of them
    private var badBest = Double.infinity
    private var events: [String] = []
    private let lock = NSLock()
    private let maxKept = 400000             // about 4.4 hours of RaceBox at 25 Hz, or 110 hours of Phone GPS (about 40 MB)

    // MARK: settings from the page

    struct Config {
        var source = "phone"
        var vehicle = ""
        var units = "mi"
        var motion = false
        var racebox = ""                     // the RaceBox the page last connected (its iOS id), and its name
        var raceboxName = ""
    }
    private let configKey = "dd.recorder.config"
    var config: Config {
        get {
            let d = UserDefaults.standard.dictionary(forKey: configKey) ?? [:]
            var c = Config()
            c.source = d["source"] as? String ?? c.source
            c.vehicle = d["vehicle"] as? String ?? c.vehicle
            c.units = d["units"] as? String ?? c.units
            c.motion = d["motion"] as? Bool ?? c.motion
            c.racebox = d["racebox"] as? String ?? c.racebox
            c.raceboxName = d["raceboxName"] as? String ?? c.raceboxName
            return c
        }
        set {
            UserDefaults.standard.set(["source": newValue.source, "vehicle": newValue.vehicle,
                                       "units": newValue.units, "motion": newValue.motion,
                                       "racebox": newValue.racebox, "raceboxName": newValue.raceboxName], forKey: configKey)
            if !newValue.racebox.isEmpty { RaceBoxLink.shared.remember(id: newValue.racebox, name: newValue.raceboxName) }
        }
    }

    // MARK: launch

    // Called from AppDelegate on every launch (on screen, in the background for Siri, or for CarPlay). bluetooth is
    // true when iOS relaunched the app for the RaceBox (Bluetooth state restoration) during a RaceBox drive.
    func boot(bluetooth: Bool = false) {
        if booted { return }
        booted = true
        RaceBoxLink.shared.onReading = { [weak self] r in self?.raceBoxReading(r) }
        // queue nil: runs on the posting thread (the car screen posts on the main thread), so the reply comes back
        // before post() returns.
        NotificationCenter.default.addObserver(forName: DriveRecorder.commandName, object: nil, queue: nil) { [weak self] n in
            self?.command(n.userInfo ?? [:])
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.recording else { return }
            self.note("background"); self.flush()
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stayAwake()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.recording else { return }
            self.note("foreground")
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.flush()
        }
        recoverInterrupted(resume: bluetooth)
        if bluetooth { RaceBoxLink.shared.setUp() }
        publish()
    }

    // A drive that was recording when the app last stopped (closed from the app switcher, or a crash) is saved from
    // its file, so it shows up when the page next runs. iOS does not relaunch an app to carry on standard location.
    // A RaceBox drive is different: if iOS ended the app in the background, it relaunches it for the RaceBox's next
    // message (resume), and the drive carries on from its file as if nothing happened.
    private func recoverInterrupted(resume: Bool) {
        guard let meta = readJSON(currentMeta), let id = meta["id"] as? String else { return }
        var rows: [DriveFix] = []
        if let data = try? Data(contentsOf: currentFixes), let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let d = line.data(using: .utf8), let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let f = DriveFix(r) { rows.append(f) }
            }
        }
        let src = meta["source"] as? String ?? "phone"
        var m: Double = 0, n = 0, last: DriveFix?
        for r in rows where accept(r, after: last, source: src) { if let l = last { m += hav(l, r) }; last = r; n += 1 }
        if resume && src == "racebox" {
            resumeRaceBox(meta: meta, rows: rows, meters: m, good: n, last: last)
            return
        }
        if n >= 5 && m >= 100 {
            var out = meta
            out["fixes"] = rows.map { $0.dict }
            out["end"] = rows.last?.t ?? (meta["start"] as? Double) ?? 0
            out["interrupted"] = true
            writeJSON(out, to: finishedDir.appendingPathComponent(id + ".json"))
        }
        removeCurrent()
    }

    private func resumeRaceBox(meta: [String: Any], rows: [DriveFix], meters m: Double, good n: Int, last: DriveFix?) {
        lock.lock()
        fixes = rows; seq = rows.last?.seq ?? 0; meters = m; good = n; lastGood = last; diagBackground = 0; badRun = 0; badBest = .infinity; events.removeAll(); gPeak = 0
        lock.unlock()
        driveId = meta["id"] as? String ?? ""
        startMs = meta["start"] as? Double ?? (Date().timeIntervalSince1970 * 1000).rounded()
        startedAt = Date(timeIntervalSince1970: startMs / 1000)
        origin = meta["origin"] as? String ?? "siri"
        source = "racebox"
        deviceName = meta["device"] as? String ?? RaceBoxLink.shared.name
        recording = true
        file = try? FileHandle(forWritingTo: currentFixes)
        if #available(iOS 13.4, *) { _ = try? file?.seekToEnd() } else { file?.seekToEndOfFile() }
        unflushed = 0
        note("resumed after iOS relaunch")
        RaceBoxLink.shared.driveHold = true
        startStateTimer()
    }

    // MARK: start and finish

    var authStatus: CLAuthorizationStatus {
        let m = manager ?? CLLocationManager()
        if #available(iOS 14.0, *) { return m.authorizationStatus }
        return CLLocationManager.authorizationStatus()
    }

    var appActive: Bool { UIApplication.shared.applicationState == .active }

    // Can location be started from where we are now: on screen with any permission, or anywhere with Always.
    func canStartHere() -> Bool {
        let a = authStatus
        if a == .authorizedAlways { return true }
        return appActive && (a == .authorizedWhenInUse || a == .notDetermined)
    }

    // source: what to record from; nil is the page's choice (config). "phone" or "racebox"; anything else is the page's.
    @discardableResult
    func start(origin: String, source want: String? = nil, force: Bool = false) -> StartResult {
        if recording { return .already }
        if pageDrive { return .already }
        let src = want ?? config.source
        if src == "racebox" { return startRaceBox(origin: origin) }
        let a = authStatus
        if a == .denied || a == .restricted { return .denied }
        if !force && src != "phone" && origin != "app" { return .needsPage }
        if !force && !canStartHere() { return .needsForeground }

        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        m.distanceFilter = kCLDistanceFilterNone
        m.activityType = .automotiveNavigation
        m.pausesLocationUpdatesAutomatically = false
        m.allowsBackgroundLocationUpdates = true
        m.showsBackgroundLocationIndicator = true
        if a == .notDetermined { m.requestWhenInUseAuthorization() }

        beginDrive(origin: origin, source: "phone", device: "")

        if #available(iOS 17.0, *) {
            if session == nil { session = CLBackgroundActivitySession() }
        }
        m.startUpdatingLocation()
        startMotion()
        GoPros.shared.drive(on: true)
        note("start \(origin) " + authName(a) + (appActive ? "" : " locked"))

        // Started off screen without Always (the car screen tries anyway): give up if no fix arrives.
        watchdog?.invalidate()
        if !appActive && a != .authorizedAlways {
            watchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                guard let self = self, self.recording, self.seq == 0 else { return }
                self.cancel(id: self.driveId)
                self.publish(notice: "iPhone wouldn't give Dragon Drive GPS with the phone locked. In Dragon Drive, on the Drive screen, allow location with the phone locked.")
            }
        }
        startStateTimer()
        publish()
        NotificationCenter.default.post(name: DriveRecorder.changed, object: nil, userInfo: ["recording": true, "id": driveId, "origin": origin])
        return .started
    }

    private func beginDrive(origin: String, source src: String, device: String) {
        lock.lock()
        fixes.removeAll(); seq = 0; meters = 0; good = 0; lastGood = nil; diagBackground = 0; badRun = 0; badBest = .infinity; events.removeAll(); gPeak = 0
        lock.unlock()
        driveId = "n" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<46656), radix: 36)
        startMs = (Date().timeIntervalSince1970 * 1000).rounded()
        startedAt = Date()
        self.origin = origin
        source = src
        deviceName = device
        recording = true
        openCurrent()
    }

    private func startStateTimer() {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.publish() }
    }

    // A RaceBox drive: no location needed. The drive starts at once and records as soon as the RaceBox connects
    // (straight away if it is on and near; iOS keeps the request open if it isn't).
    private func startRaceBox(origin: String) -> StartResult {
        let link = RaceBoxLink.shared
        link.setUp()
        guard link.remembered != nil, link.authorized else { return .needsDevice }
        switch link.power {
        case .off: return .bluetoothOff
        case .unauthorized, .unsupported: return .needsDevice
        default: break
        }
        beginDrive(origin: origin, source: "racebox", device: link.name)
        link.driveHold = true
        note("start \(origin) racebox" + (appActive ? "" : " locked") + (link.connected ? " connected" : ""))
        watchdog?.invalidate()
        // Say so on the car screen if the RaceBox hasn't sent a fix after a minute; the drive keeps waiting for it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            guard let self = self, self.recording, self.source == "racebox", self.seq == 0 else { return }
            self.note("no racebox data")
            self.publish(notice: link.connected ? "Your RaceBox is connected but has no GPS fix yet." : "Waiting for your RaceBox. Make sure it's on and near the phone.")
        }
        startStateTimer()
        GoPros.shared.drive(on: true)
        publish()
        NotificationCenter.default.post(name: DriveRecorder.changed, object: nil, userInfo: ["recording": true, "id": driveId, "origin": origin])
        return .started
    }

    // For Siri: wait a few seconds for the RaceBox to connect and send a fix, so the answer says how it went.
    @MainActor
    func waitForRaceBox(seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !recording || source != "racebox" { return false }
            if seq > 0 { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return seq > 0
    }

    private func raceBoxReading(_ r: RaceBoxLink.Reading) {
        guard recording, source == "racebox" else { return }
        var f = DriveFix()
        f.t = r.t; f.lat = r.lat; f.lon = r.lon; f.acc = r.acc; f.alt = r.alt; f.v = r.v; f.hdg = r.hdg
        f.gx = r.gx; f.gy = r.gy; f.g = (hypot(r.gx, r.gy) * 100).rounded() / 100
        append([f])
    }

    private func stopSensors() {
        watchdog?.invalidate(); watchdog = nil
        stateTimer?.invalidate(); stateTimer = nil
        if source == "racebox" {
            RaceBoxLink.shared.driveHold = false
        } else {
            manager?.stopUpdatingLocation()
            manager?.allowsBackgroundLocationUpdates = false
            if #available(iOS 17.0, *) { (session as? CLBackgroundActivitySession)?.invalidate() }
            session = nil
            motion.stopDeviceMotionUpdates()
        }
        recording = false
        GoPros.shared.drive(on: pageDrive)
    }

    // Finish and save here (Siri, CarPlay). Same rules as the page: at least 5 points and 100 m, else it is dropped.
    func finish(origin: String) -> FinishResult {
        guard recording else { return .notRecording }
        note("finish \(origin)")
        stopSensors()
        lock.lock()
        let rows = fixes, m = meters, n = good, ev = events, bg = diagBackground
        lock.unlock()
        let id = driveId
        closeCurrent()
        var result: FinishResult = .tooShort
        if n >= 5 && m >= 100 {
            let out: [String: Any] = ["id": id, "start": startMs, "end": rows.last?.t ?? startMs, "origin": self.origin,
                                      "finishedBy": origin, "vehicle": config.vehicle, "fixes": rows.map { $0.dict },
                                      "source": source, "device": deviceName,
                                      "diag": ["total": rows.count, "background": bg, "events": ev, "kept": rows.count]]
            writeJSON(out, to: finishedDir.appendingPathComponent(id + ".json"))
            result = .saved(meters: m)
        }
        removeCurrent()
        driveId = ""
        publish()
        NotificationCenter.default.post(name: DriveRecorder.changed, object: nil, userInfo: ["recording": false, "id": id, "finished": true])
        return result
    }

    // The page finished (or abandoned) this drive itself: drop the native copy. Only the drive it names, so a late
    // cancel never stops a newer drive.
    func cancel(id: String?) {
        guard recording, id == nil || id == driveId else { return }
        note("cancel")
        stopSensors()
        closeCurrent()
        removeCurrent()
        driveId = ""
        publish()
        NotificationCenter.default.post(name: DriveRecorder.changed, object: nil, userInfo: ["recording": false])
    }

    // MARK: Siri and CarPlay phrasing

    func spoken(_ meters: Double) -> String {
        let km = config.units == "km"
        let v = km ? meters / 1000 : meters / 1609.344
        let n = v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return "\(n) \(km ? (n == "1" ? "kilometer" : "kilometers") : (n == "1" ? "mile" : "miles"))"
    }

    func timeText() -> String {
        let s = max(0, Int(Date().timeIntervalSince(startedAt)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    func distText() -> String {
        lock.lock(); let m = meters; lock.unlock()
        let km = config.units == "km"
        return String(format: "%.1f %@", km ? m / 1000 : m / 1609.344, km ? "km" : "mi")
    }

    // MARK: commands from the car screen

    private func command(_ info: [AnyHashable: Any]) {
        let action = info["action"] as? String ?? ""
        let from = info["origin"] as? String ?? "carplay"
        let reply = info["reply"] as? ([String: Any]) -> Void
        if action == "state" { publish(); reply?(["handled": true]); return }
        if action == "start" {
            switch start(origin: from, force: false) {
            case .started, .already: reply?(["handled": true])
            case .denied: reply?(["handled": true, "notice": "Location is off for Dragon Drive. Turn it on in Settings on your iPhone."])
            case .needsPage, .needsDevice: reply?(["handled": false])
            case .bluetoothOff: reply?(["handled": true, "notice": "Bluetooth is off on your iPhone. Turn it on to record from your RaceBox."])
            case .needsForeground:
                // CarPlay may count as "in use" for While Using permission: try, and the watchdog reports if not.
                if appActive { reply?(["handled": false]) } else { _ = start(origin: from, force: true); reply?(["handled": true]) }
            }
        } else if action == "finish" {
            switch finish(origin: from) {
            case .saved: reply?(["handled": true])
            case .tooShort: reply?(["handled": true, "notice": "That drive was too short to save."])
            case .notRecording: reply?(["handled": false])
            }
        } else {
            reply?(["handled": false])
        }
    }

    // What the car screen shows while the recorder has a drive.
    private var noticeSeq = 0
    func publish(notice: String? = nil) {
        var s: [String: Any] = ["available": true, "recording": recording]
        if recording { s["time"] = timeText(); s["dist"] = distText() }
        liveActivity()
        if let n = notice { noticeSeq += 1; s["notice"] = n; s["noticeId"] = "rec\(noticeSeq)" }
        DispatchQueue.main.async { NotificationCenter.default.post(name: DriveRecorder.stateName, object: nil, userInfo: s) }
    }

    // MARK: for the page

    // At most `limit` fixes a call, so a long stretch locked doesn't make one huge message (the page asks again).
    func drain(after: Int, limit: Int = 20000) -> [String: Any] {
        lock.lock()
        var out: [[String: Any]] = []
        if let first = fixes.first?.seq {
            let from = max(0, after + 1 - first)
            if from < fixes.count {
                let to = min(fixes.count, from + limit)
                out.reserveCapacity(to - from)
                for i in from..<to { out.append(fixes[i].dict) }
            }
        }
        let more = (fixes.last?.seq ?? 0) > ((out.last?["seq"] as? Int) ?? after)
        var diag: [String: Any] = ["total": seq, "background": diagBackground, "events": events, "kept": fixes.count]
        if let l = fixes.last?.t { diag["lastFix"] = l }
        lock.unlock()
        return ["fixes": out, "more": more, "running": recording, "id": driveId, "source": source, "diag": diag]
    }

    func status() -> [String: Any] {
        var r: [String: Any] = ["status": authName(authStatus), "recording": recording, "pageDrive": pageDrive,
                                "finished": finishedIds().count, "racebox": RaceBoxLink.shared.status()]
        if #available(iOS 14.0, *) { r["precise"] = (manager ?? CLLocationManager()).accuracyAuthorization == .fullAccuracy }
        if recording { r["id"] = driveId; r["start"] = startMs; r["origin"] = origin; r["source"] = source; r["device"] = deviceName }
        return r
    }

    func finishedDrives() -> [[String: Any]] {
        finishedIds().compactMap { readJSON(finishedDir.appendingPathComponent($0 + ".json")) }
    }

    func ack(_ ids: [String]) {
        for id in ids where !id.contains("/") { try? FileManager.default.removeItem(at: finishedDir.appendingPathComponent(id + ".json")) }
    }

    // "Always": asked once by iOS while the app is on screen; after that only Settings can change it.
    private var alwaysWaiters: [(String) -> Void] = []
    func requestAlways(_ done: @escaping (String) -> Void) {
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        let a = authStatus
        if a == .authorizedAlways || a == .denied || a == .restricted { done(authName(a)); return }
        alwaysWaiters.append(done)
        m.requestAlwaysAuthorization()
        // No answer when iOS has already asked once: report what we have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.answerAlways(prompted: false) }
    }

    private func answerAlways(prompted: Bool) {
        if alwaysWaiters.isEmpty { return }
        let a = authStatus
        if !prompted && a == .notDetermined { return }
        let w = alwaysWaiters; alwaysWaiters = []
        for f in w { f(authName(a)) }
    }

    // MARK: location and motion

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard recording, source == "phone" else { return }
        var rows: [DriveFix] = []
        for l in locations where l.timestamp >= startedAt.addingTimeInterval(-2) && l.horizontalAccuracy >= 0 {
            var f = DriveFix()
            f.lat = l.coordinate.latitude; f.lon = l.coordinate.longitude; f.acc = l.horizontalAccuracy
            f.t = (l.timestamp.timeIntervalSince1970 * 1000).rounded()
            if l.verticalAccuracy >= 0 { f.alt = l.altitude }
            if l.speed >= 0 { f.v = l.speed }
            if l.course >= 0 { f.hdg = l.course }
            rows.append(f)
        }
        if rows.isEmpty { return }
        lock.lock()
        if motion.isDeviceMotionActive { rows[rows.count - 1].g = (gPeak * 100).rounded() / 100; gPeak = 0 }
        lock.unlock()
        append(rows)
    }

    // New readings into the drive: memory, the distance so far, and the file.
    private func append(_ rows: [DriveFix]) {
        let bg = !appActive
        lock.lock()
        var lines = ""
        var gaps: [String] = []
        for var r in rows {
            seq += 1; r.seq = seq; r.bg = bg
            if bg { diagBackground += 1 }
            if accept(r, after: lastGood, source: source) {
                // A hole of over 15 s (what the map draws dashed): say whether iOS sent nothing or sent fixes too rough to keep
                if let l = lastGood, r.t - l.t > 15000 {
                    let best = badBest.isFinite ? " best \(Int(badBest)) m" : ""
                    gaps.append("gap \(Int((r.t - l.t) / 1000))s: \(badRun) rough" + best + (bg ? " bg" : ""))
                }
                if let l = lastGood { meters += hav(l, r) }; lastGood = r; good += 1; badRun = 0; badBest = .infinity
            } else if source != "racebox" && !(r.acc <= 40) { badRun += 1; badBest = min(badBest, r.acc) }
            fixes.append(r)
            if let d = try? JSONSerialization.data(withJSONObject: r.dict), let s = String(data: d, encoding: .utf8) { lines += s + "\n" }
        }
        if fixes.count > maxKept { fixes.removeFirst(fixes.count - maxKept) }
        unflushed += rows.count
        lock.unlock()
        for g in gaps { note(g) }
        if let d = lines.data(using: .utf8) { file?.write(d) }
        // A RaceBox sends 25 a second: write to disk about once a second either way.
        if unflushed >= (source == "racebox" ? 25 : 15) { flush() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError err: Error) {
        if let e = err as? CLError, e.code == .locationUnknown { return }
        note("error \((err as NSError).code)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = authStatus
        if recording { note("auth " + authName(s)) }
        if s != .notDetermined { answerAlways(prompted: true) }
        if recording && (s == .authorizedAlways || s == .authorizedWhenInUse) { manager.startUpdatingLocation() }
    }

    // The same g as the page's: the largest sideways-and-along acceleration (gravity taken out) since the last fix.
    private func startMotion() {
        guard config.motion, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] dm, _ in
            guard let self = self, let dm = dm else { return }
            let a = dm.userAcceleration, g = dm.gravity
            let gn = max(1e-6, sqrt(g.x * g.x + g.y * g.y + g.z * g.z))
            let dot = (a.x * g.x + a.y * g.y + a.z * g.z) / gn
            let hx = a.x - dot * g.x / gn, hy = a.y - dot * g.y / gn, hz = a.z - dot * g.z / gn
            let h = sqrt(hx * hx + hy * hy + hz * hz)
            if h < 3 { self.lock.lock(); self.gPeak = max(self.gPeak, h); self.lock.unlock() }
        }
    }

    // MARK: helpers

    // The page's own checks (app.html ingest and startRec): accuracy within 40 m (Phone GPS only: the page takes every
    // RaceBox fix it has), under 90 m/s, time moving forward.
    private func accept(_ r: DriveFix, after last: DriveFix?, source src: String) -> Bool {
        if src != "racebox" && !(r.acc <= 40) { return false }
        if !r.v.isNaN && r.v > 90 { return false }
        if let l = last, r.t <= l.t { return false }
        return true
    }

    private func hav(_ a: DriveFix, _ b: DriveFix) -> Double {
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dla = la2 - la1, dlo = (b.lon - a.lon) * .pi / 180
        let h = sin(dla / 2) * sin(dla / 2) + cos(la1) * cos(la2) * sin(dlo / 2) * sin(dlo / 2)
        return 2 * 6371000 * asin(min(1, sqrt(h)))
    }

    private func authName(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "prompt"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "unknown"
        }
    }

    private func note(_ e: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lock.lock(); events.append("\(e) \(f.string(from: Date()))"); if events.count > 30 { events.removeFirst(events.count - 30) }; lock.unlock()
    }

    // MARK: files (readable and writable with the phone locked, once it has been unlocked since it was turned on)

    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DriveRecorder", isDirectory: true)
        let fin = base.appendingPathComponent("finished", isDirectory: true)
        let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? FileManager.default.createDirectory(at: fin, withIntermediateDirectories: true, attributes: attrs)
        return base
    }()
    private var finishedDir: URL { dir.appendingPathComponent("finished", isDirectory: true) }
    private var currentMeta: URL { dir.appendingPathComponent("current.json") }
    private var currentFixes: URL { dir.appendingPathComponent("current.jsonl") }

    private func finishedIds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: finishedDir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private func openCurrent() {
        writeJSON(["id": driveId, "start": startMs, "origin": origin, "vehicle": config.vehicle, "source": source, "device": deviceName], to: currentMeta)
        FileManager.default.createFile(atPath: currentFixes.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        file = try? FileHandle(forWritingTo: currentFixes)
        unflushed = 0
    }

    private func flush() {
        if let f = file { if #available(iOS 13.0, *) { try? f.synchronize() } else { f.synchronizeFile() } }
        unflushed = 0
    }

    private func closeCurrent() {
        flush()
        if let f = file { if #available(iOS 13.0, *) { try? f.close() } else { f.closeFile() } }
        file = nil
    }

    private func removeCurrent() {
        try? FileManager.default.removeItem(at: currentMeta)
        try? FileManager.default.removeItem(at: currentFixes)
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// The page's side of the recorder. Registered on the bridge by DDBridgeViewController (SceneDelegate.swift), because
// it lives in the app target, next to the Siri intents, instead of in a plugin package.
@objc(DriveRecorderPlugin)
public class DriveRecorderPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "DriveRecorderPlugin"
    public let jsName = "DriveRecorder"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "drain", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finished", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "config", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pageDrive", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestAlways", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "raceboxLink", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "raceboxUnlink", returnType: CAPPluginReturnPromise)
    ]
    private var rec: DriveRecorder { DriveRecorder.shared }

    override public func load() {
        NotificationCenter.default.addObserver(forName: DriveRecorder.changed, object: nil, queue: .main) { [weak self] n in
            var d: [String: Any] = [:]
            for (k, v) in n.userInfo ?? [:] { if let k = k as? String { d[k] = v } }
            self?.notifyListeners("changed", data: d)
        }
        NotificationCenter.default.addObserver(forName: RaceBoxLink.changed, object: nil, queue: .main) { [weak self] n in
            var d: [String: Any] = [:]
            for (k, v) in n.userInfo ?? [:] { if let k = k as? String { d[k] = v } }
            self?.notifyListeners("racebox", data: d)
        }
    }

    // Starts a drive, or answers with the one already running (the page then picks it up).
    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let r = self.rec.start(origin: call.getString("origin") ?? "app", source: call.getString("source"), force: true)
            var out = self.rec.status()
            switch r {
            case .started: out["started"] = true
            case .already: out["already"] = true
            case .needsDevice: out["error"] = "device"
            case .bluetoothOff: out["error"] = "bluetoothOff"
            default: break
            }
            call.resolve(out)
        }
    }

    @objc func drain(_ call: CAPPluginCall) {
        let after = call.getInt("after") ?? -1
        call.resolve(rec.drain(after: after))
    }

    // The page's RaceBox, connected and held by the recorder while the app is on screen (the page shows its status
    // from the "racebox" event). The page's own device picker finds it; this takes over from there.
    @objc func raceboxLink(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let link = RaceBoxLink.shared
            if let id = call.getString("id") {
                var c = self.rec.config
                c.racebox = id; c.raceboxName = call.getString("name") ?? ""
                self.rec.config = c
            }
            link.ready { _ in
                link.pageHold = true
                call.resolve(link.status())
            }
        }
    }

    @objc func raceboxUnlink(_ call: CAPPluginCall) {
        DispatchQueue.main.async { RaceBoxLink.shared.pageHold = false; call.resolve(RaceBoxLink.shared.status()) }
    }

    @objc func cancel(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.rec.cancel(id: call.getString("id")); call.resolve() }
    }

    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(self.rec.status()) }
    }

    @objc func finished(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["drives": self.rec.finishedDrives()]) }
    }

    @objc func ack(_ call: CAPPluginCall) {
        let ids = (call.getArray("ids") as? [String]) ?? []
        DispatchQueue.main.async { self.rec.ack(ids); call.resolve() }
    }

    @objc func config(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            var c = self.rec.config
            if let s = call.getString("source") { c.source = s }
            if let v = call.getString("vehicle") { c.vehicle = v }
            if let u = call.getString("units") { c.units = u }
            if let m = call.getBool("motion") { c.motion = m }
            if let r = call.getString("racebox") { c.racebox = r }
            if let n = call.getString("raceboxName") { c.raceboxName = n }
            self.rec.config = c
            call.resolve()
        }
    }

    @objc func pageDrive(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.rec.pageDrive = call.getBool("on") ?? false; call.resolve() }
    }

    @objc func requestAlways(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.rec.requestAlways { s in call.resolve(["status": s]) } }
    }

    @objc func openSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            call.resolve()
        }
    }
}
