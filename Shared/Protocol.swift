// Wire protocol shared by the iPad sender and the Mac receiver.
// Every message is one fixed-size UDP datagram (20 bytes), so there is no framing
// and a lost packet only costs one pointer sample.

import Foundation
import CoreGraphics

enum PacketKind: UInt8 {
    case hello = 0          // iPad -> Mac: "I'm here", also used as a keepalive
    case config = 1         // Mac -> iPad: x,y = target display size in points
    case moveAbsolute = 2   // x,y normalized 0...1 inside the mapped area (pen tablet mode)
    case moveRelative = 3   // dx,dy in points (trackpad mode)
    case buttonDown = 4     // button = MouseButton
    case buttonUp = 5
    case scroll = 6         // dx,dy = finger travel in points, flags = ScrollPhase
    case key = 7            // button = virtual key code, flags = KeyModifiers
    case peerAddress = 8    // Mac -> iPad: bytes 1-2 = port (big endian), bytes 4-19 = a link-local IPv6 of the Mac
    case pairPending = 9    // Mac -> iPad: this iPad is not approved yet; the Mac is asking its user
    case pairDenied = 10    // Mac -> iPad: the Mac's user said no
    case name = 11          // iPad -> Mac: bytes 4-19 = UTF-8 device name (truncated)
}

/// Values match CGMouseButton numbering, so the Mac can pass them straight through.
enum MouseButton: UInt8 {
    case left = 0, right = 1, middle = 2, back = 3, forward = 4
}

enum ScrollPhase: UInt8 {
    case began = 1, changed, ended, momentumBegan, momentumChanged, momentumEnded
}

struct KeyModifiers: OptionSet {
    let rawValue: UInt8
    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift   = KeyModifiers(rawValue: 1 << 1)
    static let control = KeyModifiers(rawValue: 1 << 2)
    static let option  = KeyModifiers(rawValue: 1 << 3)
}

/// macOS virtual key codes (Carbon HIToolbox values).
enum KeyCode {
    static let equals: UInt8 = 24
    static let minus: UInt8 = 27
    static let leftArrow: UInt8 = 123
    static let rightArrow: UInt8 = 124
    static let downArrow: UInt8 = 125
    static let upArrow: UInt8 = 126
}

struct Packet {
    var kind: PacketKind
    var button: UInt8 = 0
    var flags: UInt8 = 0
    var x: Float = 0
    var y: Float = 0
    var dx: Float = 0
    var dy: Float = 0

    static let byteCount = 20
    static let serviceType = "_ipadmouse._udp"

    func encoded() -> Data {
        var bytes: [UInt8] = [kind.rawValue, button, flags, 0]
        bytes.reserveCapacity(Self.byteCount)
        for value in [x, y, dx, dy] {
            let bits = value.bitPattern.littleEndian
            bytes.append(UInt8(bits & 0xff))
            bytes.append(UInt8((bits >> 8) & 0xff))
            bytes.append(UInt8((bits >> 16) & 0xff))
            bytes.append(UInt8((bits >> 24) & 0xff))
        }
        return Data(bytes)
    }
}

extension Packet {
    /// Raw layout for `.peerAddress`: [8, portHi, portLo, 0, 16 bytes of IPv6].
    static func peerAddress(ipv6: [UInt8], port: UInt16) -> Data {
        var b = [UInt8](repeating: 0, count: byteCount)
        b[0] = PacketKind.peerAddress.rawValue
        b[1] = UInt8(port >> 8)
        b[2] = UInt8(port & 0xff)
        for i in 0 ..< min(16, ipv6.count) { b[4 + i] = ipv6[i] }
        return Data(b)
    }

    /// Hello carries a 16-byte device token in bytes 4-19 so the Mac can recognise approved iPads.
    static func hello(token: [UInt8]) -> Data {
        var b = [UInt8](repeating: 0, count: byteCount)
        b[0] = PacketKind.hello.rawValue
        for i in 0 ..< min(16, token.count) { b[4 + i] = token[i] }
        return Data(b)
    }

    static func token(fromHello data: Data) -> [UInt8]? {
        let b = [UInt8](data)
        guard b.count >= byteCount, b[0] == PacketKind.hello.rawValue else { return nil }
        return Array(b[4 ..< 20])
    }

    static func name(_ text: String) -> Data {
        var b = [UInt8](repeating: 0, count: byteCount)
        b[0] = PacketKind.name.rawValue
        let utf8 = Array(text.utf8.prefix(16))
        for i in 0 ..< utf8.count { b[4 + i] = utf8[i] }
        return Data(b)
    }

    static func parseName(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= byteCount, b[0] == PacketKind.name.rawValue else { return nil }
        let bytes = Array(b[4 ..< 20]).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func parsePeerAddress(_ data: Data) -> (ipv6: [UInt8], port: UInt16)? {
        let b = [UInt8](data)
        guard b.count >= byteCount, b[0] == PacketKind.peerAddress.rawValue else { return nil }
        return (Array(b[4 ..< 20]), UInt16(b[1]) << 8 | UInt16(b[2]))
    }

    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= Packet.byteCount, let kind = PacketKind(rawValue: b[0]) else { return nil }
        func float(at i: Int) -> Float {
            let bits = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            return Float(bitPattern: bits)
        }
        self.init(kind: kind, button: b[1], flags: b[2], x: float(at: 4), y: float(at: 8), dx: float(at: 12), dy: float(at: 16))
    }
}
