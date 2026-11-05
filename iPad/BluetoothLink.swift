// The iPad end of the Bluetooth link: finds Macs advertising the iPad Mouse service, connects to the
// chosen one, writes packets to it and hands back the Mac's replies.
// Bluetooth exchanges data on a steady schedule of its own, so it has none of the half-second stalls
// Wi-Fi gets while peer-to-peer Wi-Fi is in use; the price is fewer, slightly later updates than USB.

import CoreBluetooth
import Foundation
import QuartzCore

final class BluetoothLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onStatus: ((String) -> Void)?
    /// A packet from the Mac.
    var onData: ((Data) -> Void)?
    /// Names of the Macs seen over Bluetooth.
    var onMacsChanged: (([String]) -> Void)?
    /// The packets that introduce this iPad (name, then hello with its token); sent on connect and every 2 s.
    var hello: (() -> [Data])?
    /// The Mac the user wants. With none set, a lone Mac is used.
    var wantedMac: String? { didSet { if wantedMac != oldValue { reconsider() } } }
    /// True once packets can be written. Read from other threads as a plain flag.
    private(set) var ready = false

    private let queue: DispatchQueue
    private var central: CBCentralManager?
    private var found: [UUID: (peripheral: CBPeripheral, name: String)] = [:]
    private var peripheral: CBPeripheral?
    private var connectedName = "the Mac"
    private var toMac: CBCharacteristic?
    private var outbox: [Data] = []
    private var helloTimer: DispatchSourceTimer?

    private let serviceID = CBUUID(string: BluetoothLinkID.service)
    private let fromIPadID = CBUUID(string: BluetoothLinkID.fromIPad)
    private let toIPadID = CBUUID(string: BluetoothLinkID.toIPad)

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Call on the link queue. The first call makes iPadOS ask for Bluetooth permission.
    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
        } else {
            scan()
        }
    }

    /// Call on the link queue.
    func stop() {
        helloTimer?.cancel()
        helloTimer = nil
        ready = false
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        central = nil
        peripheral = nil
        toMac = nil
        outbox.removeAll()
        heldMove = nil
        found.removeAll()
        onMacsChanged?([])
    }

    /// Safe from any thread.
    func send(_ data: Data) {
        queue.async {
            guard self.ready else { return }
            self.enqueue(data)
            self.flush()
        }
    }

    // MARK: Sending

    /// The newest pointer move, held back until the next send slot.
    private var heldMove: Data?
    private var lastMoveSent: TimeInterval = 0
    private var moveSendScheduled = false
    /// Bluetooth carries data once per exchange (every 30 ms here) and CoreBluetooth queues whatever it is
    /// handed in the meantime. Moves written as fast as the finger makes them (120 a second) pile up in that
    /// queue, and the pointer then keeps travelling after the finger has stopped. So moves go out at most
    /// once per slot, each one carrying everything since the last, and the queue never holds old motion.
    private let moveSlot: TimeInterval = 0.015

    private static func isMove(_ data: Data) -> Bool {
        data.count == Packet.byteCount
            && (data.first == PacketKind.moveAbsolute.rawValue || data.first == PacketKind.moveRelative.rawValue)
    }

    /// Two moves become one: the later absolute position, or the sum of two relative moves in one stroke.
    private static func merged(_ earlier: Data, _ later: Data) -> Data? {
        guard isMove(earlier), isMove(later), let a = Packet(data: earlier), let b = Packet(data: later),
              a.kind == b.kind else { return nil }
        if a.kind == .moveAbsolute { return later }
        guard a.button == b.button else { return nil }
        var sum = b
        sum.dx += a.dx
        sum.dy += a.dy
        sum.y = max(a.y, b.y)
        return sum.encoded()
    }

    private func append(_ data: Data) {
        if let last = outbox.last, let both = Self.merged(last, data) {
            outbox[outbox.count - 1] = both            // still waiting behind a full queue: fold it in
            return
        }
        outbox.append(data)
        if outbox.count > 200 { outbox.removeFirst(outbox.count - 200) }
    }

    private func releaseHeldMove() {
        guard let move = heldMove else { return }
        heldMove = nil
        lastMoveSent = CACurrentMediaTime()
        append(move)
    }

    private func enqueue(_ data: Data) {
        guard Self.isMove(data) else {
            releaseHeldMove()                          // keep the order: the move first, then the click
            append(data)
            return
        }
        if let held = heldMove {
            if let both = Self.merged(held, data) {
                heldMove = both
            } else {
                releaseHeldMove()
                heldMove = data
            }
        } else {
            heldMove = data
        }
        let wait = moveSlot - (CACurrentMediaTime() - lastMoveSent)
        if wait <= 0 {
            releaseHeldMove()                          // nothing sent lately: go at once
        } else if !moveSendScheduled {
            moveSendScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.moveSendScheduled = false
                self.releaseHeldMove()
                self.flush()
            }
        }
    }

    private func flush() {
        guard let peripheral, let toMac else { return }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        while !outbox.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(outbox.removeFirst().prefix(limit), for: toMac, type: .withoutResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush()
    }

    // MARK: Finding and connecting

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scan()
        case .unauthorized:
            onStatus?("Bluetooth is not allowed for iPad Mouse. Turn it on in Settings › Apps › iPad Mouse.")
        case .poweredOff:
            dropped()
            onStatus?("Bluetooth is switched off on this iPad")
        case .unsupported:
            onStatus?("This iPad has no Bluetooth LE")
        default:
            break
        }
    }

    private func scan() {
        guard let central, central.state == .poweredOn, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [serviceID])
        onStatus?("Looking for the Mac over Bluetooth…")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Mac"
        found[peripheral.identifier] = (peripheral, name)
        onMacsChanged?(found.values.map(\.name).sorted())
        reconsider()
    }

    /// The advertised name is cut short to fit the advertisement, so one name may be the start of the other.
    static func sameMac(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    private func reconsider() {
        guard let central, central.state == .poweredOn, peripheral == nil, !found.isEmpty else { return }
        var pick = wantedMac.flatMap { wanted in found.values.first { Self.sameMac($0.name, wanted) } }
        if pick == nil, found.count == 1 { pick = found.values.first }
        guard let pick else {
            onStatus?("\(found.count) Macs found over Bluetooth. Tap “Macs” to choose one.")
            return
        }
        peripheral = pick.peripheral
        connectedName = pick.name
        pick.peripheral.delegate = self
        central.connect(pick.peripheral)
        onStatus?("Connecting to \(pick.name) over Bluetooth…")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        central.stopScan()
        peripheral.discoverServices([serviceID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([fromIPadID, toIPadID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let all = service.characteristics ?? []
        guard let write = all.first(where: { $0.uuid == fromIPadID }),
              let notify = all.first(where: { $0.uuid == toIPadID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        toMac = write
        peripheral.setNotifyValue(true, for: notify)       // the Mac can only answer once we are listening
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.isNotifying, toMac != nil else { return }
        ready = true
        onStatus?("Bluetooth link up, waiting for \(connectedName) to reply…")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.ready else { return }
            for packet in self.hello?() ?? [] { self.enqueue(packet) }
            self.flush()
        }
        timer.resume()
        helloTimer?.cancel()
        helloTimer = timer
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let value = characteristic.value { onData?(value) }
    }

    /// The Mac app restarted and published its service afresh: start over.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        central?.cancelPeripheralConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dropped()
        retrySoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dropped()
        onStatus?("Bluetooth link to \(connectedName) dropped, reconnecting…")
        retrySoon()
    }

    private func dropped() {
        helloTimer?.cancel()
        helloTimer = nil
        ready = false
        peripheral = nil
        toMac = nil
        outbox.removeAll()
        heldMove = nil
    }

    private func retrySoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.central != nil, self.peripheral == nil else { return }
            self.scan()
            self.reconsider()
        }
    }
}
