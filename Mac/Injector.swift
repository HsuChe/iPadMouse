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
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }
}
