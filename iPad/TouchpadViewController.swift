// All input mapping lives here.
//
// Pencil:  hover moves the pointer, touch = left click (hold to drag),
//          double-tap = right click, squeeze = back (mouse 4), a quick hard stab = back.
// Fingers: 1 drag = move (trackpad), 1 tap = left click, or right click while the
//          Pencil is in use; 2 drag = scroll with momentum; 2 tap = right click;
//          3 swipe = switch Spaces / Mission Control; pinch = Cmd +/- zoom.

import UIKit
import QuartzCore

final class TouchpadViewController: UIViewController {

    // MARK: Tunables
    private let trackpadSensitivity: CGFloat = 1.6
    private let scrollScale: CGFloat = 1.0
    /// Fraction of the Pencil's maximum force that counts as a "hard press".
    private let hardPressRatio: CGFloat = 0.5
    /// Hard press must happen within this window after touch-down; after that the touch is a normal click.
    private let hardPressWindow: TimeInterval = 0.12
    /// Pencil movement beyond this many points commits a left-click immediately (so drags feel instant).
    private let dragSlop: CGFloat = 4
    /// After the Pencil was seen, finger taps right-click for this long.
    private let pencilGrace: TimeInterval = 1.5

    // MARK: Pieces
    private let link = Link()
    private let pad = TouchpadView()
    private let outline = UIView()
    private let hud = UILabel()
    private let dimButton = UIButton(type: .system)
    private let wiredButton = UIButton(type: .system)
    private var pinch: UIPinchGestureRecognizer!

    // MARK: State
    private var macScreen = CGSize(width: 16, height: 10)
    private var activeRect = CGRect.zero
    private var status = "Starting…"
    private var pencilActiveUntil: TimeInterval = 0
    private var pencilTouch: UITouch?
    private var pencilDownSent = false
    private var pencilConsumed = false
    private var pencilStart = CGPoint.zero
    private var pencilDownWork: DispatchWorkItem?
    private var lastOffset = TouchpadView.center
    private var suppressScroll = false
    private var inMomentum = false
    private var dimmed = false
    private var savedBrightness: CGFloat = 0.5

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPad()
        setupOverlay()
        setupGestures()
        setupLink()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateActiveRect()
    }

    private func setupPad() {
        pad.frame = view.bounds
        pad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pad.delegate = self
        pad.pencilHandler = { [weak self] touch, phase in self?.handlePencil(touch, phase) }
        view.addSubview(pad)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        pad.addInteraction(pencil)
    }

    private func setupOverlay() {
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        outline.layer.borderWidth = 1
        view.addSubview(outline)

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hud.textColor = UIColor(white: 0.45, alpha: 1)
        hud.textAlignment = .center
        hud.numberOfLines = 0
        hud.isUserInteractionEnabled = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)

        configure(dimButton, title: "Dim screen", action: #selector(toggleDim))
        configure(wiredButton, title: "Prefer USB: off", action: #selector(toggleWired))

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.6),
            dimButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            dimButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            wiredButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            wiredButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
        ])
        refreshHUD()
    }

    private func configure(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        button.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
    }

    private func setupGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        pad.addGestureRecognizer(hover)

        let oneTap = UITapGestureRecognizer(target: self, action: #selector(handleOneFingerTap(_:)))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        self.pinch = pinch

        var swipes: [UISwipeGestureRecognizer] = []
        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipes.append(swipe)
        }

        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for recognizer in [oneTap, twoTap, pan, pinch] + swipes {
            recognizer.allowedTouchTypes = fingerOnly
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            pad.addGestureRecognizer(recognizer)
        }
    }

    private func setupLink() {
        link.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.status = text
                self?.refreshHUD()
            }
        }
        link.onConfig = { [weak self] size in
            DispatchQueue.main.async {
                guard let self, self.macScreen != size else { return }
                self.macScreen = size
                self.updateActiveRect()
            }
        }
        link.start()
    }

    // MARK: Mapping

    /// Letterbox the Mac display's aspect ratio inside the iPad screen so the pen mapping is not stretched.
    private func updateActiveRect() {
        let b = view.bounds
        guard b.width > 0, b.height > 0, macScreen.width > 0, macScreen.height > 0 else { return }
        let aspect = macScreen.width / macScreen.height
        var w = b.width
        var h = w / aspect
        if h > b.height {
            h = b.height
            w = h * aspect
        }
        activeRect = CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        outline.frame = activeRect
    }

    private func sendAbsolute(_ p: CGPoint) {
        guard activeRect.width > 0 else { return }
        let nx = min(max((p.x - activeRect.minX) / activeRect.width, 0), 1)
        let ny = min(max((p.y - activeRect.minY) / activeRect.height, 0), 1)
        link.send(Packet(kind: .moveAbsolute, x: Float(nx), y: Float(ny)))
    }

    private func click(_ button: MouseButton) {
        link.send(Packet(kind: .buttonDown, button: button.rawValue))
        link.send(Packet(kind: .buttonUp, button: button.rawValue))
    }

    private func key(_ code: UInt8, _ modifiers: KeyModifiers) {
        link.send(Packet(kind: .key, button: code, flags: modifiers.rawValue))
    }

    private var pencilActive: Bool { CACurrentMediaTime() < pencilActiveUntil }

    private func markPencilActive() {
        pencilActiveUntil = CACurrentMediaTime() + pencilGrace
    }

    // MARK: Pencil

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        markPencilActive()
        sendAbsolute(g.location(in: view))
    }

    private func handlePencil(_ touch: UITouch, _ phase: UITouch.Phase) {
        markPencilActive()
        let p = touch.location(in: view)
        switch phase {
        case .began:
            pencilTouch = touch
            pencilDownSent = false
            pencilConsumed = false
            pencilStart = p
            sendAbsolute(p)
            // Defer the left-click briefly so a hard stab can become "back" instead of a click.
            let work = DispatchWorkItem { [weak self] in self?.commitPencilDown() }
            pencilDownWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hardPressWindow, execute: work)

        case .moved:
            guard touch == pencilTouch, !pencilConsumed else { return }
            if !pencilDownSent, touch.maximumPossibleForce > 0,
               touch.force / touch.maximumPossibleForce >= hardPressRatio {
                pencilDownWork?.cancel()
                pencilConsumed = true
                click(.back)
                return
            }
            if !pencilDownSent, hypot(p.x - pencilStart.x, p.y - pencilStart.y) > dragSlop {
                commitPencilDown()
            }
            sendAbsolute(p)

        case .ended, .cancelled:
            guard touch == pencilTouch else { return }
            pencilDownWork?.cancel()
            if !pencilConsumed {
                if !pencilDownSent { commitPencilDown() }
                sendAbsolute(p)
                link.send(Packet(kind: .buttonUp, button: MouseButton.left.rawValue))
            }
            pencilTouch = nil

        default:
            break
        }
    }

    private func commitPencilDown() {
        guard pencilTouch != nil, !pencilDownSent, !pencilConsumed else { return }
        pencilDownSent = true
        link.send(Packet(kind: .buttonDown, button: MouseButton.left.rawValue))
    }

    // MARK: Fingers

    @objc private func handleOneFingerTap(_ g: UITapGestureRecognizer) {
        click(pencilActive ? .right : .left)
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        click(.right)
    }

    @objc private func handleOneFingerPan(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        link.send(Packet(kind: .moveRelative,
                         dx: Float(t.x * trackpadSensitivity),
                         dy: Float(t.y * trackpadSensitivity)))
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        if g.scale > 1.25 {
            key(KeyCode.equals, [.command])
            g.scale = 1
        } else if g.scale < 0.8 {
            key(KeyCode.minus, [.command])
            g.scale = 1
        }
    }

    @objc private func handleThreeFingerSwipe(_ g: UISwipeGestureRecognizer) {
        switch g.direction {
        case .left:  key(KeyCode.rightArrow, [.control])   // next Space
        case .right: key(KeyCode.leftArrow, [.control])    // previous Space
        case .up:    key(KeyCode.upArrow, [.control])      // Mission Control
        case .down:  key(KeyCode.downArrow, [.control])    // App Exposé
        default: break
        }
    }

    // MARK: Screen dimming

    private var screen: UIScreen {
        view.window?.windowScene?.screen ?? UIScreen.main
    }

    @objc private func toggleDim() {
        dimmed.toggle()
        applyDim()
    }

    private func applyDim() {
        if dimmed {
            savedBrightness = screen.brightness
            screen.brightness = 0
            dimButton.setTitle("tap here to restore brightness", for: .normal)
        } else {
            screen.brightness = savedBrightness
            dimButton.setTitle("Dim screen", for: .normal)
        }
        // Keep the restore button hit-testable (alpha must stay above 0.01).
        hud.alpha = dimmed ? 0 : 1
        outline.alpha = dimmed ? 0 : 1
        wiredButton.alpha = dimmed ? 0.02 : 1
        dimButton.alpha = dimmed ? 0.1 : 1
    }

    @objc private func appWillResignActive() {
        if dimmed { screen.brightness = savedBrightness }
    }

    @objc private func appDidBecomeActive() {
        if dimmed { screen.brightness = 0 }
    }

    @objc private func toggleWired() {
        link.preferWired.toggle()
        wiredButton.setTitle("Prefer USB: \(link.preferWired ? "on" : "off")", for: .normal)
    }

    private func refreshHUD() {
        hud.text = status + "\n" +
            "Pencil: hover moves · touch clicks · double-tap right-clicks · squeeze/stab = back\n" +
            "Fingers: 1 drag moves · 1 tap clicks · 2 drag scrolls · 2 tap right-clicks · 3 swipe Spaces · pinch zooms"
    }
}

// MARK: - Two-finger scrolling via the scroll view

extension TouchpadViewController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if inMomentum {
            inMomentum = false
            link.send(Packet(kind: .scroll, flags: ScrollPhase.momentumEnded.rawValue))
        }
        lastOffset = scrollView.contentOffset
        link.send(Packet(kind: .scroll, flags: ScrollPhase.began.rawValue))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !suppressScroll, scrollView.isDragging || scrollView.isDecelerating else { return }
        let d = CGPoint(x: scrollView.contentOffset.x - lastOffset.x, y: scrollView.contentOffset.y - lastOffset.y)
        lastOffset = scrollView.contentOffset
        guard d != .zero else { return }
        let phase: ScrollPhase = inMomentum ? .momentumChanged : .changed
        // Content offset moves opposite to the fingers; the protocol carries finger travel.
        link.send(Packet(kind: .scroll, flags: phase.rawValue,
                         dx: Float(-d.x * scrollScale), dy: Float(-d.y * scrollScale)))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        link.send(Packet(kind: .scroll, flags: ScrollPhase.ended.rawValue))
        if decelerate {
            inMomentum = true
            link.send(Packet(kind: .scroll, flags: ScrollPhase.momentumBegan.rawValue))
        } else {
            recenter()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if inMomentum {
            inMomentum = false
            link.send(Packet(kind: .scroll, flags: ScrollPhase.momentumEnded.rawValue))
        }
        recenter()
    }

    private func recenter() {
        suppressScroll = true
        pad.contentOffset = TouchpadView.center
        lastOffset = TouchpadView.center
        suppressScroll = false
    }
}

// MARK: - Pencil double-tap and squeeze

extension TouchpadViewController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        click(.right)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        click(.back)
    }
}

// MARK: - Gesture coexistence

extension TouchpadViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ a: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        // Let pinch run alongside the scroll view's two-finger pan.
        (a === pinch && b === pad.panGestureRecognizer) || (b === pinch && a === pad.panGestureRecognizer)
    }
}
