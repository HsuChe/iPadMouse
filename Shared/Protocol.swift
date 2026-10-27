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
