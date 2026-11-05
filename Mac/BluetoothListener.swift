// The Mac end of the Bluetooth link. The Mac advertises a small service; the iPad connects, writes its
// packets to one characteristic and listens for the Mac's replies on another.
// Bluetooth keeps its own steady schedule (one exchange every 15 ms or so), so it has none of the
// half-second stalls Wi-Fi gets while peer-to-peer Wi-Fi (AWDL) is in use on the Mac.

import CoreBluetooth
import Foundation

final class BluetoothListener: NSObject, CBPeripheralManagerDelegate {
    /// A packet arrived from the iPad with this Bluetooth identifier.
    var onData: ((UUID, Data) -> Void)?
    /// That iPad disconnected.
    var onGone: ((UUID) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue: DispatchQueue
    private var manager: CBPeripheralManager?
    private var name = "Mac"
    private var toIPad: CBMutableCharacteristic?
    private var centrals: [UUID: CBCentral] = [:]
    /// Replies waiting because the transmit queue was full.
    private var pending: [(data: Data, id: UUID)] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Callbacks arrive on the queue given at init. The first call makes macOS ask for Bluetooth permission.
    func start(name: String) {
        self.name = name
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    func send(_ data: Data, to id: UUID) {
        guard let manager, let characteristic = toIPad, let central = centrals[id] else { return }
        if !pending.isEmpty || !manager.updateValue(data, for: characteristic, onSubscribedCentrals: [central]) {
            pending.append((data, id))
            if pending.count > 32 { pending.removeFirst(pending.count - 32) }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let characteristic = toIPad else { return }
        while let next = pending.first {
            guard let central = centrals[next.id] else { pending.removeFirst(); continue }
            guard peripheral.updateValue(next.data, for: characteristic, onSubscribedCentrals: [central]) else { return }
            pending.removeFirst()
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            let fromIPad = CBMutableCharacteristic(type: CBUUID(string: BluetoothLinkID.fromIPad),
                                                   properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
            let toIPad = CBMutableCharacteristic(type: CBUUID(string: BluetoothLinkID.toIPad),
                                                 properties: [.notify], value: nil, permissions: [.readable])
            let service = CBMutableService(type: CBUUID(string: BluetoothLinkID.service), primary: true)
            service.characteristics = [fromIPad, toIPad]
            self.toIPad = toIPad
            peripheral.removeAllServices()
            peripheral.add(service)
        case .unauthorized:
            onLog?("not allowed. Turn it on in System Settings > Privacy & Security > Bluetooth > iPad Mouse")
        case .poweredOff:
            onLog?("Bluetooth is switched off on this Mac")
        case .unsupported:
            onLog?("this Mac has no Bluetooth LE")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onLog?("could not publish the service: \(error.localizedDescription)")
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                                     CBAdvertisementDataLocalNameKey: name])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        onLog?(error.map { "could not advertise: \($0.localizedDescription)" } ?? "advertising as \"\(name)\"")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        centrals[central.identifier] = central
        // Ask for the shortest interval between exchanges; the default is tuned for battery life, not pointers.
        peripheral.setDesiredConnectionLatency(.low, for: central)
        onLog?("iPad connected (up to \(central.maximumUpdateValueLength) bytes per packet)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        centrals[central.identifier] = nil
        pending.removeAll { $0.id == central.identifier }
        onLog?("iPad disconnected")
        onGone?(central.identifier)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let value = request.value else { continue }
            onData?(request.central.identifier, value)
        }
    }
}
