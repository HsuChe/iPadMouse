// All input mapping lives here.
//
// Two modes, switchable from the HUD and remembered between launches:
//
// Desktop: Pencil hover moves, touch = left click (hold to drag), double-tap = right
//          click, squeeze = back (mouse 4), quick hard stab = back. Finger tap jumps the
//          pointer to that spot and left-clicks; 1 drag = trackpad move; 2 drag = scroll
//          with momentum; 2 tap = right click; 3 swipe = Spaces; pinch = Cmd +/-.
// League:  one-handed finger layout. Finger down/held = pointer follows the finger
//          (aim for skillshots, no click). Quick 1-finger tap = right click there (move).
//          2-finger tap = left click at the centroid (attack-move). 3-finger tap =
//          mouse 4 (summoner). 4-finger tap = mouse 5 (item). 2-finger drag still scrolls
//          (camera zoom). Pencil: hover aims, touch = left click, squeeze = mouse 4,
//          double-tap = mouse 5. Hard stab, 3-finger swipes and pinch are disabled.

import UIKit
import QuartzCore

enum PadMode: String {
    case desktop, league, training

    var title: String {
        switch self {
        case .desktop: return "Mode: Desktop"
        case .league: return "Mode: League"
        case .training: return "Mode: Training"
        }
    }

    var next: PadMode {
        switch self {
        case .desktop: return .league
        case .league: return .training
        case .training: return .desktop
        }
    }
}

final class TouchpadViewController: UIViewController {

    private var mode: PadMode = PadMode(rawValue: UserDefaults.standard.string(forKey: "padMode") ?? "") ?? .desktop {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "padMode")
            modeButton.setTitle(mode.title, for: .normal)
            applyModeGestures()
            refreshHUD()
        }
    }

    /// Size of the mapped area as a fraction of the largest letterboxed fit, and where it sits.
    /// Smaller areas let the fingers do the work without moving the arm.
    private static let areaScales: [CGFloat] = [1.0, 0.8, 0.65, 0.5, 0.4, 0.3]
    private static let anchorNames = ["Center", "Bottom right", "Bottom left", "Bottom center", "Right", "Left"]
    private var areaScaleIndex = UserDefaults.standard.integer(forKey: "areaScaleIndex") {
        didSet { UserDefaults.standard.set(areaScaleIndex, forKey: "areaScaleIndex"); updateActiveRect(); refreshAreaButtons() }
    }
    private var areaAnchor = UserDefaults.standard.integer(forKey: "areaAnchor") {
        didSet { UserDefaults.standard.set(areaAnchor, forKey: "areaAnchor"); updateActiveRect(); refreshAreaButtons() }
    }

    // MARK: Tunables
    private let trackpadSensitivity: CGFloat = 1.6
    private let scrollScale: CGFloat = 1.0
    /// Fraction of the Pencil's maximum force that counts as a "hard press".
    private let hardPressRatio: CGFloat = 0.5
    /// Hard press must happen within this window after touch-down; after that the touch is a normal click.
    private let hardPressWindow: TimeInterval = 0.12
    /// Pencil movement beyond this many points commits a left-click immediately (so drags feel instant).
    private let dragSlop: CGFloat = 4
    /// League: a one-finger touch shorter than this, with little movement, is a tap (move command).
    private let tapMaxDuration: TimeInterval = 0.25
    /// League: multi-finger taps may take a little longer since fingers land and lift unevenly.
    private let multiTapMaxDuration: TimeInterval = 0.35
    /// League: a finger that travels further than this is an aim-hold, not a tap.
    private let tapSlop: CGFloat = 12

    // MARK: Pieces
    private let link = Link()
    private let pad = TouchpadView()
    private let outline = UIView()
    private let hud = UILabel()
    private let dimButton = UIButton(type: .system)
    private let wiredButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let areaButton = UIButton(type: .system)
    private let anchorButton = UIButton(type: .system)
    private let trainer = TrainingView()
    private var pinch: UIPinchGestureRecognizer!
    /// Recognizers that only make sense in Desktop mode; League handles fingers itself.
    private var desktopRecognizers: [UIGestureRecognizer] = []

    // League finger gesture state
    private var leagueActive = Set<UITouch>()
    private var leaguePoints: [UITouch: CGPoint] = [:]
    private var leagueStart: TimeInterval = 0
    private var leagueStartPoint = CGPoint.zero
    private var leagueMaxFingers = 0
    private var leagueMoved = false

    // MARK: State
    private var macScreen = CGSize(width: 16, height: 10)
    private var activeRect = CGRect.zero
    private var status = "Starting…"
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
        pad.fingerHandler = { [weak self] touches, phase in self?.handleFingers(touches, phase) }
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

        trainer.frame = view.bounds
        trainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        trainer.isHidden = mode != .training
        view.addSubview(trainer)

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hud.textColor = UIColor(white: 0.45, alpha: 1)
        hud.textAlignment = .center
        hud.numberOfLines = 0
        hud.isUserInteractionEnabled = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)

        configure(dimButton, title: "Dim screen", action: #selector(toggleDim))
        configure(wiredButton, title: "Prefer USB: off", action: #selector(toggleWired))
        configure(modeButton, title: mode.title, action: #selector(toggleMode))
        configure(areaButton, title: "", action: #selector(cycleAreaScale))
        configure(anchorButton, title: "", action: #selector(cycleAnchor))
        refreshAreaButtons()

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.6),
            dimButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            dimButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            wiredButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            wiredButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            modeButton.topAnchor.constraint(equalTo: wiredButton.bottomAnchor, constant: 4),
            modeButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            areaButton.topAnchor.constraint(equalTo: modeButton.bottomAnchor, constant: 4),
            areaButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            anchorButton.topAnchor.constraint(equalTo: areaButton.bottomAnchor, constant: 4),
            anchorButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
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
        desktopRecognizers = [oneTap, twoTap, pan, pinch] + swipes
        for recognizer in desktopRecognizers {
            recognizer.allowedTouchTypes = fingerOnly
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            pad.addGestureRecognizer(recognizer)
        }
        applyModeGestures()
    }

    private func applyModeGestures() {
        let desktop = mode == .desktop
        for recognizer in desktopRecognizers { recognizer.isEnabled = desktop }
        leagueActive.removeAll()
        leaguePoints.removeAll()
        trainer.isHidden = mode != .training
        if mode != .training { trainer.stop() }
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
        let scale = Self.areaScales[min(max(areaScaleIndex, 0), Self.areaScales.count - 1)]
        w *= scale
        h *= scale
        let margin: CGFloat = 24
        let safe = view.safeAreaInsets
        let minX = margin + safe.left, maxX = b.width - margin - safe.right - w
        let minY = margin + safe.top + 100, maxY = b.height - margin - safe.bottom - h   // leave room for the HUD
        var origin = CGPoint(x: (b.width - w) / 2, y: (b.height - h) / 2)
        switch areaAnchor {
        case 1: origin = CGPoint(x: maxX, y: maxY)
        case 2: origin = CGPoint(x: minX, y: maxY)
        case 3: origin = CGPoint(x: (b.width - w) / 2, y: maxY)
        case 4: origin = CGPoint(x: maxX, y: (b.height - h) / 2)
        case 5: origin = CGPoint(x: minX, y: (b.height - h) / 2)
        default: break
        }
        origin.x = min(max(origin.x, minX), max(minX, maxX))
        origin.y = min(max(origin.y, min(minY, maxY)), max(minY, maxY))
        activeRect = CGRect(origin: origin, size: CGSize(width: w, height: h))
        outline.frame = activeRect
        trainer.playArea = activeRect
    }

    @objc private func cycleAreaScale() {
        areaScaleIndex = (areaScaleIndex + 1) % Self.areaScales.count
    }

    @objc private func cycleAnchor() {
        areaAnchor = (areaAnchor + 1) % Self.anchorNames.count
    }

    private func refreshAreaButtons() {
        let scale = Self.areaScales[min(max(areaScaleIndex, 0), Self.areaScales.count - 1)]
        areaButton.setTitle("Area: \(Int(scale * 100))%", for: .normal)
        anchorButton.setTitle("Anchor: \(Self.anchorNames[min(max(areaAnchor, 0), Self.anchorNames.count - 1)])", for: .normal)
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

    // MARK: Pencil

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard mode != .training, g.state == .began || g.state == .changed else { return }
        sendAbsolute(g.location(in: view))
    }

    private func handlePencil(_ touch: UITouch, _ phase: UITouch.Phase) {
        let p = touch.location(in: view)
        if mode == .training {
            if phase == .began { trainer.handle(.pencilTap(p)) }
            return
        }
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
            if mode == .desktop, !pencilDownSent, touch.maximumPossibleForce > 0,
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

    // MARK: League finger layout (raw touches)

    private func handleFingers(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        guard mode != .desktop else { return }
        switch phase {
        case .began:
            if leagueActive.isEmpty {
                leaguePoints.removeAll()
                leagueStart = CACurrentMediaTime()
                leagueMaxFingers = 0
                leagueMoved = false
                leagueStartPoint = touches.first?.location(in: view) ?? .zero
            }
            for t in touches {
                leagueActive.insert(t)
                leaguePoints[t] = t.location(in: view)
            }
            leagueMaxFingers = max(leagueMaxFingers, leagueActive.count)
            // A lone finger aims immediately: the pointer is where you touch.
            if leagueActive.count == 1, let t = touches.first {
                dispatch(.aim(t.location(in: view)))
            }

        case .moved:
            for t in touches where leagueActive.contains(t) {
                leaguePoints[t] = t.location(in: view)
            }
            if leagueActive.count == 1, let t = touches.first, leagueActive.contains(t) {
                let p = t.location(in: view)
                if hypot(p.x - leagueStartPoint.x, p.y - leagueStartPoint.y) > tapSlop {
                    leagueMoved = true
                }
                dispatch(.aim(p))
            }

        case .ended, .cancelled:
            for t in touches where leagueActive.contains(t) {
                leaguePoints[t] = t.location(in: view)
                leagueActive.remove(t)
            }
            guard leagueActive.isEmpty, !leaguePoints.isEmpty else { return }
            let duration = CACurrentMediaTime() - leagueStart
            let points = Array(leaguePoints.values)
            let fingers = leagueMaxFingers
            leaguePoints.removeAll()
            // The scroll view cancels our touches when a two-finger drag becomes a scroll.
            guard phase != .cancelled else { return }
            let limit = fingers == 1 ? tapMaxDuration : multiTapMaxDuration
            guard duration < limit, fingers > 1 || !leagueMoved else { return }
            dispatch(.tap(fingers: fingers, at: centroid(points)))

        default:
            break
        }
    }

    /// League sends gestures to the Mac; Training feeds them to the trainer instead.
    private func dispatch(_ gesture: FingerGesture) {
        if mode == .training {
            trainer.handle(gesture)
            return
        }
        switch gesture {
        case .aim(let p):
            sendAbsolute(p)
        case .tap(let fingers, let p):
            switch fingers {
            case 1: sendAbsolute(p); click(.right)      // move here
            case 2: sendAbsolute(p); click(.left)       // attack-move here
            case 3: click(.back)                        // mouse 4: summoner
            default: click(.forward)                    // mouse 5: item
            }
        case .pencilTap:
            break
        }
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    // MARK: Fingers (Desktop mode gesture recognizers)

    /// Finger taps are positional like the Pencil: jump the pointer there, then click.
    /// Desktop clicks with the left button; League right-clicks, which is "move here".
    @objc private func handleOneFingerTap(_ g: UITapGestureRecognizer) {
        sendAbsolute(g.location(in: view))
        click(mode == .league ? .right : .left)
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
        guard mode == .desktop, g.state == .changed else { return }
        if g.scale > 1.25 {
            key(KeyCode.equals, [.command])
            g.scale = 1
        } else if g.scale < 0.8 {
            key(KeyCode.minus, [.command])
            g.scale = 1
        }
    }

    @objc private func handleThreeFingerSwipe(_ g: UISwipeGestureRecognizer) {
        guard mode == .desktop else { return }
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
        modeButton.alpha = dimmed ? 0.02 : 1
        areaButton.alpha = dimmed ? 0.02 : 1
        anchorButton.alpha = dimmed ? 0.02 : 1
        dimButton.alpha = dimmed ? 0.1 : 1
    }

    @objc private func appWillResignActive() {
        if dimmed { screen.brightness = savedBrightness }
    }

    @objc private func appDidBecomeActive() {
        if dimmed { screen.brightness = 0 }
    }

    @objc private func toggleMode() {
        mode = mode.next
    }

    @objc private func toggleWired() {
        link.preferWired.toggle()
        wiredButton.setTitle("Prefer USB: \(link.preferWired ? "on" : "off")", for: .normal)
    }

    private func refreshHUD() {
        let hint: String
        switch mode {
        case .desktop:
            hint = "Pencil: hover moves · touch clicks · double-tap right-clicks · squeeze/stab = back\n" +
                   "Fingers: tap jumps + clicks · 1 drag moves · 2 drag scrolls · 2 tap right-clicks · 3 swipe Spaces · pinch zooms"
        case .league:
            hint = "Finger: hold = aim · tap = move · 2-tap = attack-move · 3-tap = summoner (M4) · 4-tap = item (M5) · 2 drag = zoom\n" +
                   "Pencil: hover aims · touch = attack-move · squeeze = M4 · double-tap = M5"
        case .training:
            hint = "Training: nothing is sent to the Mac. Pick a drill below, press Start, hit the prompts on the beat."
        }
        hud.text = (mode == .training ? "" : status + "\n") + hint
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
        click(mode == .league ? .forward : .right)
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
