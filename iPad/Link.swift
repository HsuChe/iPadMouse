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

    /// When on, Wi-Fi and cellular are prohibited so only a wired (USB) link can be used.
    var preferWired = false {
        didSet {
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

    private let queue = DispatchQueue(label: "ipadmouse.link", qos: .userInteractive)
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
        let params = NWParameters()
        params.includePeerToPeer = true
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
    }

    func send(_ packet: Packet) {
        (directConnection ?? connection)?.send(content: packet.encoded(), completion: .idempotent)
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
            if let r = self.results.first(where: { self.name(of: $0.endpoint) == name }) {
                self.connect(to: r.endpoint)
            } else {
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
        let macs = results.map { name(of: $0.endpoint) }.sorted()
        if macs != availableMacs {
            availableMacs = macs
            onMacsChanged?(macs)
        }
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
        params.includePeerToPeer = true
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
