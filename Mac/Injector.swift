// Turns protocol packets into real macOS input using Quartz Event Services (CGEvent).
// Posting to the HID event tap needs the Accessibility permission, nothing else.

import AppKit
import CoreGraphics

final class Injector {
    /// Which display the iPad's surface is mapped onto in pen-tablet mode.
    var targetDisplay: CGDirectDisplayID = CGMainDisplayID()
    /// Fingers-down moves content down, like a Mac trackpad. Flip it from the menu if it feels wrong.
    var naturalScrolling = true

    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<UInt8>()
    private var buttonDownTime: [UInt8: TimeInterval] = [:]
    /// Games poll input once per frame; a press shorter than a frame can be missed entirely.
    private let minimumPress: TimeInterval = 0.03
    private var lastClickTime: [UInt8: TimeInterval] = [:]
    private var lastClickPoint = CGPoint.zero
    private var clickCount: [UInt8: Int64] = [:]

    var displaySize: CGSize { CGDisplayBounds(targetDisplay).size }
    var anyButtonDown: Bool { !buttonsDown.isEmpty }

    /// Safety: release every held button (link dropped mid-press, app quitting).
    func releaseAll() {
        for b in buttonsDown { post(button: b, down: false) }
        clearModifiers()
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Movement

    func moveAbsolute(nx: Float, ny: Float) {
        let b = CGDisplayBounds(targetDisplay)
        let p = CGPoint(x: b.minX + CGFloat(nx) * (b.width - 1),
                        y: b.minY + CGFloat(ny) * (b.height - 1))
        move(to: p)
    }

    func moveRelative(dx: CGFloat, dy: CGFloat) {
        let c = currentLocation()
        move(to: CGPoint(x: c.x + dx, y: c.y + dy))
    }

    /// While a button is held the system expects *Dragged events, not mouseMoved,
    /// otherwise drags and text selection silently stop working.
    private func move(to p: CGPoint) {
        var type = CGEventType.mouseMoved
        var button = CGMouseButton.left
        if buttonsDown.contains(MouseButton.left.rawValue) {
            type = .leftMouseDragged
        } else if buttonsDown.contains(MouseButton.right.rawValue) {
            type = .rightMouseDragged
            button = .right
        } else if let other = buttonsDown.first {
            type = .otherMouseDragged
            button = CGMouseButton(rawValue: UInt32(other)) ?? .center
        }
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    // MARK: Buttons

    func button(_ b: UInt8, down: Bool) {
        if !down, let since = buttonDownTime[b] {
            let held = ProcessInfo.processInfo.systemUptime - since
            if held < minimumPress {
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + (minimumPress - held)) {
                    self.post(button: b, down: false)
                }
                return
            }
        }
        post(button: b, down: down)
    }

    private func post(button b: UInt8, down: Bool) {
        let p = currentLocation()
        let type: CGEventType
        switch (b, down) {
        case (MouseButton.left.rawValue, true):   type = .leftMouseDown
        case (MouseButton.left.rawValue, false):  type = .leftMouseUp
        case (MouseButton.right.rawValue, true):  type = .rightMouseDown
        case (MouseButton.right.rawValue, false): type = .rightMouseUp
        case (_, true):                           type = .otherMouseDown
        case (_, false):                          type = .otherMouseUp
        }

        if down {
            // Double-click detection has to be done by us: the click count is a field on the event.
            let now = ProcessInfo.processInfo.systemUptime
            let recent = now - (lastClickTime[b] ?? -1000) < NSEvent.doubleClickInterval
            let near = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 8
            clickCount[b] = (recent && near) ? (clickCount[b] ?? 0) + 1 : 1
            lastClickTime[b] = now
            lastClickPoint = p
            buttonsDown.insert(b)
            buttonDownTime[b] = now
        } else {
            buttonsDown.remove(b)
            buttonDownTime[b] = nil
        }

        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: CGMouseButton(rawValue: UInt32(b)) ?? .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickCount[b] ?? 1)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Scrolling

    /// Pixel-precise scrolling with the same phase fields a real trackpad sends,
    /// so apps get smooth scrolling, rubber-banding and momentum.
    func scroll(dx: Float, dy: Float, phase: ScrollPhase) {
        let sign: Double = naturalScrolling ? 1 : -1
        let v = Double(dy) * sign
        let h = Double(dx) * sign
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(v.rounded()), wheel2: Int32(h.rounded()), wheel3: 0) else { return }
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: v)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: h)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        switch phase {
        case .began:           e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)   // kCGScrollPhaseBegan
        case .changed:         e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)   // kCGScrollPhaseChanged
        case .ended:           e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)   // kCGScrollPhaseEnded
        case .momentumBegan:   e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1) // kCGMomentumScrollPhaseBegin
        case .momentumChanged: e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) // kCGMomentumScrollPhaseContinue
        case .momentumEnded:   e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3) // kCGMomentumScrollPhaseEnd
        }
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keys

    func key(code: UInt16, modifiers: KeyModifiers) {
        // A plain F4 key code does nothing; the Launchpad key on Apple keyboards is a system-defined
        // media key (NX_KEYTYPE_LAUNCHPAD), so post that instead. On macOS 26 it opens the Apps view.
        if code == UInt16(KeyCode.f4), modifiers.isEmpty {
            postSystemKey(28)
            return
        }
        // Press each modifier as a real key, the way a keyboard does, then release it again. Putting the
        // modifier only in the arrow key's flags left macOS believing Control was still held, so every
        // later click became a Control-click and opened a context menu.
        let modifierKeys: [(KeyModifiers, CGKeyCode, CGEventFlags)] = [
            (.command, 55, .maskCommand), (.shift, 56, .maskShift),
            (.control, 59, .maskControl), (.option, 58, .maskAlternate),
        ]
        var flags = CGEventFlags()
        for (modifier, keyCode, flag) in modifierKeys where modifiers.contains(modifier) {
            flags.insert(flag)
            postModifier(keyCode, flags: flags)
        }
        var keyFlags = flags
        // Real arrow keys carry the fn and numeric-pad flags. Without them, macOS ignores a synthetic
        // Ctrl-arrow for its Space and Mission Control shortcuts.
        if (123...126).contains(code) { keyFlags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.flags = keyFlags
            e.post(tap: .cghidEventTap)
        }
        for (modifier, keyCode, flag) in modifierKeys.reversed() where modifiers.contains(modifier) {
            flags.remove(flag)
            postModifier(keyCode, flags: flags)
        }
        // Finish on a clean slate: this also drops the arrow key's fn and numeric-pad flags.
        if !keyFlags.isEmpty { clearModifiers() }
    }

    /// A modifier key going down or up is a flagsChanged event whose flags are the new state.
    private func postModifier(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    /// Tells macOS no modifier is held. Safe to call any time.
    func clearModifiers() {
        postModifier(63, flags: [])                 // fn key, released, with every flag cleared
    }

    /// Media and special keys (NX_KEYTYPE_*) travel as system-defined events, not keyboard events.
    private func postSystemKey(_ keyType: Int) {
        for down in [true, false] {
            let state = down ? 0xa : 0xb
            guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                             subtype: 8, data1: (keyType << 16) | (state << 8), data2: -1) else { continue }
            e.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
