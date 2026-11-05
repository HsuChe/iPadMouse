// The black surface. It is a UIScrollView so two-finger scrolling gets UIKit's
// native deceleration for free; Pencil touches are forwarded raw to the controller.

import UIKit

final class TouchpadView: UIScrollView {
    static let center = CGPoint(x: 50_000, y: 50_000)

    var pencilHandler: ((UITouch, UITouch.Phase) -> Void)?
    /// Raw finger touches (used by League mode; Desktop mode uses gesture recognizers instead).
    var fingerHandler: ((Set<UITouch>, UITouch.Phase) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        contentSize = CGSize(width: 100_000, height: 100_000)
        contentOffset = Self.center
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = false
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.maximumNumberOfTouches = 2
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, .began)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The Pencil samples faster than the display refreshes; coalesced touches carry the in-between samples.
        for touch in touches where touch.type == .pencil {
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for sample in samples { pencilHandler?(sample, .moved) }
        }
        let fingers = touches.filter { $0.type == .direct }
        if !fingers.isEmpty { fingerHandler?(fingers, .moved) }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, .ended)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, .cancelled)
        super.touchesCancelled(touches, with: event)
    }

    private func forward(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        for touch in touches where touch.type == .pencil {
            pencilHandler?(touch, phase)
        }
        let fingers = touches.filter { $0.type == .direct }
        if !fingers.isEmpty {
            fingerHandler?(fingers, phase)
        }
    }
}
