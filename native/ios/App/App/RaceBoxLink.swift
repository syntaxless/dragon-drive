import Foundation
import UIKit
import CoreBluetooth

// The RaceBox connection, in native code, so a RaceBox drive can start, record and finish with the phone locked.
//
// Why it is native: the web app's JavaScript is paused whenever the app is not on screen, and with Siri or the car
// screen it is often never on screen. CoreBluetooth in the app itself keeps working off screen thanks to the
// "bluetooth-central" background mode: iOS wakes the app for every notification the RaceBox sends.
//
// - The RaceBox is the one the page last connected (bleMem "racebox" in app.html, sent here with config). A
//   remembered device is reconnected by its id with retrievePeripherals: no scan, which iOS doesn't allow off screen
//   without a service filter anyway, and no picker. A connect request never times out on iOS, so if the RaceBox is
//   off or out of range the request waits and iOS connects (and wakes the app) as soon as it shows up.
// - While a drive is recording, a dropped link is asked for again at once, the same way.
// - The central has a restore identifier, so if iOS ends the app in the background during a RaceBox drive (to free
//   memory), it relaunches it when the RaceBox sends data, and DriveRecorder carries on the same drive.
// - The page holds the link too while the app is on screen (to show the device status before a drive); that hold
//   lapses in the background so a RaceBox left on doesn't keep the app awake when no drive is recording.
// - Messages are the RaceBox "Data Message" (UBX frame, class 0xFF id 0x01, 80-byte payload), parsed the same way
//   as makeUbxParser() in app.html.

final class RaceBoxLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = RaceBoxLink()
    // userInfo: status() of the link. Posted on a state change and at most once a second otherwise.
    static let changed = Notification.Name("DDRaceBoxChanged")

    static let nus = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    enum Power { case unknown, on, off, unauthorized, unsupported }

    struct Device { var id: UUID; var name: String }

    // One reading from the RaceBox (only when it has a valid 2D or 3D fix).
    struct Reading {
        var t: Double, lat: Double, lon: Double, alt: Double, acc: Double, v: Double, hdg: Double, gx: Double, gy: Double
    }

    var onReading: ((Reading) -> Void)?
    // Who wants the link up: a recording drive, and the page while it is on screen.
    var driveHold = false { didSet { if driveHold != oldValue { apply() } } }
    var pageHold = false { didSet { if pageHold != oldValue { apply() } } }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private(set) var state = "idle"       // idle, waiting (asked to connect), connected, data, off, unauthorized
    private(set) var sats: Int?
    private(set) var battery: Int?
    private(set) var hasFix = false
    private(set) var lastData: Date?
    private var hz = 0
    private var hzCount = 0
    private var hzStart = Date()
    private var lastPost = Date.distantPast
    private var buf = [UInt8]()
    private var restored: [CBPeripheral] = []
    private var readyWaiters: [(Power) -> Void] = []
    private var observing = false

    private let memKey = "dd.racebox.device"
    private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    // MARK: the remembered device

    var remembered: Device? {
        guard let d = UserDefaults.standard.dictionary(forKey: memKey), let s = d["id"] as? String, let id = UUID(uuidString: s) else { return nil }
        return Device(id: id, name: d["name"] as? String ?? "")
    }

    // The page's choice (its device picker, or bleMem on launch). A different device drops the old link.
    func remember(id: String, name: String) {
        guard let u = UUID(uuidString: id) else { return }
        let old = remembered
        UserDefaults.standard.set(["id": u.uuidString, "name": name], forKey: memKey)
        if let o = old, o.id != u, let p = peripheral {
            central?.cancelPeripheralConnection(p)
            peripheral = nil
            resetData()
        }
        apply()
    }

    var name: String { let n = remembered?.name ?? ""; return n.isEmpty ? "RaceBox" : n }

    // MARK: Bluetooth on or off

    var power: Power {
        guard let c = central else { return authorizationDenied ? .unauthorized : .unknown }
        switch c.state {
        case .poweredOn: return .on
        case .poweredOff: return .off
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        default: return .unknown
        }
    }

    private var authorizationDenied: Bool {
        if #available(iOS 13.1, *) { return CBManager.authorization == .denied || CBManager.authorization == .restricted }
        return false
    }

    // Has the user ever allowed Bluetooth for the app (the page's first connect asks)? Off screen iOS can't ask.
    var authorized: Bool {
        if #available(iOS 13.1, *) { return CBManager.authorization == .allowedAlways }
        return true
    }

    // Creates the central (once) and answers when its state is known, or after `timeout` seconds.
    func ready(timeout: Double = 3, _ done: @escaping (Power) -> Void) {
        setUp()
        if power != .unknown { done(power); return }
        readyWaiters.append(done)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.answerReady() }
    }

    @MainActor
    func whenReady(timeout: Double = 3) async -> Power {
        await withCheckedContinuation { c in ready(timeout: timeout) { c.resume(returning: $0) } }
    }

    private func answerReady() {
        let w = readyWaiters; readyWaiters = []
        for f in w { f(power) }
    }

    // Called at launch when iOS relaunched the app for Bluetooth (state restoration): the central must exist at once.
    func setUp() {
        if central != nil { return }
        if !observing {
            observing = true
            let nc = NotificationCenter.default
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.apply() }
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.apply() }
        }
        // Main queue: the readings are small and few (25 a second at most), and the recorder works on the main thread.
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false,
            CBCentralManagerOptionRestoreIdentifierKey: "dd.racebox"
        ])
    }

    // MARK: connecting

    private var wanted: Bool { driveHold || (pageHold && UIApplication.shared.applicationState != .background) }

    private func apply() {
        if wanted { setUp(); connect() } else { drop() }
    }

    private func connect() {
        guard let c = central, c.state == .poweredOn, let dev = remembered else { publish(force: true); return }
        if let p = peripheral, p.identifier == dev.id {
            if p.state == .connected { if state == "idle" || state == "waiting" { setState("connected"); discover(p) } ; return }
            if p.state == .connecting { setState("waiting"); return }
        }
        let p = restored.first(where: { $0.identifier == dev.id }) ?? c.retrievePeripherals(withIdentifiers: [dev.id]).first
        restored.removeAll()
        guard let per = p else { setState("idle"); return }
        peripheral = per
        per.delegate = self
        if per.state == .connected { setState("connected"); discover(per); return }
        setState("waiting")
        c.connect(per, options: nil)
    }

    private func drop() {
        if let p = peripheral, let c = central, p.state != .disconnected { c.cancelPeripheralConnection(p) }
        // A link iOS kept from before a relaunch that no drive needs any more.
        if let c = central { for p in restored where p.state != .disconnected { c.cancelPeripheralConnection(p) } }
        restored.removeAll()
        resetData()
        if state != "off" && state != "unauthorized" { setState("idle") }
    }

    private func resetData() {
        buf.removeAll(); hasFix = false; hz = 0; hzCount = 0; lastData = nil
    }

    private func discover(_ p: CBPeripheral) {
        p.discoverServices([RaceBoxLink.nus])
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: if state == "off" || state == "unauthorized" { state = "idle" }; apply()
        case .poweredOff: resetData(); setState("off")
        case .unauthorized: resetData(); setState("unauthorized")
        default: break
        }
        if c.state != .unknown && c.state != .resetting { answerReady() }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        for p in restored { p.delegate = self }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == remembered?.id else { c.cancelPeripheralConnection(p); return }
        if !wanted { c.cancelPeripheralConnection(p); return }
        setState("connected")
        discover(p)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if wanted && p.identifier == remembered?.id { setState("waiting"); c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        resetData()
        // Ask again straight away: iOS reconnects whenever the RaceBox is back in range, and wakes the app for it.
        if wanted && c.state == .poweredOn { setState("waiting"); c.connect(p, options: nil) } else { setState("idle") }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == RaceBoxLink.nus { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let d = ch.value, !d.isEmpty else { return }
        buf.append(contentsOf: d)
        parse()
    }

    // MARK: the RaceBox Data Message

    private func parse() {
        var i = 0
        while buf.count - i >= 8 {
            if buf[i] != 0xB5 || buf[i + 1] != 0x62 { i += 1; continue }
            let len = Int(buf[i + 4]) | (Int(buf[i + 5]) << 8)
            let total = 8 + len
            if buf.count - i < total { break }
            var a: UInt8 = 0, b: UInt8 = 0
            for k in (i + 2)..<(i + 6 + len) { a = a &+ buf[k]; b = b &+ a }
            if a == buf[i + 6 + len] && b == buf[i + 7 + len] && buf[i + 2] == 0xFF && buf[i + 3] == 0x01 && len == 80 {
                message(Array(buf[(i + 6)..<(i + 86)]))
            }
            i += total
        }
        if i > 0 { buf.removeFirst(min(i, buf.count)) }
        if buf.count > 4096 { buf.removeAll() }   // never a whole message: junk
    }

    private func message(_ m: [UInt8]) {
        func u8(_ o: Int) -> Int { Int(m[o]) }
        func u16(_ o: Int) -> Int { Int(m[o]) | Int(m[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(m[o]) | UInt32(m[o + 1]) << 8 | UInt32(m[o + 2]) << 16 | UInt32(m[o + 3]) << 24 }
        func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: UInt16(m[o]) | UInt16(m[o + 1]) << 8) }

        let fix = u8(20), valid = u8(21) & 1
        sats = u8(23)
        battery = u8(67) & 0x7F
        lastData = Date()
        hzCount += 1
        let el = Date().timeIntervalSince(hzStart)
        if el >= 1 { hz = Int((Double(hzCount) / el).rounded()); hzCount = 0; hzStart = Date() }
        if fix >= 2 && valid == 1 {
            var dc = DateComponents()
            dc.year = u16(4); dc.month = u8(6); dc.day = u8(7); dc.hour = u8(8); dc.minute = u8(9); dc.second = u8(10)
            if let date = utc.date(from: dc) {
                let t = (date.timeIntervalSince1970 * 1000).rounded() + (Double(i32(16)) / 1e6).rounded()
                let r = Reading(t: t, lat: Double(i32(28)) / 1e7, lon: Double(i32(24)) / 1e7, alt: Double(i32(36)) / 1000,
                                acc: Double(u32(40)) / 1000, v: max(0, Double(i32(48)) / 1000), hdg: Double(i32(52)) / 1e5,
                                gx: Double(i16(68)) / 1000, gy: Double(i16(70)) / 1000)
                let first = !hasFix
                hasFix = true
                if state != "data" { setState("data") } else if first { publish(force: true) }
                onReading?(r)
            }
        } else {
            let had = hasFix
            hasFix = false
            if state != "connected" { setState("connected") } else if had { publish(force: true) }
        }
        publish()
    }

    // MARK: status for the page and the recorder

    private func setState(_ s: String) {
        state = s
        publish(force: true)
    }

    func status() -> [String: Any] {
        var d: [String: Any] = ["state": state, "name": name, "fix": hasFix, "hz": hz,
                                "remembered": remembered != nil, "authorized": authorized]
        if let r = remembered { d["id"] = r.id.uuidString }
        if let s = sats { d["sats"] = s }
        if let b = battery { d["battery"] = b }
        if let l = lastData { d["lastData"] = (l.timeIntervalSince1970 * 1000).rounded() }
        return d
    }

    var connected: Bool { state == "connected" || state == "data" }

    private func publish(force: Bool = false) {
        if !force && Date().timeIntervalSince(lastPost) < 1 { return }
        lastPost = Date()
        NotificationCenter.default.post(name: RaceBoxLink.changed, object: nil, userInfo: status())
    }
}
