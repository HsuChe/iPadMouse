// Advertises "_ipadmouse._udp" over Bonjour (Wi-Fi, peer-to-peer and any USB network link)
// and feeds incoming packets to the Injector.

import Foundation
import Network

final class Receiver {
    var onStatus: ((String) -> Void)?

    private let injector: Injector
    private let queue = DispatchQueue(label: "ipadmouse.receiver", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var lastPacket = Date()
    private var watchdog: DispatchSourceTimer?

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
            if let data, let packet = Packet(data: data) {
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
    }

    private func handle(_ p: Packet, from connection: NWConnection) {
        lastPacket = Date()
        switch p.kind {
        case .hello:
            sendConfig(to: connection)
            onStatus?("iPad connected: \(connection.endpoint)")
            NSLog("iPadMouse hello from \(connection.endpoint)")
        case .config:
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
