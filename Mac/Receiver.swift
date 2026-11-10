// Advertises "_ipadmouse._udp" over Bonjour (Wi-Fi, peer-to-peer and any USB network link)
// and feeds incoming packets to the Injector.

import AppKit
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

    /// One iPad link, whatever carries it: a UDP flow (Wi-Fi or USB) or a Bluetooth connection.
    private final class Peer {
        let label: String
        /// UDP links are also told the Mac's USB addresses; that means nothing over Bluetooth.
        let overNetwork: Bool
        let send: (Data) -> Void
        init(label: String, overNetwork: Bool, send: @escaping (Data) -> Void) {
            self.label = label
            self.overNetwork = overNetwork
            self.send = send
        }
    }
    private var networkPeers: [ObjectIdentifier: Peer] = [:]
    private var bluetoothPeers: [UUID: Peer] = [:]
    private lazy var bluetooth = BluetoothListener(queue: queue)
    private var lastPacket = Date()
    private var watchdog: DispatchSourceTimer?

    // Timing stats for move packets, logged every 2 s while moves arrive.
    private var statCount = 0
    private var statLastArrival: Double = 0
    private var statMaxGap: Double = 0
    private var statOffsetMin = Double.greatestFiniteMagnitude
    private var statOffsetMax = -Double.greatestFiniteMagnitude
    private var statWindowStart: Double = 0

    private func recordMove(sentStamp: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        if statCount > 0 {
            statMaxGap = max(statMaxGap, now - statLastArrival)
        } else {
            statWindowStart = now
        }
        statLastArrival = now
        statCount += 1
        if sentStamp > 0 {
            let offset = now - Double(sentStamp)       // clocks differ; only the spread matters
            statOffsetMin = min(statOffsetMin, offset)
            statOffsetMax = max(statOffsetMax, offset)
        }
        if now - statWindowStart >= 2 {
            let seconds = now - statWindowStart
            let jitter = statOffsetMax >= statOffsetMin ? (statOffsetMax - statOffsetMin) * 1000 : 0
            log(String(format: "moves: %d in %.1fs (%.0f/s), max gap %.1f ms, delivery jitter %.1f ms",
                       statCount, seconds, Double(statCount) / seconds, statMaxGap * 1000, jitter))
            statCount = 0
            statMaxGap = 0
            statOffsetMin = Double.greatestFiniteMagnitude
            statOffsetMax = -Double.greatestFiniteMagnitude
        }
    }

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

    private var lastDownAt: [UInt8: TimeInterval] = [:]
    /// Finger (relative) moves: a gap of 40 ms to 1 s between two moves is a pause in the middle of a glide.
    private var lastRelativeMove: TimeInterval = 0
    private var lastRelativeSent: Float = 0
    private var lastStroke: UInt8 = 0
    private var relativeCount = 0
    private var relativeWindow: TimeInterval = 0
    /// Arrival time minus the iPad's send time, smallest and largest in the window. The two clocks differ,
    /// so only the spread means anything: it is how much later the slowest packet was than the quickest.
    private var relativeOffsetMin = Double.greatestFiniteMagnitude
    private var relativeOffsetMax = -Double.greatestFiniteMagnitude
    /// A gap of 40 ms or more inside one stroke (finger still on the glass) is a pause. The iPad's send
    /// times show whose fault it is: if the iPad also sent nothing for that long, the finger was still or
    /// the iPad stalled (a large touch age means the iPad stalled); if the iPad sent on time, the link held
    /// the packets.
    private func recordRelativeMove(stroke: UInt8, sentAt: Float, touchAgeMs: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastRelativeMove
        if lastRelativeMove > 0, stroke == lastStroke, gap > 0.04, gap < 2 {
            let sentGap = Double(sentAt - lastRelativeSent)
            let cause: String
            if sentGap < gap * 0.5 { cause = "LINK delayed it" }
            else if touchAgeMs > 30 { cause = "iPad STALLED" }
            else { cause = "iPad sent nothing (finger still?)" }
            log(String(format: "finger move PAUSE %.0f ms in stroke %d: iPad send gap %.0f ms, touch age %.0f ms → %@",
                       gap * 1000, stroke, sentGap * 1000, touchAgeMs, cause))
        }
        if stroke != lastStroke || gap >= 2 {
            // A stroke of half a second or more still gets a line; shorter ones say too little.
            if relativeCount >= 15, lastRelativeMove - relativeWindow >= 0.5 { logRelativeWindow(until: lastRelativeMove) }
            relativeCount = 0
            relativeWindow = now
            relativeOffsetMin = Double.greatestFiniteMagnitude
            relativeOffsetMax = -Double.greatestFiniteMagnitude
        }
        lastRelativeMove = now
        lastRelativeSent = sentAt
        lastStroke = stroke
        relativeCount += 1
        let offset = now - Double(sentAt)
        relativeOffsetMin = min(relativeOffsetMin, offset)
        relativeOffsetMax = max(relativeOffsetMax, offset)
        if now - relativeWindow >= 2 {
            logRelativeWindow(until: now)
            relativeCount = 0
            relativeWindow = now
            relativeOffsetMin = Double.greatestFiniteMagnitude
            relativeOffsetMax = -Double.greatestFiniteMagnitude
        }
    }
    // The pointer sometimes turns invisible on the Mac while the iPad is moving it (hover highlights still
    // follow it), until a switch to another Space brings it back. Tested 2026-11-05: a pointer hidden by
    // typing comes back on our first move, but one hidden by an app's own hide call stays hidden whatever
    // moves arrive. So when it stays invisible while moves keep coming, log which app is in front.
    private static let cursorIsVisible: (@convention(c) () -> UInt32)? = {
        typealias Fn = @convention(c) () -> UInt32
        if let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
           let p = dlsym(sky, "SLCursorIsVisible") { return unsafeBitCast(p, to: Fn.self) }
        if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") { return unsafeBitCast(p, to: Fn.self) }
        return nil
    }()
    private var lastVisibilityCheck: TimeInterval = 0
    private var hiddenSince: TimeInterval?
    private var hiddenChecks = 0
    private var movesWhileHidden = 0
    private var hiddenLogged = false

    private func checkPointerVisible() {
        guard let visible = Self.cursorIsVisible else { return }
        if hiddenSince != nil { movesWhileHidden += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVisibilityCheck >= 0.25 else { return }
        let steady = now - lastVisibilityCheck < 1          // moves have kept coming since the last check
        lastVisibilityCheck = now
        if visible() != 0 {
            if hiddenLogged, let since = hiddenSince {
                log(String(format: "pointer visible again after %.1f s (%d moves arrived while it was hidden)",
                           now - since, movesWhileHidden))
            }
            hiddenSince = nil
            hiddenLogged = false
            return
        }
        if hiddenSince == nil { hiddenSince = now; hiddenChecks = 0; movesWhileHidden = 0 }
        hiddenChecks = steady ? hiddenChecks + 1 : 1
        // Three checks in a row during one steady movement: hidden for over half a second of real motion.
        guard !hiddenLogged, hiddenChecks >= 3 else { return }
        hiddenLogged = true
        // A recent key press points at "hidden while typing", which each new key press renews.
        let sinceKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let moves = movesWhileHidden
        DispatchQueue.main.async {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            self.queue.async {
                self.log(String(format: "pointer INVISIBLE while the iPad moves it (%d moves so far); frontmost app: %@; last key press %.1f s ago",
                                moves, front, sinceKey))
            }
        }
    }

    /// Which Space each display is showing, for checking that a swipe really switched Space.
    private struct SpaceState {
        var ids: [Int]
        var text: String            // "Space 3 of 4", one per display
    }

    /// Nil if macOS no longer offers the (private) call.
    private static func currentSpaces() -> SpaceState? {
        typealias Connection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let connection = dlsym(sky, "CGSMainConnectionID"),
              let copy = dlsym(sky, "CGSCopyManagedDisplaySpaces") else { return nil }
        let id = unsafeBitCast(connection, to: Connection.self)()
        guard let displays = unsafeBitCast(copy, to: CopySpaces.self)(id)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var state = SpaceState(ids: [], text: "")
        var parts: [String] = []
        for display in displays {
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
            let all = (display["Spaces"] as? [[String: Any]] ?? []).map { $0["ManagedSpaceID"] as? Int ?? -1 }
            state.ids.append(current)
            parts.append("Space \((all.firstIndex(of: current) ?? -1) + 1) of \(all.count)")
        }
        state.text = parts.joined(separator: ", ")
        return state
    }

    // A swipe on the iPad that "does nothing" either never arrived or was ignored by macOS. The key line in the
    // log covers the first; this covers the second. macOS reports the new Space only once the slide has
    // finished, so the check waits for the swipes to stop and then compares with where they started.
    private var spaceSwipeStart: SpaceState?
    private var spaceSwipeKeys = 0
    private var spaceSwipeNet = 0
    private var spaceSwipeGeneration = 0
    private let spaceSwipeSettle: TimeInterval = 1.5

    private func noteSpaceKey(next: Bool) {
        if spaceSwipeStart == nil {
            guard let now = Self.currentSpaces() else { return }
            spaceSwipeStart = now
            spaceSwipeKeys = 0
            spaceSwipeNet = 0
        }
        spaceSwipeKeys += 1
        spaceSwipeNet += next ? 1 : -1
        spaceSwipeGeneration += 1
        let generation = spaceSwipeGeneration
        queue.asyncAfter(deadline: .now() + spaceSwipeSettle) { [weak self] in
            guard let self, generation == self.spaceSwipeGeneration else { return }
            self.reportSpaceSwitch()
        }
    }

    private func reportSpaceSwitch() {
        guard let before = spaceSwipeStart, let after = Self.currentSpaces() else { return }
        let keys = "\(spaceSwipeKeys) swipe key\(spaceSwipeKeys == 1 ? "" : "s"), net \(abs(spaceSwipeNet)) \(spaceSwipeNet >= 0 ? "next" : "previous")"
        spaceSwipeStart = nil
        if after.ids != before.ids {
            log("Space changed: \(before.text) -> \(after.text) (\(keys))")
            return
        }
        let pointerHidden = Self.cursorIsVisible.map { $0() == 0 } ?? false
        DispatchQueue.main.async {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            self.queue.async {
                self.log("Space did NOT change (still \(after.text)) after \(keys); frontmost app: \(front); pointer \(pointerHidden ? "hidden" : "visible")")
            }
        }
    }

    private func logRelativeWindow(until end: TimeInterval) {
        log(String(format: "finger moves: %.0f/s over %.1f s, delivery spread %.0f ms",
                   Double(relativeCount) / max(end - relativeWindow, 0.001), end - relativeWindow,
                   (relativeOffsetMax - relativeOffsetMin) * 1000))
    }

    private let stampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func log(_ text: String) {
        let stamp = stampFormatter.string(from: Date())
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
        startBluetooth()

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

    /// The same packets, arriving over Bluetooth instead of UDP.
    private func startBluetooth() {
        bluetooth.onLog = { [weak self] text in self?.log("Bluetooth: \(text)") }
        bluetooth.onData = { [weak self] id, data in
            guard let self else { return }
            let peer = self.bluetoothPeers[id] ?? Peer(label: "Bluetooth", overNetwork: false) { [weak self] reply in
                self?.bluetooth.send(reply, to: id)
            }
            self.bluetoothPeers[id] = peer
            self.dispatch(data, from: peer)
        }
        bluetooth.onGone = { [weak self] id in
            guard let self, let peer = self.bluetoothPeers.removeValue(forKey: id) else { return }
            self.forget(peer)
            self.onStatus?("iPad disconnected (Bluetooth)")
        }
        bluetooth.start(name: Host.current().localizedName ?? "Mac")
    }

    private func forget(_ peer: Peer) {
        authorized.remove(ObjectIdentifier(peer))
        names[ObjectIdentifier(peer)] = nil
    }

    /// Re-send the display size to every iPad, e.g. after the target display changes.
    func broadcastConfig() {
        queue.async {
            for peer in Array(self.networkPeers.values) + Array(self.bluetoothPeers.values) { self.sendConfig(to: peer) }
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        let peer = Peer(label: "\(connection.endpoint)", overNetwork: true) { [weak connection] data in
            connection?.send(content: data, completion: .idempotent)
        }
        networkPeers[ObjectIdentifier(connection)] = peer
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.connections.removeAll { $0 === connection }
                if let peer = self.networkPeers.removeValue(forKey: ObjectIdentifier(connection)) { self.forget(peer) }
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
            if let data, let peer = self.networkPeers[ObjectIdentifier(connection)] {
                self.dispatch(data, from: peer)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    /// One packet from an iPad, over any link.
    private func dispatch(_ data: Data, from peer: Peer) {
        if let name = Packet.parseName(data) {
            names[ObjectIdentifier(peer)] = name
        } else if let note = Packet.parseNote(data) {
            if authorized.contains(ObjectIdentifier(peer)) { log("iPad: \(note)") }
        } else if let token = Packet.token(fromHello: data) {
            handleHello(token: token, from: peer)
        } else if let packet = Packet(data: data) {
            handle(packet, from: peer)
        }
    }

    private func sendConfig(to peer: Peer) {
        let size = injector.displaySize
        let reply = Packet(kind: .config, x: Float(size.width), y: Float(size.height))
        peer.send(reply.encoded())
        // Tell the iPad how to reach us directly over any wired (USB) link, bypassing Bonjour.
        if peer.overNetwork, let port = listener?.port?.rawValue {
            for address in Self.wiredLinkLocalAddresses() {
                peer.send(Packet.peerAddress(ipv6: address, port: port))
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

    private func handleHello(token: [UInt8], from peer: Peer) {
        lastPacket = Date()
        let id = ObjectIdentifier(peer)
        let key = Data(token)
        let name = names[id] ?? "iPad"
        if approvedTokens.contains(key) {
            if !authorized.contains(id) {
                authorized.insert(id)
                onStatus?("\(name) connected")
                log("authorized \(name) on \(peer.label)")
            }
            sendConfig(to: peer)
        } else if deniedTokens.contains(key) {
            peer.send(Packet(kind: .pairDenied).encoded())
        } else {
            peer.send(Packet(kind: .pairPending).encoded())
            if pendingToken == nil {
                pendingToken = key
                onStatus?("\(name) is asking to connect…")
                onPairRequest?(name, token)
            }
        }
    }

    private func handle(_ p: Packet, from peer: Peer) {
        lastPacket = Date()
        guard authorized.contains(ObjectIdentifier(peer)) else { return }
        switch p.kind {
        case .hello, .name, .note, .pairPending, .pairDenied:
            break
        case .config, .peerAddress:
            break
        case .moveAbsolute:
            recordMove(sentStamp: p.dx)
            injector.moveAbsolute(nx: p.x, ny: p.y)
            checkPointerVisible()
        case .moveRelative:
            recordRelativeMove(stroke: p.button, sentAt: p.x, touchAgeMs: p.y)
            injector.moveRelative(dx: CGFloat(p.dx), dy: CGFloat(p.dy))
            checkPointerVisible()
        case .buttonDown:
            // Which input sent it, and how soon after the previous press of the same button: two presses
            // closer than the double-click interval are what macOS turns into a double-click.
            let now = ProcessInfo.processInfo.systemUptime
            let gap = lastDownAt[p.button].map { String(format: ", %.0f ms after the previous", (now - $0) * 1000) } ?? ""
            lastDownAt[p.button] = now
            let source = ClickSource(rawValue: p.flags)?.label ?? "source \(p.flags)"
            log("buttonDown \(p.button) (\(MouseButton(rawValue: p.button).map { "\($0)" } ?? "?")) from \(source)\(gap)")
            injector.button(p.button, down: true, singleClick: p.flags == ClickSource.tapDrag.rawValue)
        case .buttonUp:
            log("buttonUp \(p.button)")
            injector.button(p.button, down: false)
        case .magnify:
            injector.magnify(by: Double(p.dx), phase: p.flags)
        case .scroll:
            if p.flags == ScrollPhase.began.rawValue, p.button != 0 {
                log("circle scroll started (\(p.button == 1 ? "finger" : "Pencil")): pointer frozen")
            }
            if let phase = ScrollPhase(rawValue: p.flags) {
                injector.scroll(dx: p.dx, dy: p.dy, phase: phase)
            }
        case .key:
            log("key \(p.button) mods \(p.flags)")
            // Ctrl-Left / Ctrl-Right ask for another Space: note where we are, to check that it worked.
            let isSpaceKey = (p.button == KeyCode.leftArrow || p.button == KeyCode.rightArrow)
                && p.flags == KeyModifiers.control.rawValue
            if isSpaceKey { noteSpaceKey(next: p.button == KeyCode.rightArrow) }
            injector.key(code: UInt16(p.button), modifiers: KeyModifiers(rawValue: p.flags))
        }
    }
}
