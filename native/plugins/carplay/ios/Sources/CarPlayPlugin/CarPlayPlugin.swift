import Foundation
import UIKit
import CarPlay
import Capacitor

// CarPlay for Dragon Drive (category: Driving Task, entitlement com.apple.developer.carplay-driving-task).
//
// The car screen is one list: Start drive or Finish drive (with the drive's time and distance), and Follow a
// route, which opens the list of planned routes. The drive itself still lives in the web app (app.html):
// a tap here becomes an event for it ("start", "finish", "follow", "unfollow"), and the web app answers
// with update(), the state the car screen shows. CarPlayHub holds that state and any events the page has not
// collected yet, because CarPlay can connect before the web view exists (the app launched from the car).
//
// Apple's rules for driving-task apps that shape this: only the system templates (no map, no video), at most
// two templates deep, and the data on screen refreshed no more than once every 10 seconds. So the time and
// distance on the Finish row move in 10-second steps; a change of state (started, finished, a new route)
// shows at once.
//
// Both classes are in this one file on purpose: the scene delegate is only ever looked up by name (Info.plist),
// and keeping it next to the plugin keeps the linker from dropping it.

final class CarPlayHub {
    static let shared = CarPlayHub()

    weak var plugin: CarPlayPlugin?
    weak var scene: CarPlaySceneDelegate?
    private(set) var state: [String: Any] = [:]
    private var pending: [(String, [String: Any])] = []

    var connected: Bool { scene != nil }

    // A tap in the car. If the plugin is loaded, Capacitor keeps the event until the page listens
    // (retainUntilConsumed); if not (no web view yet), keep it here and hand it over when it loads.
    func send(_ event: String, _ data: [String: Any] = [:]) {
        if let p = plugin { p.notifyListeners(event, data: data, retainUntilConsumed: true) }
        else { pending.append((event, data)) }
    }

    func attach(_ p: CarPlayPlugin) {
        plugin = p
        let q = pending; pending = []
        for (e, d) in q { p.notifyListeners(e, data: d, retainUntilConsumed: true) }
    }

    func setState(_ s: [String: Any]) {
        state = s
        DispatchQueue.main.async { self.scene?.refresh() }
    }
}

@objc(CarPlayPlugin)
public class CarPlayPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "CarPlayPlugin"
    public let jsName = "CarPlay"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise)
    ]

    override public func load() {
        DispatchQueue.main.async { CarPlayHub.shared.attach(self) }
    }

    // What the car screen shows. Keys (all optional):
    //   ready: Bool            the page is running (until it says so, Start asks to open the app once)
    //   recording: Bool        a drive is being recorded
    //   time, dist: String     "12:34", "8.2 mi" (already in the driver's units)
    //   source, vehicle: String
    //   following: String      title of the route being followed, or absent
    //   followingId: String
    //   routes: [{id, title, detail}]   routes the driver can follow, newest first
    //   notice: String, noticeId: String  shown once as an alert in the car (for example "Connect your RaceBox first")
    @objc func update(_ call: CAPPluginCall) {
        CarPlayHub.shared.setState(call.options as? [String: Any] ?? [:])
        call.resolve()
    }

    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(["connected": CarPlayHub.shared.connected]) }
    }
}

@objc(DDCarPlaySceneDelegate)
public class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var ic: CPInterfaceController?
    private var root: CPListTemplate?
    private var routesList: CPListTemplate?
    private var lastShape = ""
    private var lastDraw = Date.distantPast
    private var shownNotice = ""
    private var timer: Timer?

    private var hub: CarPlayHub { CarPlayHub.shared }
    private func str(_ k: String) -> String? { (hub.state[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private func flag(_ k: String) -> Bool { hub.state[k] as? Bool ?? false }
    private var routes: [[String: Any]] { hub.state["routes"] as? [[String: Any]] ?? [] }

    public func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                         didConnect interfaceController: CPInterfaceController) {
        ic = interfaceController
        hub.scene = self
        let t = CPListTemplate(title: "Dragon Drive", sections: mainSections())
        root = t
        interfaceController.setRootTemplate(t, animated: false, completion: nil)
        lastShape = shape(); lastDraw = Date()
        // Picks up the 10-second refresh of time and distance even if the page sends nothing new.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        hub.send("connected")
    }

    public func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                         didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        timer?.invalidate(); timer = nil
        ic = nil; root = nil; routesList = nil
        if hub.scene === self { hub.scene = nil }
        hub.send("disconnected")
    }

    // What changes the layout or the meaning of a row: shown at once. Everything else (time, distance)
    // waits for the 10-second step.
    private func shape() -> String {
        let ids = routes.compactMap { $0["id"] as? String }.joined(separator: ",")
        return "\(flag("ready"))|\(flag("recording"))|\(str("followingId") ?? "")|\(ids)"
    }

    func refresh() {
        guard let root = root else { return }
        let s = shape()
        if s != lastShape || Date().timeIntervalSince(lastDraw) >= 9.5 {
            lastShape = s; lastDraw = Date()
            root.updateSections(mainSections())
            routesList?.updateSections(routeSections())
        }
        if let n = str("notice"), let id = str("noticeId"), id != shownNotice {
            shownNotice = id
            alert(n, [CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.dismissAlert() }])
        }
    }

    private func mainSections() -> [CPListSection] {
        let drive: CPListItem
        if !flag("ready") {
            drive = CPListItem(text: "Start drive", detailText: "Open Dragon Drive on your iPhone once first",
                               image: UIImage(systemName: "iphone"))
            drive.handler = { [weak self] _, done in
                self?.alert("Open Dragon Drive on your iPhone once, then you can start and finish drives from here.",
                            [CPAlertAction(title: "OK", style: .cancel) { _ in self?.dismissAlert() }])
                done()
            }
        } else if flag("recording") {
            let detail = [str("time"), str("dist")].compactMap { $0 }.joined(separator: " · ")
            drive = CPListItem(text: "Finish drive", detailText: detail.isEmpty ? "Recording" : "Recording · " + detail,
                               image: UIImage(systemName: "stop.circle.fill"))
            drive.handler = { [weak self] _, done in self?.confirmFinish(); done() }
        } else {
            let detail = [str("source"), str("vehicle")].compactMap { $0 }.joined(separator: " · ")
            drive = CPListItem(text: "Start drive", detailText: detail.isEmpty ? nil : detail,
                               image: UIImage(systemName: "record.circle"))
            drive.handler = { [weak self] _, done in self?.hub.send("start"); done() }
        }

        let follow = CPListItem(text: "Follow a route",
                                detailText: str("following").map { "Following " + $0 } ?? (routes.isEmpty ? "No planned routes yet" : "\(routes.count) planned"),
                                image: UIImage(systemName: "point.topleft.down.curvedto.point.bottomright.up"))
        follow.accessoryType = .disclosureIndicator
        follow.handler = { [weak self] _, done in self?.openRoutes(); done() }

        return [CPListSection(items: [drive, follow])]
    }

    private func routeSections() -> [CPListSection] {
        var items: [CPListItem] = []
        let cur = str("followingId")
        if let f = str("following") {
            let stop = CPListItem(text: "Stop following", detailText: f, image: UIImage(systemName: "xmark.circle"))
            stop.handler = { [weak self] _, done in self?.hub.send("unfollow"); self?.ic?.popTemplate(animated: true, completion: nil); done() }
            items.append(stop)
        }
        for r in routes.prefix(CPListTemplate.maximumItemCount - items.count) {
            guard let id = r["id"] as? String else { continue }
            let it = CPListItem(text: r["title"] as? String ?? "Route", detailText: r["detail"] as? String,
                                image: UIImage(systemName: id == cur ? "checkmark.circle.fill" : "map"))
            it.handler = { [weak self] _, done in
                self?.hub.send("follow", ["id": id])
                self?.ic?.popTemplate(animated: true, completion: nil)
                done()
            }
            items.append(it)
        }
        return [CPListSection(items: items)]
    }

    private func openRoutes() {
        let t = CPListTemplate(title: "Follow a route", sections: routeSections())
        t.emptyViewTitleVariants = ["No planned routes"]
        t.emptyViewSubtitleVariants = ["Plan one on the Routes tab on your iPhone."]
        routesList = t
        ic?.pushTemplate(t, animated: true, completion: nil)
    }

    // On the phone a drive finishes by holding the button, so a stray touch can't end it; here it's a confirmation.
    private func confirmFinish() {
        alert("Finish this drive?", [
            CPAlertAction(title: "Finish", style: .destructive) { [weak self] _ in self?.hub.send("finish"); self?.dismissAlert() },
            CPAlertAction(title: "Keep recording", style: .cancel) { [weak self] _ in self?.dismissAlert() }
        ])
    }

    private func alert(_ text: String, _ actions: [CPAlertAction]) {
        guard let ic = ic else { return }
        let show = { ic.presentTemplate(CPAlertTemplate(titleVariants: [text], actions: actions), animated: true, completion: nil) }
        if ic.presentedTemplate != nil { ic.dismissTemplate(animated: false) { _, _ in show() } } else { show() }
    }

    private func dismissAlert() { ic?.dismissTemplate(animated: true, completion: nil) }
}
