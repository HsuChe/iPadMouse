// Finds the Mac over Bonjour and keeps a UDP "connection" to it.
// Status strings go to the HUD; the config reply carries the Mac display size.

import Foundation
import Network
import Darwin
import CoreGraphics
import UIKit

final class Link {
    var onStatus: ((String) -> Void)?
    var onConfig: ((CGSize) -> Void)?
    /// Names of Macs currently visible on the network (main-thread safe copy via onMacsChanged).
    var onMacsChanged: (([String]) -> Void)?
    private(set) var availableMacs: [String] = []
    private var bonjourMacs: [String] = []
    private var bluetoothMacs: [String] = []

    /// Stable per-install identity the Mac approves once.
    private let token: [UInt8] = {
        if let saved = UserDefaults.standard.data(forKey: "deviceToken"), saved.count == 16 { return [UInt8](saved) }
        let fresh = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        UserDefaults.standard.set(Data(fresh), forKey: "deviceToken")
        return fresh
    }()
    private let deviceName = UIDevice.current.name
    private var preferredMac: String? = UserDefaults.standard.string(forKey: "preferredMac")
    private var results = Set<NWBrowser.Result>()

    /// When on, the direct USB link is used whenever the cable is attached; without it, Wi-Fi carries on.
    /// Saved, and on by default: Wi-Fi delivery jitters by 100-150 ms, USB by about 5 ms.
    var preferWired = UserDefaults.standard.object(forKey: "preferWired") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(preferWired, forKey: "preferWired")
            queue.async {
                if self.preferWired {
                    self.triedDirectHosts.removeAll()       // next peerAddress packet will trigger an attempt
                } else {
                    self.directConnection?.cancel()
                    self.directConnection = nil
                    for c in self.directCandidates.values { c.cancel() }
                    self.directCandidates.removeAll()
                    self.report("Using Wi-Fi")
                }
            }
        }
    }

    /// When on, packets go over Bluetooth whenever that link is up and no USB cable is attached; Wi-Fi is
    /// then only the fallback. Off by default: turning it on makes iPadOS ask for Bluetooth permission.
    var useBluetooth = UserDefaults.standard.bool(forKey: "useBluetooth") {
        didSet {
            UserDefaults.standard.set(useBluetooth, forKey: "useBluetooth")
            queue.async {
                if self.useBluetooth {
                    self.startBluetooth()
                } else {
                    self.bluetooth.stop()
                    self.bluetoothReplied = false
                    self.report("Bluetooth off")
                }
            }
        }
    }

    /// Which link the next packet will travel over, for the HUD.
    var carrier: String {
        if directConnection != nil { return "USB" }
        if bluetooth.ready { return "Bluetooth" }
        return connection == nil ? "none" : "Wi-Fi"
    }

    private let queue = DispatchQueue(label: "ipadmouse.link", qos: .userInteractive)
    private lazy var bluetooth = BluetoothLink(queue: queue)
    private var bluetoothReplied = false
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var keepalive: DispatchSourceTimer?
    private var lastReply = Date()
    /// Direct USB attempt: candidate connections keyed by scoped host, and the one that answered.
    private var directCandidates: [String: NWConnection] = [:]
    private var directConnection: NWConnection?
    private var triedDirectHosts = Set<String>()

    func start() {
        // No peer-to-peer (AWDL): while it is in use the Wi-Fi radio leaves the network's channel for about
        // 160 ms in every 524 ms, and every packet sent in that window waits. The Mac log showed all of a
        // session's "LINK delayed it" pauses locked to that 524 ms cycle (2026-11-05).
        let params = NWParameters()
        let browser = NWBrowser(for: .bonjour(type: Packet.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.report("Discovery failed: \(error.localizedDescription)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            for change in changes {
                if case .removed(let result) = change, result.endpoint == self.endpoint {
                    self.report("Mac went away, reconnecting…")
                    self.dropConnection(retry: true)
                    return
                }
            }
            self.connectIfNeeded(results)
        }
        browser.start(queue: queue)
        self.browser = browser
        report("Searching for the Mac…")
        if useBluetooth { queue.async { self.startBluetooth() } }
    }

    func send(_ packet: Packet) {
        transmit(packet.encoded())
    }

    /// A diagnostic line that lands in the Mac's log (~/Library/Logs/iPadMouse.log).
    func note(_ text: String) {
        transmit(Packet.note(text))
    }

    /// USB first, then Bluetooth if it is switched on and connected, then Wi-Fi.
    private func transmit(_ data: Data) {
        if let direct = directConnection {
            direct.send(content: data, completion: .idempotent)
        } else if bluetooth.ready {
            bluetooth.send(data)
        } else {
            connection?.send(content: data, completion: .idempotent)
        }
    }

    // MARK: Bluetooth

    /// Call on the link queue.
    private func startBluetooth() {
        bluetooth.onStatus = { [weak self] text in self?.report(text) }
        bluetooth.hello = { [weak self] in
            guard let self else { return [] }
            return [Packet.name(self.deviceName), Packet.hello(token: self.token)]
        }
        bluetooth.onMacsChanged = { [weak self] macs in
            self?.bluetoothMacs = macs
            self?.publishMacs()
        }
        bluetooth.onData = { [weak self] data in
            guard let self, let packet = Packet(data: data) else { return }
            switch packet.kind {
            case .pairPending:
                self.report("Waiting for approval on the Mac… (check the Mac's screen)")
            case .pairDenied:
                self.report("The Mac denied this iPad. Use “Forget Paired iPads” on the Mac to retry.")
            case .config:
                if !self.bluetoothReplied {
                    self.bluetoothReplied = true
                    self.report("Connected via Bluetooth")
                }
                self.onConfig?(CGSize(width: CGFloat(packet.x), height: CGFloat(packet.y)))
            default:
                break
            }
        }
        bluetoothReplied = false
        bluetooth.wantedMac = preferredMac
        bluetooth.start()
    }

    /// The Macs list is everything seen over Bonjour plus any Mac seen only over Bluetooth.
    private func publishMacs() {
        let extra = bluetoothMacs.filter { b in !bonjourMacs.contains { BluetoothLink.sameMac($0, b) } }
        let macs = (bonjourMacs + extra).sorted()
        if macs != availableMacs {
            availableMacs = macs
            onMacsChanged?(macs)
        }
    }

    /// Hello (with our token) preceded by our name, on a specific connection.
    private func sendHello(on c: NWConnection) {
        c.send(content: Packet.name(deviceName), completion: .idempotent)
        c.send(content: Packet.hello(token: token), completion: .idempotent)
    }

    /// User picked a Mac from the list.
    func connect(toMacNamed name: String) {
        preferredMac = name
        UserDefaults.standard.set(name, forKey: "preferredMac")
        queue.async {
            self.dropConnection(retry: false)
            if self.useBluetooth {
                // Start the Bluetooth side over as well, so it follows the choice.
                self.bluetooth.stop()
                self.startBluetooth()
            }
            if let r = self.results.first(where: { self.name(of: $0.endpoint) == name }) {
                self.connect(to: r.endpoint)
            } else if !self.bluetoothMacs.contains(where: { BluetoothLink.sameMac($0, name) }) {
                self.report("\(name) is not visible right now")
            }
        }
    }

    // MARK: Private

    private func report(_ text: String) {
        onStatus?(text)
    }

    private func connectIfNeeded(_ results: Set<NWBrowser.Result>) {
        self.results = results
        bonjourMacs = results.map { name(of: $0.endpoint) }.sorted()
        publishMacs()
        guard connection == nil else { return }
        if let preferred = preferredMac, let r = results.first(where: { name(of: $0.endpoint) == preferred }) {
            connect(to: r.endpoint)
        } else if results.count == 1, let only = results.first {
            connect(to: only.endpoint)
        } else if results.isEmpty {
            report("Searching for a Mac… is iPad Mouse running there?")
        } else {
            report("\(results.count) Macs found. Tap “Macs” to choose one.")
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        self.endpoint = endpoint
        let params = NWParameters.udp
        // Bonjour discovery stays on Wi-Fi; "Prefer USB" switches to a direct address once the Mac sends one.
        let connection = NWConnection(to: endpoint, using: params)
        lastReply = Date()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report("Link up, waiting for the Mac to reply…")
                self.startKeepalive()
                self.receive(on: connection)
                self.sendHello(on: connection)
            case .waiting(let error):
                self.report("Waiting: \(error.localizedDescription)")
            case .failed(let error):
                self.report("Link failed: \(error.localizedDescription)")
                self.dropConnection(retry: true)
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
        report("Connecting to \(name(of: endpoint))…")
    }

    private func dropConnection(retry: Bool) {
        keepalive?.cancel()
        keepalive = nil
        connection?.cancel()
        connection = nil
        directConnection?.cancel()
        directConnection = nil
        for c in directCandidates.values { c.cancel() }
        directCandidates.removeAll()
        triedDirectHosts.removeAll()
        guard retry else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let browser = self.browser else { return }
            self.connectIfNeeded(browser.browseResults)
        }
    }

    /// A hello every 2 s; the Mac answers each one with a config packet.
    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReply) > 6 {
                self.report("No reply from the Mac, reconnecting…")
                self.dropConnection(retry: true)
                return
            }
            if let direct = self.directConnection { self.sendHello(on: direct) }
            // Keep the discovery link alive too so the Mac keeps telling us its USB address.
            if let c = self.connection { self.sendHello(on: c) }
        }
        timer.resume()
        keepalive = timer
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let peer = Packet.parsePeerAddress(data) {
                if self.preferWired { self.tryDirect(ipv6: peer.ipv6, port: peer.port) }
            } else if let data, let packet = Packet(data: data), packet.kind == .pairPending {
                self.lastReply = Date()
                self.report("Waiting for approval on \(self.name(of: connection.endpoint))… (check the Mac's screen)")
            } else if let data, let packet = Packet(data: data), packet.kind == .pairDenied {
                self.lastReply = Date()
                self.report("\(self.name(of: connection.endpoint)) denied this iPad. Use “Forget Paired iPads” on the Mac to retry.")
            } else if let data, let packet = Packet(data: data), packet.kind == .config {
                let firstReply = Date().timeIntervalSince(self.lastReply) > 1.5
                self.lastReply = Date()
                let wired = connection.currentPath?.usesInterfaceType(.wiredEthernet) ?? false
                if firstReply {
                    self.report("Connected to \(self.name(of: connection.endpoint)) via \(wired ? "USB" : "Wi-Fi")")
                }
                self.onConfig?(CGSize(width: CGFloat(packet.x), height: CGFloat(packet.y)))
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    // MARK: Direct USB path

    /// The Mac told us one of its link-local addresses. Try it through each non-Wi-Fi interface we have.
    private func tryDirect(ipv6: [UInt8], port: UInt16) {
        guard directConnection == nil else { return }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var raw = in6_addr()
        _ = withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: ipv6) }
        guard inet_ntop(AF_INET6, &raw, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else { return }
        let address = String(cString: text)
        for iface in Self.candidateWiredInterfaces() {
            let host = "\(address)%\(iface)"
            guard !triedDirectHosts.contains(host) else { continue }
            triedDirectHosts.insert(host)
            let params = NWParameters.udp
            let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 0, using: params)
            directCandidates[host] = c
            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendHello(on: c)
                    self.receiveDirect(on: c, host: host)
                case .failed, .cancelled:
                    self.directCandidates[host] = nil
                default:
                    break
                }
            }
            c.start(queue: queue)
            report("Trying USB path \(iface)…")
        }
    }

    private func receiveDirect(on c: NWConnection, host: String) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = Packet(data: data), packet.kind == .config, self.directConnection == nil {
                // This path answers: make it primary and drop the others.
                self.directConnection = c
                self.directCandidates[host] = nil
                for other in self.directCandidates.values { other.cancel() }
                self.directCandidates.removeAll()
                self.lastReply = Date()
                self.report("Connected via USB (direct)")
                self.onConfig?(CGSize(width: CGFloat(packet.x), height: CGFloat(packet.y)))
            } else if let data, let packet = Packet(data: data), packet.kind == .config {
                self.lastReply = Date()
                self.onConfig?(CGSize(width: CGFloat(packet.x), height: CGFloat(packet.y)))
            }
            if error == nil { self.receiveDirect(on: c, host: host) }
        }
    }

    /// Interface names that could carry the USB link: en* except en0 (Wi-Fi), plus anything else Ethernet-like.
    static func candidateWiredInterfaces() -> [String] {
        var names = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en"), name != "en0" else { continue }
            names.insert(name)
        }
        return names.sorted()
    }

    private func name(of endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return "\(endpoint)"
    }
}
