import Foundation
import UIKit
import CoreBluetooth
import Capacitor

// GoPro control: paired GoPros start recording when a drive starts and stop when it ends, with the phone locked too.
//
// It uses GoPro's published Bluetooth API, Open GoPro (https://gopro.github.io/OpenGoPro), which HERO9 Black (firmware
// 1.70 or later), HERO10, HERO11, HERO11 Mini, HERO12, HERO13, MAX 2 and the MISSION and LIT cameras support. Older
// GoPros don't have it. Only Bluetooth is used, never the camera's Wi-Fi, so the phone stays on its own network and the
// video stays on the camera's card: the existing GoPro import links it to the drive afterwards.
//
// Why it is native: a drive Siri or the car screen starts with the phone locked never runs the page's JavaScript, so
// the drive recorder (DriveRecorder.swift) calls drive(on:) here whenever a drive starts or ends, whoever started it.
// iOS lets the app use Bluetooth in the background ("bluetooth-central" in Info.plist) and the drive's location
// updates keep the app running, so the keep-alive and status checks below carry on with the screen off.
//
// - Pairing (once per camera, on screen): the camera has to be in its pairing mode. Its characteristics are encrypted,
//   so subscribing to them makes iOS show its own Bluetooth pairing request, and iOS keeps the bond after that.
// - A drive starts: every paired camera with "Record with drives" on is connected. A camera that is asleep but still
//   advertising (for 8 hours after it goes to sleep, per Open GoPro) wakes up when it is connected. iOS keeps a
//   connection attempt open with no time limit, so a camera that is off and turned on later in the drive connects then
//   and starts recording. Once it is not busy and not already encoding, Set Shutter on.
// - During the drive: Keep Alive and a status query every 3 s (battery, remaining video, encoding, overheating). A
//   camera that drops out (range, battery) is reconnected and, if it stopped, started again: that makes a new clip.
// - Paused from the car screen (CarPlay's GoPro row, or anything that posts "DDGoProCommand"): Set Shutter off but
//   stay connected for the rest of the drive (keep-alive and status go on), so resuming is one Set Shutter on and
//   a new clip. Every drive starts unpaused.
// - The drive ends: Set Shutter off, then Sleep if "Turn the GoPros off after a drive" is on, then disconnect. iOS gives
//   the app a background task for this, because location stops with the drive and the app may be suspended soon after.
//
// Messages follow the Open GoPro data protocol: TLV commands on GP-0072 (answers on GP-0073), settings on GP-0074
// (GP-0075), queries on GP-0076 (GP-0077), each with a 1-byte header (5-bit length; answers can be longer and split
// into continuation packets, see Assembler).

final class GoPros: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = GoPros()
    static let changed = Notification.Name("DDGoProChanged")

    private static func gp(_ s: String) -> CBUUID { CBUUID(string: "B5F9\(s)-AA8D-11E3-9046-0002A5D5C51B") }
    private static let service = CBUUID(string: "FEA6")
    private static let cmd = gp("0072"), cmdRsp = gp("0073")
    private static let set = gp("0074"), setRsp = gp("0075")
    private static let query = gp("0076"), queryRsp = gp("0077")
    private static let notifyChars = [cmdRsp, setRsp, queryRsp]

    // Open GoPro IDs used here.
    private enum Cmd { static let shutter: UInt8 = 0x01, sleep: UInt8 = 0x05, dateTime: UInt8 = 0x0D, localDateTime: UInt8 = 0x0F,
                       hwInfo: UInt8 = 0x3C, thirdParty: UInt8 = 0x50, getStatus: UInt8 = 0x13 }
    private enum Status { static let hot: UInt8 = 6, busy: UInt8 = 8, encoding: UInt8 = 10, videoLeft: UInt8 = 35, battery: UInt8 = 70 }
    private static let keepAlive: [UInt8] = [0x03, 0x5B, 0x01, 0x42]        // setting 91 (LED) = 66, the BLE keep-alive

    // What a camera is connected for.
    // pause: connected during a drive, not recording (paused from the car screen).
    enum Want: String { case none, pair, record, pause, stop, check, test }
    static let command = Notification.Name("DDGoProCommand")

    final class Cam {
        let id: UUID
        var p: CBPeripheral?
        var name: String
        var model = ""
        var firmware = ""
        var auto = true
        var saved = false
        var want: Want = .none
        var state = "idle"            // idle, connecting, connected, recording, stopping, error
        var note = ""
        var chars: [CBUUID: CBCharacteristic] = [:]
        var subscribed = Set<CBUUID>()
        var ready = false
        var asm: [CBUUID: Assembler] = [:]
        var queue: [CBUUID: [Data]] = [:]
        var inflight: [CBUUID: Date] = [:]
        var busy = true, encoding = false, hot = false, statusSeen = false
        var battery: Int?, videoLeft: Int?
        var shutterSent: Date?
        var stopSent = false, sleepSent = false
        var testUntil: Date?
        var sawRecording = false       // recorded during the current drive
        var deadline: Date?            // pairing gives up after this
        init(id: UUID, name: String) { self.id = id; self.name = name }
        var label: String { model.isEmpty ? name : (model.lowercased().hasPrefix("gopro") ? model : "GoPro " + model) }
    }

    // Reassembles one Open GoPro message from its packets.
    struct Assembler {
        var want = -1
        var data = Data()
        // Returns the whole message once it is complete.
        mutating func add(_ pkt: Data) -> Data? {
            guard let b0 = pkt.first else { return nil }
            let bytes = [UInt8](pkt)
            if b0 & 0x80 != 0 {
                if want < 0 { return nil }
                data.append(contentsOf: bytes.dropFirst())
            } else {
                switch (b0 >> 5) & 0x03 {
                case 0: want = Int(b0 & 0x1F); data = Data(bytes.dropFirst())
                case 1: guard bytes.count >= 2 else { return nil }
                        want = (Int(b0 & 0x1F) << 8) | Int(bytes[1]); data = Data(bytes.dropFirst(2))
                case 2: guard bytes.count >= 3 else { return nil }
                        want = (Int(bytes[1]) << 8) | Int(bytes[2]); data = Data(bytes.dropFirst(3))
                default: return nil
                }
            }
            if want >= 0 && data.count >= want {
                let out = data.prefix(want); want = -1; data = Data(); return Data(out)
            }
            return nil
        }
    }

    private var central: CBCentralManager?
    private var whenOn: [() -> Void] = []
    private var cams: [UUID: Cam] = [:]
    private var found: [UUID: (p: CBPeripheral, name: String, rssi: Int)] = [:]
    private var scanning = false
    private var scanTimer: Timer?
    private var tick: Timer?
    private var driveOn = false
    private var paused = false              // filming paused for the rest of this drive (car screen)
    private var driveWant: Want { paused ? .pause : .record }
    private var driveStart: Double = 0
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var booted = false
    private var pairNote = ""                // why the last pairing failed (that camera is not kept)

    private let savedKey = "dd.gopro.cams", sleepKey = "dd.gopro.sleepAfter", sessionsKey = "dd.gopro.sessions"
    var sleepAfter: Bool {
        get { UserDefaults.standard.bool(forKey: sleepKey) }
        set { UserDefaults.standard.set(newValue, forKey: sleepKey); publish() }
    }

    override init() {
        super.init()
        // The car screen (CarPlay plugin, a separate package that can't import this file) talks by name:
        // ["action": "film" | "pause" | "state"]. The answer is the usual DDGoProChanged state.
        NotificationCenter.default.addObserver(forName: GoPros.command, object: nil, queue: .main) { [weak self] n in
            switch n.userInfo?["action"] as? String {
            case "film": self?.setPaused(false)
            case "pause": self?.setPaused(true)
            default: self?.publish()
            }
        }
    }

    // MARK: launch

    // AppDelegate, on every launch. Bluetooth starts only when a camera has been paired, so nobody without a GoPro gets
    // a Bluetooth permission prompt from this.
    func boot() {
        if booted { return }
        booted = true
        for d in (UserDefaults.standard.array(forKey: savedKey) as? [[String: Any]]) ?? [] {
            guard let s = d["id"] as? String, let id = UUID(uuidString: s) else { continue }
            let c = Cam(id: id, name: d["name"] as? String ?? "GoPro")
            c.model = d["model"] as? String ?? ""
            c.firmware = d["firmware"] as? String ?? ""
            c.auto = d["auto"] as? Bool ?? true
            c.saved = true
            cams[id] = c
        }
        if !cams.isEmpty { ensureCentral() }
        publish()
    }

    private func ensureCentral() {
        if central == nil { central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
    }

    private func onPowered(_ f: @escaping () -> Void) {
        ensureCentral()
        if central?.state == .poweredOn { f() } else { whenOn.append(f) }
    }

    private func save() {
        let list = cams.values.filter { $0.saved }.sorted { $0.name < $1.name }.map {
            ["id": $0.id.uuidString, "name": $0.name, "model": $0.model, "firmware": $0.firmware, "auto": $0.auto] as [String: Any]
        }
        UserDefaults.standard.set(list, forKey: savedKey)
    }

    // MARK: the drive

    // From DriveRecorder whenever a drive starts or ends (its own, or a Bluetooth drive the page runs).
    func drive(on: Bool) {
        DispatchQueue.main.async { self.setDrive(on) }
    }

    private func setDrive(_ on: Bool) {
        if on == driveOn { return }
        driveOn = on
        paused = false
        if on {
            driveStart = (Date().timeIntervalSince1970 * 1000).rounded()
            for c in cams.values where c.saved && c.auto {
                c.sawRecording = false
                c.want = .record
                c.note = ""
                c.shutterSent = nil
                connect(c)
            }
        } else {
            let names = cams.values.filter { $0.sawRecording }.map { $0.label }
            if !names.isEmpty { logSession(names) }
            var any = false
            for c in cams.values where c.want == .record || c.want == .pause || c.want == .test {
                c.sawRecording = false
                c.want = .stop
                c.stopSent = false; c.sleepSent = false
                if c.ready { any = true; c.state = "stopping"; act(c) }
                else { drop(c, state: "idle") }
            }
            if any { holdBackground() }
        }
        publish()
    }

    // Stop or start filming for the rest of the drive, from the car screen. Only during a drive: outside one the
    // cameras are off and the next drive films as usual.
    func setPaused(_ p: Bool) {
        guard driveOn, p != paused else { publish(); return }
        paused = p
        for c in cams.values where c.saved && c.auto && (c.want == .record || c.want == .pause || c.want == .none) {
            c.want = driveWant
            c.note = ""
            c.shutterSent = nil; c.stopSent = false
            if c.ready { act(c) } else { connect(c) }
        }
        publish()
    }

    // The page asks which cameras filmed which drive (by time) to note it on the drive.
    private func logSession(_ names: [String]) {
        var list = (UserDefaults.standard.array(forKey: sessionsKey) as? [[String: Any]]) ?? []
        list.append(["start": driveStart, "end": (Date().timeIntervalSince1970 * 1000).rounded(), "cams": names])
        if list.count > 20 { list.removeFirst(list.count - 20) }
        UserDefaults.standard.set(list, forKey: sessionsKey)
    }

    func sessions() -> [[String: Any]] { (UserDefaults.standard.array(forKey: sessionsKey) as? [[String: Any]]) ?? [] }

    // Keeps the app awake long enough to stop the cameras after the drive's location updates end.
    private func holdBackground() {
        if bgTask != .invalid { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Stop GoPros") { [weak self] in self?.endBackground() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.endBackground() }
    }

    private func endBackground() {
        if bgTask == .invalid { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: from the page

    func scan() {
        onPowered { [weak self] in
            guard let self = self else { return }
            self.found.removeAll()
            self.pairNote = ""
            self.scanning = true
            self.central?.scanForPeripherals(withServices: [GoPros.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            self.scanTimer?.invalidate()
            self.scanTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in self?.stopScan() }
            self.publish()
        }
        if central?.state == .poweredOff || central?.state == .unauthorized { publish() }
    }

    func stopScan() {
        scanTimer?.invalidate(); scanTimer = nil
        if scanning { central?.stopScan() }
        scanning = false
        publish()
    }

    func pair(_ id: UUID) -> Bool {
        guard let f = found[id] else { return false }
        stopScan()
        pairNote = ""
        let c = cams[id] ?? Cam(id: id, name: f.name)
        c.p = f.p
        c.want = .pair
        c.note = ""
        c.deadline = Date().addingTimeInterval(45)
        cams[id] = c
        connect(c)
        return true
    }

    func check(_ id: UUID, test: Bool) {
        guard let c = cams[id], c.saved else { return }
        if driveOn && (c.want == .record || c.want == .pause) { return }
        c.note = ""
        c.want = test ? .test : .check
        c.testUntil = nil; c.shutterSent = nil; c.stopSent = false; c.sleepSent = false
        c.deadline = Date().addingTimeInterval(30)
        if c.ready { act(c) } else { connect(c) }
    }

    func setAuto(_ id: UUID, _ on: Bool) {
        guard let c = cams[id] else { return }
        c.auto = on
        save()
        // Turned on mid-drive: join the drive now.
        if on && driveOn && c.want == .none { c.want = driveWant; connect(c) }
        publish()
    }

    func forget(_ id: UUID) {
        guard let c = cams[id] else { return }
        if let p = c.p { central?.cancelPeripheralConnection(p) }
        cams[id] = nil
        save()
        publish()
    }

    // MARK: connecting

    private func connect(_ c: Cam) {
        onPowered { [weak self] in
            guard let self = self, let central = self.central else { return }
            if c.p == nil { c.p = central.retrievePeripherals(withIdentifiers: [c.id]).first }
            guard let p = c.p else { c.state = "error"; c.note = "This iPhone doesn't know that GoPro any more. Forget it here and pair it again."; self.publish(); return }
            p.delegate = self
            if p.state == .connected && c.ready { self.act(c); return }
            c.state = "connecting"
            if p.state != .connecting && p.state != .connected { central.connect(p, options: nil) }
            self.startTick()
            self.publish()
        }
    }

    // Disconnect and forget the session state (the bond stays with iOS).
    private func drop(_ c: Cam, state: String) {
        c.want = .none
        c.ready = false
        c.state = state
        c.deadline = nil
        if let p = c.p, p.state != .disconnected { central?.cancelPeripheralConnection(p) }
        publish()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            let w = whenOn; whenOn = []
            for f in w { f() }
        } else if central.state == .poweredOff || central.state == .unauthorized {
            for c in cams.values where c.want != .none {
                c.state = "error"
                c.note = central.state == .poweredOff ? "Bluetooth is off on this iPhone." : "Bluetooth is off for Dragon Drive in Settings."
            }
        }
        publish()
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "GoPro"
        found[p.identifier] = (p, name, RSSI.intValue)
        publish()
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard let c = cams[p.identifier] else { central.cancelPeripheralConnection(p); return }
        c.state = "connected"
        c.chars = [:]; c.subscribed = []; c.ready = false; c.asm = [:]; c.queue = [:]; c.inflight = [:]
        c.statusSeen = false; c.busy = true
        p.delegate = self
        p.discoverServices([GoPros.service])
        publish()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard let c = cams[p.identifier] else { return }
        lost(c, error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard let c = cams[p.identifier] else { return }
        lost(c, error)
    }

    private func lost(_ c: Cam, _ error: Error?) {
        c.ready = false
        if let e = error as NSError?, e.domain == CBErrorDomain,
           e.code == CBError.peerRemovedPairingInformation.rawValue || e.code == CBError.encryptionTimedOut.rawValue {
            c.state = "error"
            c.note = "The pairing is out of date. In iPhone Settings, Bluetooth, tap (i) next to the GoPro and Forget This Device, then pair it again here."
            if c.want != .record && c.want != .pause { c.want = .none }
            publish()
            return
        }
        switch c.want {
        case .record, .pause:
            // Out of range or battery: keep trying for the rest of the drive.
            c.state = "connecting"; c.note = "Lost the camera. Reconnecting…"
            if let p = c.p { central?.connect(p, options: nil) }
        case .pair:
            if c.note.isEmpty { c.note = "Couldn't pair. Put the GoPro in pairing mode and try again." }
            c.state = "error"; c.want = .none
            if !c.saved { pairNote = c.note; cams[c.id] = nil }
        default:
            c.want = .none
            if c.state != "error" { c.state = "idle" }
        }
        publish()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == GoPros.service }) else { return }
        p.discoverCharacteristics([GoPros.cmd, GoPros.cmdRsp, GoPros.set, GoPros.setRsp, GoPros.query, GoPros.queryRsp], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let c = cams[p.identifier] else { return }
        for ch in s.characteristics ?? [] { c.chars[ch.uuid] = ch }
        // Subscribing to an encrypted characteristic is what makes iOS pair, the first time.
        for u in GoPros.notifyChars { if let ch = c.chars[u] { p.setNotifyValue(true, for: ch) } }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard let c = cams[p.identifier] else { return }
        if let e = error as NSError? {
            c.state = "error"
            if e.domain == CBATTErrorDomain && (e.code == CBATTError.insufficientEncryption.rawValue || e.code == CBATTError.insufficientAuthentication.rawValue) {
                c.note = c.want == .pair ? "The GoPro didn't accept the pairing. Put it in pairing mode, tap Pair again and accept the iPhone's request."
                                         : "The GoPro has forgotten this iPhone. Forget it here and pair it again."
            } else {
                c.note = "Couldn't talk to the GoPro (\(e.localizedDescription))."
            }
            if c.want == .pair && !c.saved { pairNote = c.note; cams[c.id] = nil }
            c.want = .none
            central?.cancelPeripheralConnection(p)
            publish()
            return
        }
        if ch.isNotifying { c.subscribed.insert(ch.uuid) }
        if !c.ready && GoPros.notifyChars.allSatisfy({ c.subscribed.contains($0) }) {
            c.ready = true
            setup(c)
        }
    }

    // First messages on every connection: say we're a third-party client, set the camera's clock from the phone (so
    // clip times match the drive), ask what model it is, and read its status.
    private func setup(_ c: Cam) {
        send(c, GoPros.cmd, [0x01, Cmd.thirdParty])
        let now = Date(), cal = Calendar.current
        let k = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let y = UInt16(k.year ?? 2026)
        let dt: [UInt8] = [UInt8(y >> 8), UInt8(y & 0xFF), UInt8(k.month ?? 1), UInt8(k.day ?? 1), UInt8(k.hour ?? 0), UInt8(k.minute ?? 0), UInt8(k.second ?? 0)]
        let tz = Int16(TimeZone.current.secondsFromGMT(for: now) / 60), dst: UInt8 = TimeZone.current.isDaylightSavingTime(for: now) ? 1 : 0
        let u = UInt16(bitPattern: tz)
        // Set Local Date Time (time zone and DST) where the camera has it; Set Date Time first for older firmware.
        send(c, GoPros.cmd, [0x09, Cmd.dateTime, 0x07] + dt)
        send(c, GoPros.cmd, [0x0C, Cmd.localDateTime, 0x0A] + dt + [UInt8(u >> 8), UInt8(u & 0xFF), dst])
        send(c, GoPros.cmd, [0x01, Cmd.hwInfo])
        pollStatus(c)
        startTick()
        publish()
    }

    // MARK: messages

    private func send(_ c: Cam, _ u: CBUUID, _ bytes: [UInt8]) {
        c.queue[u, default: []].append(Data(bytes))
        pump(c, u)
    }

    // One message in flight per characteristic, like GoPro's own SDK: the next goes when the answer arrives (or 3 s pass).
    private func pump(_ c: Cam, _ u: CBUUID) {
        guard c.ready, c.inflight[u] == nil, var q = c.queue[u], !q.isEmpty, let p = c.p, let ch = c.chars[u] else { return }
        let d = q.removeFirst()
        c.queue[u] = q
        c.inflight[u] = Date()
        p.writeValue(d, for: ch, type: .withResponse)
    }

    private func responseChar(_ u: CBUUID) -> CBUUID? {
        switch u { case GoPros.cmdRsp: return GoPros.cmd; case GoPros.setRsp: return GoPros.set; case GoPros.queryRsp: return GoPros.query; default: return nil }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let c = cams[p.identifier], let v = ch.value, let req = responseChar(ch.uuid) else { return }
        var a = c.asm[ch.uuid] ?? Assembler()
        let msg = a.add(v)
        c.asm[ch.uuid] = a
        guard let m = msg, m.count >= 2 else { return }
        let b = [UInt8](m)
        c.inflight[req] = nil
        if ch.uuid == GoPros.cmdRsp { command(c, id: b[0], ok: b[1] == 0, rest: Array(b.dropFirst(2))) }
        else if ch.uuid == GoPros.queryRsp && (b[0] == Cmd.getStatus || b[0] == 0x93) && b[1] == 0 { statuses(c, Array(b.dropFirst(2))) }
        pump(c, req)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard let c = cams[p.identifier], error != nil else { return }
        // A failed write gets no answer: free the slot.
        c.inflight[ch.uuid] = nil
        pump(c, ch.uuid)
    }

    private func command(_ c: Cam, id: UInt8, ok: Bool, rest: [UInt8]) {
        switch id {
        case Cmd.hwInfo where ok:
            // length-value fields: model number, model name, (deprecated), firmware, serial, AP SSID, AP MAC
            var f: [[UInt8]] = [], i = 0
            while i < rest.count { let n = Int(rest[i]); i += 1; if i + n > rest.count { break }; f.append(Array(rest[i..<i + n])); i += n }
            if f.count > 1, let s = String(bytes: f[1], encoding: .utf8), !s.isEmpty { c.model = s }
            if f.count > 3, let s = String(bytes: f[3], encoding: .utf8) { c.firmware = s }
            if c.want == .pair {
                c.saved = true
                c.auto = true
                c.deadline = nil
                save()
                c.note = "Paired"
                // Paired mid-drive: join it.
                if driveOn { c.want = driveWant; act(c) } else { drop(c, state: "idle") }
            } else if c.saved { save() }
            publish()
        case Cmd.shutter:
            if !ok { c.shutterSent = nil }        // try again on the next status
        case Cmd.sleep:
            c.sleepSent = true
            finishStop(c)
        default: break
        }
    }

    private func pollStatus(_ c: Cam) {
        if c.queue[GoPros.query]?.isEmpty == false || c.inflight[GoPros.query] != nil { return }
        let ids = [Status.busy, Status.encoding, Status.battery, Status.videoLeft, Status.hot]
        send(c, GoPros.query, [UInt8(ids.count + 1), Cmd.getStatus] + ids)
    }

    private func statuses(_ c: Cam, _ b: [UInt8]) {
        var i = 0
        while i + 2 <= b.count {
            let id = b[i], n = Int(b[i + 1]); i += 2
            if i + n > b.count { break }
            var v = 0
            for x in b[i..<i + n] { v = (v << 8) | Int(x) }
            i += n
            switch id {
            case Status.busy: c.busy = v != 0
            case Status.encoding: c.encoding = v != 0
            case Status.battery: c.battery = v
            case Status.videoLeft: c.videoLeft = v
            case Status.hot: c.hot = v != 0
            default: break
            }
        }
        c.statusSeen = true
        act(c)
        publish()
    }

    // What to do next for this camera, given what it is connected for and its last status.
    private func act(_ c: Cam) {
        guard c.ready, c.statusSeen else { return }
        switch c.want {
        case .record, .test:
            if c.encoding {
                c.state = "recording"; c.note = ""; c.shutterSent = nil
                if c.want == .record { c.sawRecording = true }
                if c.want == .test {
                    if c.testUntil == nil { c.testUntil = Date().addingTimeInterval(5) }
                    else if Date() >= c.testUntil! { c.note = "Test recording worked."; c.want = .stop; c.stopSent = false; c.sleepSent = true; c.testUntil = nil; act(c) }
                }
                return
            }
            if c.want == .test && c.testUntil != nil { c.note = "Test recording worked."; drop(c, state: "idle"); return }
            c.state = "connected"
            if c.hot { c.note = "The GoPro is too hot to record." }
            else if let left = c.videoLeft, left == 0 { c.note = "The GoPro's card is full or missing." }
            // Wait until it isn't busy (Open GoPro's rule), and don't resend while one is pending.
            if !c.busy && (c.shutterSent == nil || Date().timeIntervalSince(c.shutterSent!) > 4) {
                c.shutterSent = Date()
                send(c, GoPros.cmd, [0x03, Cmd.shutter, 0x01, 0x01])
            }
        case .pause:
            // Paused from the car screen: shutter off, then stay connected for a quick resume.
            c.state = c.encoding ? "stopping" : "paused"
            // (shutterSent paces it like the start: resent after 4 s, or on the next status if the camera said no)
            if c.encoding && (c.shutterSent == nil || Date().timeIntervalSince(c.shutterSent!) > 4) {
                c.shutterSent = Date()
                send(c, GoPros.cmd, [0x03, Cmd.shutter, 0x01, 0x00])
            } else if !c.encoding { c.shutterSent = nil; c.note = "" }
        case .stop:
            c.state = "stopping"
            if c.encoding && !c.stopSent {
                c.stopSent = true
                send(c, GoPros.cmd, [0x03, Cmd.shutter, 0x01, 0x00])
                return
            }
            if c.encoding { return }      // wait for the stop to show in the status
            if sleepAfter && !c.sleepSent {
                c.sleepSent = true
                send(c, GoPros.cmd, [0x01, Cmd.sleep])
                // The camera may drop the link as it sleeps instead of answering.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finishStop(c) }
                return
            }
            finishStop(c)
        case .check:
            c.note = ""
            drop(c, state: "idle")
        case .pair, .none:
            break
        }
    }

    private func finishStop(_ c: Cam) {
        guard c.want == .stop else { return }
        drop(c, state: "idle")
        if !cams.values.contains(where: { $0.want == .stop }) { endBackground() }
    }

    // MARK: the 3 s tick: keep-alive, status, timeouts

    private func startTick() {
        if tick != nil { return }
        tick = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.onTick() }
    }

    private func onTick() {
        let now = Date()
        var busy = false
        for c in Array(cams.values) {
            if let d = c.deadline, now > d, c.want == .pair || c.want == .check || c.want == .test {
                if c.want == .pair { c.note = "Couldn't find or pair the GoPro. Check it's in pairing mode and next to the phone." }
                else { c.note = "The GoPro didn't answer. Check it's on, or asleep for less than 8 hours." }
                let unsaved = !c.saved
                drop(c, state: "error")
                if unsaved { pairNote = c.note; cams[c.id] = nil }
                continue
            }
            for (u, t) in c.inflight where now.timeIntervalSince(t) > 3 { c.inflight[u] = nil; pump(c, u) }
            if c.ready {
                busy = true
                send(c, GoPros.set, GoPros.keepAlive)
                pollStatus(c)
            } else if c.want != .none { busy = true }
        }
        if !busy && !scanning { tick?.invalidate(); tick = nil }
    }

    // MARK: state for the page

    func state() -> [String: Any] {
        let list = cams.values.filter { $0.saved }.sorted { $0.name < $1.name }.map { c -> [String: Any] in
            var d: [String: Any] = ["id": c.id.uuidString, "name": c.label, "auto": c.auto, "state": c.state, "note": c.note,
                                    "firmware": c.firmware]
            if let b = c.battery { d["battery"] = b }
            if let v = c.videoLeft { d["videoLeft"] = v }
            return d
        }
        let pairing = cams.values.filter { !$0.saved && $0.want == .pair }.map { $0.id.uuidString }
        let f = found.filter { cams[$0.key]?.saved != true }.sorted { $0.value.rssi > $1.value.rssi }
            .map { ["id": $0.key.uuidString, "name": $0.value.name, "rssi": $0.value.rssi] as [String: Any] }
        var bt = "unknown"
        if let s = central?.state {
            switch s {
            case .poweredOn: bt = "on"
            case .poweredOff: bt = "off"
            case .unauthorized: bt = "denied"
            case .unsupported: bt = "unsupported"
            default: bt = "unknown"
            }
        }
        return ["cams": list, "found": f, "scanning": scanning, "pairing": pairing, "sleepAfter": sleepAfter,
                "drive": driveOn, "paused": paused, "bluetooth": bt, "pairNote": pairNote]
    }

    private func publish() {
        let s = state()
        DispatchQueue.main.async { NotificationCenter.default.post(name: GoPros.changed, object: nil, userInfo: s) }
    }
}

// The page's side. Registered on the bridge by DDBridgeViewController (SceneDelegate.swift).
@objc(GoProPlugin)
public class GoProPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "GoProPlugin"
    public let jsName = "GoPro"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "state", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopScan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pair", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "check", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAuto", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSleepAfter", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "forget", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sessions", returnType: CAPPluginReturnPromise)
    ]
    private var g: GoPros { GoPros.shared }

    override public func load() {
        NotificationCenter.default.addObserver(forName: GoPros.changed, object: nil, queue: .main) { [weak self] n in
            var d: [String: Any] = [:]
            for (k, v) in n.userInfo ?? [:] { if let k = k as? String { d[k] = v } }
            self?.notifyListeners("state", data: d)
        }
    }

    private func uuid(_ call: CAPPluginCall) -> UUID? { UUID(uuidString: call.getString("id") ?? "") }

    @objc func state(_ call: CAPPluginCall) { DispatchQueue.main.async { call.resolve(self.g.state()) } }
    @objc func scan(_ call: CAPPluginCall) { DispatchQueue.main.async { self.g.scan(); call.resolve() } }
    @objc func stopScan(_ call: CAPPluginCall) { DispatchQueue.main.async { self.g.stopScan(); call.resolve() } }
    @objc func pair(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let id = self.uuid(call), self.g.pair(id) else { call.reject("not found"); return }
            call.resolve()
        }
    }
    @objc func check(_ call: CAPPluginCall) {
        DispatchQueue.main.async { if let id = self.uuid(call) { self.g.check(id, test: call.getBool("test") ?? false) }; call.resolve() }
    }
    @objc func setAuto(_ call: CAPPluginCall) {
        DispatchQueue.main.async { if let id = self.uuid(call) { self.g.setAuto(id, call.getBool("on") ?? true) }; call.resolve() }
    }
    @objc func setSleepAfter(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.g.sleepAfter = call.getBool("on") ?? false; call.resolve() }
    }
    @objc func forget(_ call: CAPPluginCall) {
        DispatchQueue.main.async { if let id = self.uuid(call) { self.g.forget(id) }; call.resolve() }
    }
    @objc func sessions(_ call: CAPPluginCall) { DispatchQueue.main.async { call.resolve(["sessions": self.g.sessions()]) } }
}
