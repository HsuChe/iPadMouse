// Finds the Mac over Bonjour and keeps a UDP "connection" to it.
// Status strings go to the HUD; the config reply carries the Mac display size.

import Foundation
import Network
import CoreGraphics

final class Link {
    var onStatus: ((String) -> Void)?
    var onConfig: ((CGSize) -> Void)?

    /// When on, Wi-Fi and cellular are prohibited so only a wired (USB) link can be used.
    var preferWired = false {
        didSet { queue.async { self.dropConnection(retry: true) } }
    }

    private let queue = DispatchQueue(label: "ipadmouse.link", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpoint: NWEndpoint?
    private var keepalive: DispatchSourceTimer?
    private var lastReply = Date()

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
        connection?.send(content: packet.encoded(), completion: .idempotent)
    }

    // MARK: Private

    private func report(_ text: String) {
        onStatus?(text)
    }

    private func connectIfNeeded(_ results: Set<NWBrowser.Result>) {
        guard connection == nil else { return }
        if let first = results.first {
            connect(to: first.endpoint)
        } else {
            report("Searching for the Mac… is iPad Mouse running there?")
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        self.endpoint = endpoint
        let params = NWParameters.udp
        params.includePeerToPeer = true
        if preferWired {
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
        }
        let connection = NWConnection(to: endpoint, using: params)
        lastReply = Date()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report("Link up, waiting for the Mac to reply…")
                self.startKeepalive()
                self.receive(on: connection)
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
            self.send(Packet(kind: .hello))
        }
        timer.resume()
        keepalive = timer
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = Packet(data: data), packet.kind == .config {
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

    private func name(of endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return "\(endpoint)"
    }
}
