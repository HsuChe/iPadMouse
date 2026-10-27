// Advertises "_ipadmouse._udp" over Bonjour (Wi-Fi, peer-to-peer and any USB network link)
// and feeds incoming packets to the Injector.

import Foundation
import Network
import Darwin

final class Receiver {
    var onStatus: ((String) -> Void)?
    /// Called (on the receiver queue) when an unknown iPad asks to connect. Answer with resolvePairing.
    var onPairRequest: ((_ name: String, _ token: [UInt8]) -> Void)?

    private let injector: Injector
    private let queue = DispatchQueue(label: "ipadmouse.receiver", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var lastPacket = Date()
    private var watchdog: DispatchSourceTimer?

    // Pairing: approved device tokens persist; a connection (one UDP flow) is authorized once its hello carries one.
    private var approvedTokens: Set<Data> = Set((UserDefaults.standard.array(forKey: "approvedTokens") as? [Data]) ?? [])
    private var deniedTokens = Set<Data>()
    private var pendingToken: Data?
    private var authorized = Set<ObjectIdentifier>()
    private var names: [ObjectIdentifier: String] = [:]

    func resolvePairing(token: [UInt8], allowed: Bool) {
        queue.async {
            let key = Data(token)
            if allowed {
                self.approvedTokens.insert(key)
                UserDefaults.standard.set(Array(self.approvedTokens), forKey: "approvedTokens")
                self.log("pairing approved")
            } else {
                self.deniedTokens.insert(key)
                self.log("pairing denied")
            }
            if self.pendingToken == key { self.pendingToken = nil }
        }
    }

    func forgetAllDevices() {
        queue.async {
            self.approvedTokens.removeAll()
            self.deniedTokens.removeAll()
            self.authorized.removeAll()
            UserDefaults.standard.removeObject(forKey: "approvedTokens")
            self.onStatus?("All iPads forgotten; waiting for a new request")
        }
    }

    init(injector: Injector) {
        self.injector = injector
    }

    /// Button and key events are appended to ~/Library/Logs/iPadMouse.log for debugging.
    private lazy var logHandle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iPadMouse.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()

    private func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logHandle?.write("\(stamp) \(text)\n".data(using: .utf8) ?? Data())
    }

    func start() {
        let params = NWParameters.udp
        params.includePeerToPeer = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            onStatus?("Could not listen: \(error.localizedDescription)")
            return
        }
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: Packet.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            NSLog("iPadMouse listener state: \(state)")
            switch state {
            case .ready:
                self?.onStatus?("Waiting for iPad… (port \(listener.port?.rawValue ?? 0))")
            case .waiting(let error):
                // Typically "Local Network" permission not granted yet (System Settings > Privacy & Security > Local Network).
                self?.onStatus?("Blocked: \(error.localizedDescription). Check Local Network permission.")
            case .failed(let error):
                self?.onStatus?("Listener failed: \(error.localizedDescription)")
            case .cancelled:
                self?.onStatus?("Listener stopped")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

        // If packets stop while a button is held (cable pulled, iPad app backgrounded), let go.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.injector.anyButtonDown, Date().timeIntervalSince(self.lastPacket) > 1.0 else { return }
            self.log("watchdog: releasing held buttons after link silence")
            self.injector.releaseAll()
        }
        timer.resume()
        watchdog = timer
    }

    func releaseAll() {
        queue.async { self.injector.releaseAll() }
    }

    /// Re-send the display size to every iPad, e.g. after the target display changes.
    func broadcastConfig() {
        queue.async {
            for c in self.connections { self.sendConfig(to: c) }
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.connections.removeAll { $0 === connection }
                self.authorized.remove(ObjectIdentifier(connection))
                self.names[ObjectIdentifier(connection)] = nil
                self.onStatus?("iPad disconnected")
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let name = Packet.parseName(data) {
                self.names[ObjectIdentifier(connection)] = name
            } else if let data, let token = Packet.token(fromHello: data) {
                self.handleHello(token: token, from: connection)
            } else if let data, let packet = Packet(data: data) {
                self.handle(packet, from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func sendConfig(to connection: NWConnection) {
        let size = injector.displaySize
        let reply = Packet(kind: .config, x: Float(size.width), y: Float(size.height))
        connection.send(content: reply.encoded(), completion: .idempotent)
        // Tell the iPad how to reach us directly over any wired (USB) link, bypassing Bonjour.
        if let port = listener?.port?.rawValue {
            for address in Self.wiredLinkLocalAddresses() {
                connection.send(content: Packet.peerAddress(ipv6: address, port: port), completion: .idempotent)
            }
        }
    }

    /// Link-local IPv6 addresses on Ethernet-like interfaces other than Wi-Fi (en0): the iPad USB link shows up here.
    static func wiredLinkLocalAddresses() -> [[UInt8]] {
        var result: [[UInt8]] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en"), name != "en0" else { continue }
            var sin6 = sockaddr_in6()
            memcpy(&sin6, addr, Int(MemoryLayout<sockaddr_in6>.size))
            let bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
            guard bytes.count == 16, bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 else { continue }
            result.append(bytes)
        }
        return result
    }

    private func handleHello(token: [UInt8], from connection: NWConnection) {
        lastPacket = Date()
        let id = ObjectIdentifier(connection)
        let key = Data(token)
        let name = names[id] ?? "iPad"
        if approvedTokens.contains(key) {
            if !authorized.contains(id) {
                authorized.insert(id)
                onStatus?("\(name) connected")
                log("authorized \(name) on \(connection.endpoint)")
            }
            sendConfig(to: connection)
        } else if deniedTokens.contains(key) {
            connection.send(content: Packet(kind: .pairDenied).encoded(), completion: .idempotent)
        } else {
            connection.send(content: Packet(kind: .pairPending).encoded(), completion: .idempotent)
            if pendingToken == nil {
                pendingToken = key
                onStatus?("\(name) is asking to connect…")
                onPairRequest?(name, token)
            }
        }
    }

    private func handle(_ p: Packet, from connection: NWConnection) {
        lastPacket = Date()
        guard authorized.contains(ObjectIdentifier(connection)) else { return }
        switch p.kind {
        case .hello, .name, .pairPending, .pairDenied:
            break
        case .config, .peerAddress:
            break
        case .moveAbsolute:
            injector.moveAbsolute(nx: p.x, ny: p.y)
        case .moveRelative:
            injector.moveRelative(dx: CGFloat(p.dx), dy: CGFloat(p.dy))
        case .buttonDown:
            log("buttonDown \(p.button) (\(MouseButton(rawValue: p.button).map { "\($0)" } ?? "?"))")
            injector.button(p.button, down: true)
        case .buttonUp:
            log("buttonUp \(p.button)")
            injector.button(p.button, down: false)
        case .scroll:
            if let phase = ScrollPhase(rawValue: p.flags) {
                injector.scroll(dx: p.dx, dy: p.dy, phase: phase)
            }
        case .key:
            log("key \(p.button) mods \(p.flags)")
            injector.key(code: UInt16(p.button), modifiers: KeyModifiers(rawValue: p.flags))
        }
    }
}
