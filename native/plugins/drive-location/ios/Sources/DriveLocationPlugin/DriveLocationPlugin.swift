import Foundation
import Capacitor
import CoreLocation
import UIKit

// Background GPS for a drive.
//
// iOS keeps the app running with the screen locked because it is receiving location (UIBackgroundModes:
// location, allowsBackgroundLocationUpdates, the blue location pill), but the web view's JavaScript is
// suspended while the app is in the background, so a fix pushed to JavaScript then is lost. This plugin
// keeps every fix in native memory instead and the web app collects them with drain(): every second while
// it is on screen, and straight away when it comes back. Nothing is lost while the phone is locked.
// Each fix has a sequence number and stays here until the page confirms it has it (drain's `after`), so
// an answer lost while the page was being paused costs nothing: the next drain sends the fixes again.
// drain() also returns `diag`, a few counters that show what happened while the phone was locked.
@objc(DriveLocationPlugin)
public class DriveLocationPlugin: CAPPlugin, CAPBridgedPlugin, CLLocationManagerDelegate {
    public let identifier = "DriveLocationPlugin"
    public let jsName = "DriveLocation"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "drain", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise)
    ]

    private var manager: CLLocationManager?
    private var running = false
    private var started = Date()
    private var fixes: [[String: Any]] = []
    private var error: String?
    private var session: AnyObject?   // CLBackgroundActivitySession on iOS 17+
    private let lock = NSLock()
    private let maxKept = 20000       // about 5.5 hours at 1 Hz between two drains
    private var seq = 0
    private var total = 0
    private var inBackground = 0      // fixes received while the app was not on screen
    private var lastFix: Date?
    private var events: [String] = []
    private var observing = false

    private func note(_ e: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lock.lock(); events.append("\(e) \(f.string(from: Date()))"); if events.count > 30 { events.removeFirst(events.count - 30) }; lock.unlock()
    }

    private func observeApp() {
        if observing { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.note("background")
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.note("foreground")
        }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.note("locked")
        }
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

    private func currentAuth(_ m: CLLocationManager) -> CLAuthorizationStatus {
        if #available(iOS 14.0, *) { return m.authorizationStatus }
        return CLLocationManager.authorizationStatus()
    }

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let m = self.manager ?? CLLocationManager()
            self.manager = m
            m.delegate = self
            m.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            m.distanceFilter = kCLDistanceFilterNone
            m.activityType = .automotiveNavigation
            m.pausesLocationUpdatesAutomatically = false
            m.allowsBackgroundLocationUpdates = true
            m.showsBackgroundLocationIndicator = true
            self.lock.lock(); self.fixes.removeAll(); self.error = nil; self.seq = 0; self.total = 0; self.inBackground = 0; self.lastFix = nil; self.events.removeAll(); self.lock.unlock()
            self.observeApp()
            self.started = Date()
            self.running = true
            let auth = self.currentAuth(m)
            if auth == .denied || auth == .restricted {
                self.running = false
                call.resolve(["status": self.authName(auth)])
                return
            }
            // "While Using" is enough: updates started on screen carry on in the background with the
            // blue pill showing. "Always" is never asked for.
            if auth == .notDetermined { m.requestWhenInUseAuthorization() }
            if #available(iOS 17.0, *) {
                if self.session == nil { self.session = CLBackgroundActivitySession() }
            }
            m.startUpdatingLocation()
            self.note("start " + self.authName(auth) + (UIApplication.shared.backgroundRefreshStatus == .available ? "" : " no-bg-refresh"))
            call.resolve(["status": self.authName(auth)])
        }
    }

    // Every fix since the last drain, oldest first, and an error if location was refused or failed.
    // `after`: the highest sequence number the page already has; those fixes are dropped here.
    @objc func drain(_ call: CAPPluginCall) {
        let after = call.getInt("after") ?? -1
        lock.lock()
        fixes.removeAll { ($0["seq"] as? Int ?? 0) <= after }
        let out = fixes
        let err = error
        error = nil
        var diag: [String: Any] = ["total": total, "background": inBackground, "events": events, "kept": fixes.count]
        if let l = lastFix { diag["lastFix"] = (l.timeIntervalSince1970 * 1000).rounded() }
        lock.unlock()
        var res: [String: Any] = ["fixes": out, "running": running, "diag": diag]
        if let err = err { res["error"] = err }
        call.resolve(res)
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.running = false
            self.manager?.stopUpdatingLocation()
            self.manager?.allowsBackgroundLocationUpdates = false
            self.note("stop")
            if #available(iOS 17.0, *) {
                (self.session as? CLBackgroundActivitySession)?.invalidate()
            }
            self.session = nil
            self.lock.lock()
            let out = self.fixes
            self.fixes.removeAll()
            self.lock.unlock()
            call.resolve(["fixes": out])
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let m = self.manager ?? CLLocationManager()
            var res: [String: Any] = ["status": self.authName(self.currentAuth(m)), "running": self.running]
            if #available(iOS 14.0, *) { res["precise"] = m.accuracyAuthorization == .fullAccuracy }
            call.resolve(res)
        }
    }

    @objc func openSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            call.resolve()
        }
    }

    public func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) { note("paused") }
    public func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) { note("resumed") }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running else { return }
        // iOS can hand over several fixes at once in the background: keep all of them.
        let rows: [[String: Any]] = locations.filter { $0.timestamp >= started.addingTimeInterval(-2) && $0.horizontalAccuracy >= 0 }.map { l in
            var r: [String: Any] = [
                "lat": l.coordinate.latitude,
                "lon": l.coordinate.longitude,
                "acc": l.horizontalAccuracy,
                "t": (l.timestamp.timeIntervalSince1970 * 1000).rounded()
            ]
            if l.verticalAccuracy >= 0 { r["alt"] = l.altitude }
            if l.speed >= 0 { r["v"] = l.speed }
            if l.course >= 0 { r["hdg"] = l.course }
            return r
        }
        if rows.isEmpty { return }
        let bg = UIApplication.shared.applicationState != .active
        lock.lock()
        total += rows.count
        if bg { inBackground += rows.count }
        lastFix = Date()
        for var r in rows { seq += 1; r["seq"] = seq; fixes.append(r) }
        if fixes.count > maxKept { fixes.removeFirst(fixes.count - maxKept) }
        lock.unlock()
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError err: Error) {
        if let e = err as? CLError, e.code == .locationUnknown { return }   // no fix yet; it keeps trying
        lock.lock()
        error = (err as? CLError)?.code == .denied ? "denied" : err.localizedDescription
        lock.unlock()
        note("error \((err as NSError).code)")
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = currentAuth(manager)
        if running { note("auth " + authName(s)) }
        if s == .denied || s == .restricted {
            lock.lock(); error = "denied"; lock.unlock()
        } else if running && s != .notDetermined {
            manager.startUpdatingLocation()
        }
    }
}
