// All input mapping lives here.
//
// Pencil first: while the Pencil hovers or touches (and for a moment after), every finger and palm
// touch is ignored. The rest of the time, fingers have the pad.
//
// Two modes, switchable from the HUD and remembered between launches:
//
// Desktop: Pencil hover moves, touch = left click (hold to drag), double-tap = right
//          click, squeeze = back (mouse 4), quick hard stab = back. Finger tap jumps the
//          pointer to that spot and left-clicks; 1 drag = trackpad move; 2 drag = scroll
//          with momentum; 2 tap = right click; 3 tap = Look up; 3 swipe = Spaces / Mission
//          Control / App Exposé; 4 spread = Show Desktop; 4 pinch = Launchpad; pinch = Cmd +/-.
//          Tap then drag = drag with the button held. Pointer gain follows a Mac-style
//          acceleration curve with a 1-10 tracking setting.
//          1 finger, or the Pencil while hovering, going round in circles = scroll wheel
//          (clockwise up, counterclockwise down).
//          Pencil hovering + squeeze held + move left/right = Space switch (no back click).
// League:  one-handed finger layout, trackpad style. 1-finger drag = move the pointer
//          (relative). Quick tap = right click (move command). Firm press without moving =
//          left click (attack-move / select). 2-finger tap = left click. 3-finger tap =
//          mouse 4 (summoner). 4-finger tap = mouse 5 (item). 2-finger drag scrolls (camera
//          zoom). Pencil: hover aims (absolute), tip tap = move, barrel double-tap =
//          attack-move, squeeze = mouse 4. Hard stab, 3-finger swipes and pinch are disabled.

import UIKit
import QuartzCore
import CoreImage

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
    /// League: a finger that travels further than this is a drag, not a tap or press.
    private let tapSlop: CGFloat = 12
    /// Firm press: the contact patch must grow by this factor (and at least this many points) over its size at touch-down.
    private let pressGrowthFactor: CGFloat = 1.35
    private let pressGrowthMinimum: CGFloat = 3
    /// Squeeze + hover swipe: horizontal Pencil travel (points, while hovering) that counts as a swipe.
    private let squeezeSwipeDistance: CGFloat = 80
    /// Tap, then touch down again within this long and move: drag with the left button held (Mac "tap and drag").
    private let tapDragWindow: TimeInterval = 0.35
    private let tapToDrag = false
    /// Four fingers spreading apart by this factor shows the desktop; pinching in to the inverse opens Launchpad.
    private let fourFingerSpreadFactor: CGFloat = 1.4
    /// Pointer acceleration, modelled on the Mac trackpad: slow movements are damped for precision, fast ones
    /// are amplified. These are the gain multipliers at rest and at full speed, and the speed (points per
    /// second on the iPad) at which the curve reaches the top. "Tracking" scales the whole curve.
    private let accelerationFloor: CGFloat = 0.9
    private let accelerationCeiling: CGFloat = 2.4
    private let accelerationFullSpeed: CGFloat = 1200
    /// Mac tracking speed slider: 1 (slow) to 10 (fast). 5 matches the old fixed gain.
    private var trackingSpeed = max(1, min(10, UserDefaults.standard.object(forKey: "trackingSpeed") as? Int ?? 5)) {
        didSet { UserDefaults.standard.set(trackingSpeed, forKey: "trackingSpeed"); refreshTrackingButton() }
    }
    private var accelerationEnabled = UserDefaults.standard.object(forKey: "accelerationEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(accelerationEnabled, forKey: "accelerationEnabled"); refreshTrackingButton() }
    }

    // MARK: Pieces
    private let link = Link()
    private let pad = TouchpadView()
    private let outline = UIView()
    private let hud = UILabel()
    private let dimButton = UIButton(type: .system)
    /// Lock: hides every iPad-side control so touches only ever drive the Mac. Hold to unlock.
    private let lockButton = UIButton(type: .system)
    private var locked = false
    private let unlockHold: TimeInterval = 1.0
    private let macsButton = UIButton(type: .system)
    private let wiredButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let areaButton = UIButton(type: .system)
    private let anchorButton = UIButton(type: .system)
    private let trackingButton = UIButton(type: .system)
    private let accelButton = UIButton(type: .system)
    private let trainer = TrainingView()
    private let setupCard = UIView()
    private let setupLabel = UILabel()
    private let setupQR = UIImageView()
    private var macsVisible = 0
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
    private var leagueLastPoint = CGPoint.zero
    private var leagueStartRadius: CGFloat = 0
    private var leaguePressFired = false

    // Circle scrolling (Desktop): one detector for the finger, one for the hovering Pencil.
    private var fingerCircle = CircleDetector()
    /// Off: the Mac log showed ordinary one-finger glides tripping the circle detector and freezing the
    /// pointer several times a minute. Two-finger scrolling covers the finger side.
    private let fingerCircleScroll = false
    /// Diagnostics carried on finger move packets: which stroke (one per pan), and the worst age of a touch
    /// sample when the app got to it (a stalled main thread shows up here).
    private var strokeID: UInt8 = 0
    private var worstTouchAge: TimeInterval = 0
    /// The Pencil never lifts during hover, so its wheel stops by itself once the circling stops.
    /// Stricter than the defaults: ordinary hovering around a target looped enough to trigger the default
    /// one-and-a-quarter turns, so the Pencil needs nearly two deliberate turns on a small circle.
    private var hoverCircle = CircleDetector(stopArc: 120, triggerAngle: .pi * 3.5, maxRadius: 90, window: 2.5)

    // Pencil Pro squeeze held while hovering + sideways Pencil move
    private var squeezeHeld = false
    private var squeezeSwipeFired = false
    private var squeezeStartX: CGFloat = 0

    // Desktop raw-touch bookkeeping: tap-and-drag, four-finger pinch/spread
    private var lastOneFingerTap: TimeInterval = -1000
    private var lastFingerDown: TimeInterval = -1000
    private var tapDragging = false
    private var desktopActive = Set<UITouch>()
    private var onePan: UIPanGestureRecognizer!
    // Three-finger swipe (Spaces, Mission Control, App Exposé)
    private var threeFingerActive = false
    private var threeFingerFired = false
    private var threeFingerStart = CGPoint.zero
    /// Centroid travel (points) that makes three fingers a swipe, and how much the main axis must dominate.
    private let threeFingerSwipeDistance: CGFloat = 70
    private let threeFingerAxisDominance: CGFloat = 1.3
    private var fourFingerStartSpread: CGFloat = 0
    private var fourFingerFired = false
    /// Last gesture the pad recognised, shown on the HUD so a gesture that "does nothing" can be diagnosed.
    private var lastGesture = "" {
        didSet { refreshHUD() }
    }

    // MARK: State
    private var macScreen = CGSize(width: 16, height: 10)
    private var activeRect = CGRect.zero
    private var status = "Starting…"
    private var pencilTouch: UITouch?
    private var pencilDownSent = false
    private var pencilConsumed = false
    private var pencilStart = CGPoint.zero
    private var pencilDownWork: DispatchWorkItem?
    /// Which button the current Pencil touch is holding (left on Desktop, right = move in League).
    private var pencilButton: MouseButton = .left
    private var lastPencilPoint = CGPoint.zero
    /// Tip double-tap (League): the second quick tap near the first becomes a left click (attack-move).
    private var lastPencilTapTime: TimeInterval = 0
    private var lastPencilTapPoint = CGPoint.zero
    private var pencilTapIsSecond = false
    private let pencilDoubleTapWindow: TimeInterval = 0.3
    private let pencilDoubleTapRadius: CGFloat = 30
    private var lastHoverSent: TimeInterval = 0
    // Pencil-first arbitration
    private var pencilHovering = false
    private var pencilContact = false
    private var pencilLastSeen: TimeInterval = -1000
    /// Fingers stay ignored this long after the Pencil leaves, so the palm lifting off doesn't click.
    private let pencilGrace: TimeInterval = 0.3
    /// Every finger currently on the glass, whoever owns it.
    private var fingersDown = Set<UITouch>()
    /// Set when the Pencil showed up while fingers were down (or fingers landed near the Pencil):
    /// those touches stay ignored until every finger has lifted.
    private var fingersIgnored = false
    private var pencilGraceWork: DispatchWorkItem?
    /// One "sequence" runs from the first finger landing to the last one lifting. A tap only counts when
    /// the sequence had exactly that many fingers and they landed together, so a resting thumb, a palm, or
    /// the fingers of a three-finger swipe can never produce a click.
    private var seqMaxFingers = 0
    private var seqFirstLand: TimeInterval = 0
    private var seqLastLand: TimeInterval = 0
    /// Contacts this big (UITouch.majorRadius, points) are a palm or the side of the hand, not a fingertip.
    /// Fingertips read about 10-30; a firm press can reach about 30. Palms read 40 and up.
    private let palmRadius: CGFloat = 40
    private var palmTouches = Set<UITouch>()
    /// Largest contact seen in the last sequence, shown on the HUD so the palm threshold can be tuned.
    private var seqMaxRadius: CGFloat = 0
    private var lastSeqMaxRadius: CGFloat = 0
    /// Longest gap between the first and last finger landing that still counts as a two- or three-finger tap.
    private let multiTapLandingSpread: TimeInterval = 0.08
    /// Keeps ProMotion at 120 Hz: input events are delivered in step with the display, and a static
    /// black screen would otherwise let the panel idle down to 24 Hz and starve the pointer stream.
    private var refreshLink: CADisplayLink?
    // Live rate readout (per second): display-link ticks, hover samples, finger moves.
    private var rateTicks = 0, rateHover = 0, rateFinger = 0
    private var rateWindowStart: TimeInterval = 0
    private var rateText = ""
    /// Hover samples arrive at up to 240 Hz; the Mac display only needs 120.
    private let hoverInterval: TimeInterval = 1.0 / 120.0
    private var lastOffset = TouchpadView.center
    private var suppressScroll = false
    private var inMomentum = false
    private var dimmed = false
    private var savedBrightness: CGFloat = 0.5

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    /// Turns off iPadOS's three-finger undo/redo/copy/paste gestures so three-finger swipes and taps reach us.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPad()
        setupOverlay()
        setupGestures()
        setupLink()
        let link = CADisplayLink(target: self, selector: #selector(refreshTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        refreshLink = link

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(guidedAccessChanged), name: UIAccessibility.guidedAccessStatusDidChangeNotification, object: nil)
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
        pad.fingerHandler = { [weak self] touches, phase in self?.arbitrateFingers(touches, phase) }
        pad.rejectsTouch = { [weak self] touch in self?.isPalm(touch) ?? false }
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

        setupSetupCard()

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hud.textColor = UIColor(white: 0.45, alpha: 1)
        hud.textAlignment = .center
        hud.numberOfLines = 0
        hud.isUserInteractionEnabled = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)

        configure(dimButton, title: "Dim screen", action: #selector(toggleDim))
        configure(macsButton, title: "Macs", action: #selector(chooseMac))
        setupLockButton()
        configure(wiredButton, title: "Prefer USB: \(link.preferWired ? "on" : "off")", action: #selector(toggleWired))
        configure(modeButton, title: mode.title, action: #selector(toggleMode))
        configure(areaButton, title: "", action: #selector(cycleAreaScale))
        configure(anchorButton, title: "", action: #selector(cycleAnchor))
        configure(trackingButton, title: "", action: #selector(cycleTracking))
        configure(accelButton, title: "", action: #selector(toggleAcceleration))
        refreshAreaButtons()
        refreshTrackingButton()

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            hud.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hud.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.6),
            dimButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            dimButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            macsButton.topAnchor.constraint(equalTo: dimButton.bottomAnchor, constant: 4),
            macsButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            lockButton.topAnchor.constraint(equalTo: macsButton.bottomAnchor, constant: 4),
            lockButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            wiredButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            wiredButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            modeButton.topAnchor.constraint(equalTo: wiredButton.bottomAnchor, constant: 4),
            modeButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            areaButton.topAnchor.constraint(equalTo: modeButton.bottomAnchor, constant: 4),
            areaButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            anchorButton.topAnchor.constraint(equalTo: areaButton.bottomAnchor, constant: 4),
            anchorButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            trackingButton.topAnchor.constraint(equalTo: anchorButton.bottomAnchor, constant: 4),
            trackingButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            accelButton.topAnchor.constraint(equalTo: trackingButton.bottomAnchor, constant: 4),
            accelButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
        ])
        refreshHUD()
    }

    /// Shown while no Mac is visible: the Mac side needs a one-time install, and this is how to get it.
    private func setupSetupCard() {
        setupCard.backgroundColor = UIColor(white: 0.1, alpha: 1)
        setupCard.layer.cornerRadius = 16
        setupCard.isUserInteractionEnabled = false
        setupCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(setupCard)

        setupLabel.font = .systemFont(ofSize: 16)
        setupLabel.textColor = UIColor(white: 0.85, alpha: 1)
        setupLabel.numberOfLines = 0
        setupLabel.textAlignment = .center
        setupLabel.text = "No Mac running iPad Mouse was found.\n\n" +
            "The Mac needs the companion app once; after that it starts at login and this iPad connects automatically.\n\n" +
            "Scan to download it. On first launch macOS will say it can't verify the app: open System Settings › Privacy & Security and click Open Anyway. " +
            "Then make sure the Mac and iPad share a Wi-Fi network or a USB-C cable."
        setupLabel.translatesAutoresizingMaskIntoConstraints = false
        setupCard.addSubview(setupLabel)

        setupQR.image = Self.qrImage(for: "https://github.com/HsuChe/iPadMouse/releases/latest")
        setupQR.contentMode = .scaleAspectFit
        setupQR.translatesAutoresizingMaskIntoConstraints = false
        setupCard.addSubview(setupQR)

        NSLayoutConstraint.activate([
            setupCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            setupCard.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            setupCard.widthAnchor.constraint(equalToConstant: 420),
            setupLabel.topAnchor.constraint(equalTo: setupCard.topAnchor, constant: 24),
            setupLabel.leadingAnchor.constraint(equalTo: setupCard.leadingAnchor, constant: 24),
            setupLabel.trailingAnchor.constraint(equalTo: setupCard.trailingAnchor, constant: -24),
            setupQR.topAnchor.constraint(equalTo: setupLabel.bottomAnchor, constant: 20),
            setupQR.centerXAnchor.constraint(equalTo: setupCard.centerXAnchor),
            setupQR.widthAnchor.constraint(equalToConstant: 180),
            setupQR.heightAnchor.constraint(equalToConstant: 180),
            setupQR.bottomAnchor.constraint(equalTo: setupCard.bottomAnchor, constant: -24),
        ])
        refreshSetupCard()
    }

    private func refreshSetupCard() {
        setupCard.isHidden = macsVisible > 0 || mode == .training || dimmed
    }

    private static func qrImage(for text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(text.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        // White modules on the dark card.
        let inverted = scaled.applyingFilter("CIColorInvert").applyingFilter("CIMaskToAlpha")
        return UIImage(ciImage: inverted)
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

        self.onePan = pan
        // Three-finger swipes are tracked from raw touches (handleDesktopRawTouches), not UISwipeGestureRecognizer:
        // fingers never land together, so the one-finger pan or the two-finger scroll always claimed the touches first.
        // Three-finger tap = Look up, like the Mac trackpad's "Look up & data detectors".
        let threeTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeTap.numberOfTouchesRequired = 3

        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        desktopRecognizers = [oneTap, twoTap, threeTap, pan, pinch]
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
        // Desktop tracks three-finger swipes from raw touches, so a two-finger scroll must not cancel them.
        // League relies on that cancellation to tell a two-finger drag from a two-finger tap.
        pad.panGestureRecognizer.cancelsTouchesInView = !desktop
        desktopActive.removeAll()
        threeFingerActive = false
        leagueActive.removeAll()
        leaguePoints.removeAll()
        trainer.isHidden = mode != .training
        if mode != .training { trainer.stop() }
        refreshSetupCard()
    }

    private func setupLink() {
        link.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.status = text
                self?.refreshHUD()
            }
        }
        link.onMacsChanged = { [weak self] macs in
            DispatchQueue.main.async {
                self?.macsButton.setTitle(macs.isEmpty ? "Macs (none)" : "Macs (\(macs.count))", for: .normal)
                self?.macsVisible = macs.count
                self?.refreshSetupCard()
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

    /// Holds the refresh rate and counts frames for the HUD readout.
    @objc private func refreshTick() {
        rateTicks += 1
        let now = CACurrentMediaTime()
        if rateWindowStart == 0 { rateWindowStart = now }
        if now - rateWindowStart >= 1 {
            rateText = "display \(rateTicks) Hz · hover \(rateHover)/s · finger \(rateFinger)/s"
            rateTicks = 0; rateHover = 0; rateFinger = 0
            rateWindowStart = now
            refreshHUD()
        }
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

    @objc private func cycleTracking() {
        trackingSpeed = trackingSpeed % 10 + 1
    }

    @objc private func toggleAcceleration() {
        accelerationEnabled.toggle()
    }

    private func refreshTrackingButton() {
        trackingButton.setTitle("Tracking: \(trackingSpeed)/10", for: .normal)
        accelButton.setTitle("Acceleration: \(accelerationEnabled ? "on" : "off")", for: .normal)
    }

    /// Mac-style pointer gain for a finger moving at `speed` points per second on the iPad.
    private func pointerGain(speed: CGFloat) -> CGFloat {
        // Tracking 1...10 spans roughly a quarter to twice the mid setting, like the Mac slider.
        let base = trackpadSensitivity * pow(2, CGFloat(trackingSpeed - 5) / 2.5)
        guard accelerationEnabled else { return base }
        let x = min(max(speed / accelerationFullSpeed, 0), 1)
        let s = x * x * (3 - 2 * x)                               // smoothstep
        return base * (accelerationFloor + (accelerationCeiling - accelerationFloor) * s)
    }

    private func refreshAreaButtons() {
        let scale = Self.areaScales[min(max(areaScaleIndex, 0), Self.areaScales.count - 1)]
        areaButton.setTitle("Area: \(Int(scale * 100))%", for: .normal)
        anchorButton.setTitle("Anchor: \(Self.anchorNames[min(max(areaAnchor, 0), Self.anchorNames.count - 1)])", for: .normal)
    }

    private let clockStart = CACurrentMediaTime()

    private func sendAbsolute(_ p: CGPoint) {
        guard activeRect.width > 0 else { return }
        let nx = min(max((p.x - activeRect.minX) / activeRect.width, 0), 1)
        let ny = min(max((p.y - activeRect.minY) / activeRect.height, 0), 1)
        // dx carries the send time (seconds since launch) so the Mac can measure delivery jitter.
        link.send(Packet(kind: .moveAbsolute, x: Float(nx), y: Float(ny), dx: Float(CACurrentMediaTime() - clockStart)))
    }

    private func click(_ button: MouseButton, _ source: ClickSource) {
        link.send(Packet(kind: .buttonDown, button: button.rawValue, flags: source.rawValue))
        link.send(Packet(kind: .buttonUp, button: button.rawValue))
    }

    private func key(_ code: UInt8, _ modifiers: KeyModifiers) {
        link.send(Packet(kind: .key, button: code, flags: modifiers.rawValue))
    }

    // MARK: Pencil

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed else {
            endCircle(&hoverCircle)                  // Pencil lifted away or touched down
            pencilHovering = false
            pencilPresenceChanged()
            return
        }
        if !pencilHovering {
            pencilHovering = true
            pencilPresenceChanged()
        }
        lastPencilPoint = g.location(in: view)
        rateHover += 1
        guard mode != .training else { trainer.cursor = lastPencilPoint; return }
        if squeezeHeld, mode == .desktop {
            // The pointer stays put while the squeeze is held; the Pencil's sideways travel picks the Space.
            checkSqueezeSwipe(at: lastPencilPoint)
            return
        }
        if mode == .desktop {
            if g.state == .began { hoverCircle.reset(at: lastPencilPoint) }
            sendCircle(hoverCircle.feed(lastPencilPoint), source: "Pencil")
            if hoverCircle.active { return }         // the pointer holds still while the wheel turns
        }
        let now = CACurrentMediaTime()
        // Samples arrive at about the same rate as the limit; demanding the full interval dropped every
        // other one (the Mac logged ~56/s). Anything past 60% of it goes out.
        guard now - lastHoverSent >= hoverInterval * 0.6 else { return }
        lastHoverSent = now
        sendAbsolute(lastPencilPoint)
    }

    private func handlePencil(_ touch: UITouch, _ phase: UITouch.Phase) {
        let p = touch.location(in: view)
        lastPencilPoint = p
        switch phase {
        case .began: pencilContact = true; pencilPresenceChanged()
        case .ended, .cancelled: pencilContact = false; pencilPresenceChanged()
        default: break
        }
        if mode == .training {
            if phase == .began {
                trainer.handle(.tap(fingers: registerPencilTap(at: p) ? 2 : 1, at: p))   // second tap = ATK prompt
            }
            return
        }
        switch phase {
        case .began:
            pencilTouch = touch
            pencilDownSent = false
            pencilConsumed = false
            pencilStart = p
            pencilTapIsSecond = mode == .league && registerPencilTap(at: p)
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
                click(.back, .pencilStab)
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
                link.send(Packet(kind: .buttonUp, button: pencilButton.rawValue))
            }
            pencilTouch = nil

        default:
            break
        }
    }

    /// Returns true when this tap is the second of a quick double-tap at roughly the same spot.
    private func registerPencilTap(at p: CGPoint) -> Bool {
        let now = CACurrentMediaTime()
        let isSecond = now - lastPencilTapTime < pencilDoubleTapWindow
            && hypot(p.x - lastPencilTapPoint.x, p.y - lastPencilTapPoint.y) < pencilDoubleTapRadius
        lastPencilTapTime = isSecond ? 0 : now
        lastPencilTapPoint = p
        return isSecond
    }

    private func commitPencilDown() {
        guard pencilTouch != nil, !pencilDownSent, !pencilConsumed else { return }
        pencilDownSent = true
        pencilButton = mode == .league ? (pencilTapIsSecond ? .left : .right) : .left
        link.send(Packet(kind: .buttonDown, button: pencilButton.rawValue, flags: ClickSource.pencilTip.rawValue))
    }

    // MARK: Pencil first, fingers otherwise

    /// True while the Pencil is hovering or touching, and for `pencilGrace` after it leaves.
    private var pencilOwnsPad: Bool {
        pencilHovering || pencilContact || CACurrentMediaTime() - pencilLastSeen < pencilGrace
    }

    private var fingersBlocked: Bool { pencilOwnsPad || fingersIgnored }

    private func pencilPresenceChanged() {
        if pencilHovering || pencilContact {
            pencilGraceWork?.cancel()
            pencilLastSeen = CACurrentMediaTime()
            if !fingersDown.isEmpty, !fingersIgnored {
                fingersIgnored = true
                cancelFingerInput()
            }
        } else {
            pencilLastSeen = CACurrentMediaTime()
            // Refresh the HUD once the grace period is over and the fingers have the pad again.
            let work = DispatchWorkItem { [weak self] in self?.refreshHUD() }
            pencilGraceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pencilGrace + 0.01, execute: work)
        }
        refreshHUD()
    }

    /// A touch is a palm once its contact patch has ever been palm-sized.
    func isPalm(_ touch: UITouch) -> Bool {
        palmTouches.contains(touch) || touch.majorRadius >= palmRadius
    }

    /// Raw finger touches pass through here first. Palms are dropped outright and never count as fingers.
    /// Touches that land while the Pencil owns the pad, or that were already down when it arrived, are
    /// dropped until every finger has lifted.
    private func arbitrateFingers(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        // Sort out palms first: a contact that grows to palm size mid-touch spoils the whole sequence,
        // because whatever it was already doing (a tap, a scroll) was the hand, not a finger.
        var fingers = Set<UITouch>()
        for t in touches {
            seqMaxRadius = max(seqMaxRadius, t.majorRadius)
            if isPalm(t) {
                if !palmTouches.contains(t) {
                    palmTouches.insert(t)
                    if fingersDown.contains(t) {
                        fingersDown.remove(t)
                        if !fingersIgnored { fingersIgnored = true; cancelFingerInput() }
                    }
                    lastGesture = "palm ignored (\(Int(t.majorRadius)) pt contact)"
                }
            } else {
                fingers.insert(t)
            }
        }
        if phase == .ended || phase == .cancelled { palmTouches.subtract(touches) }
        if phase == .moved {
            let now = CACurrentMediaTime()
            for t in touches { worstTouchAge = max(worstTouchAge, now - t.timestamp) }
        }

        switch phase {
        case .began where !fingers.isEmpty:
            let now = CACurrentMediaTime()
            if fingersDown.isEmpty {
                fingersIgnored = false
                seqMaxFingers = 0
                seqFirstLand = now
            }
            fingersDown.formUnion(fingers)
            seqMaxFingers = max(seqMaxFingers, fingersDown.count)
            seqLastLand = now
            if pencilOwnsPad, !fingersIgnored {
                fingersIgnored = true
                cancelFingerInput()
            }
        case .ended, .cancelled:
            fingersDown.subtract(touches)
            if fingersDown.isEmpty, palmTouches.isEmpty {
                lastSeqMaxRadius = seqMaxRadius
                seqMaxRadius = 0
                refreshHUD()
            }
        default:
            break
        }
        if fingersIgnored {
            if fingersDown.isEmpty { fingersIgnored = false; refreshHUD() }
            return
        }
        guard !fingers.isEmpty else { return }
        handleFingers(fingers, phase)
    }

    /// Abandons whatever the fingers were doing: no click, drag, scroll or swipe survives.
    private func cancelFingerInput() {
        for r in desktopRecognizers + [pad.panGestureRecognizer] where r.isEnabled {
            r.isEnabled = false                     // toggling cancels any in-flight recognition
            r.isEnabled = true
        }
        stopScrollMomentum()
        endCircle(&fingerCircle)
        if tapDragging {
            tapDragging = false
            link.send(Packet(kind: .buttonUp, button: MouseButton.left.rawValue))
        }
        desktopActive.removeAll()
        threeFingerActive = false
        fourFingerStartSpread = 0
        leagueActive.removeAll()
        leaguePoints.removeAll()
        refreshHUD()
    }

    private func stopScrollMomentum() {
        pad.setContentOffset(pad.contentOffset, animated: false)
        if inMomentum {
            inMomentum = false
            link.send(Packet(kind: .scroll, flags: ScrollPhase.momentumEnded.rawValue))
        }
    }

    // MARK: League finger layout (raw touches)

    private func handleFingers(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        guard mode != .desktop else { handleDesktopRawTouches(touches, phase); return }
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
            if leagueActive.count == 1, let t = touches.first {
                leagueLastPoint = t.location(in: view)
                leagueStartRadius = t.majorRadius
                leaguePressFired = false
            }

        case .moved:
            rateFinger += 1
            for t in touches where leagueActive.contains(t) {
                leaguePoints[t] = t.location(in: view)
            }
            if leagueActive.count == 1, let t = touches.first, leagueActive.contains(t) {
                let p = t.location(in: view)
                if hypot(p.x - leagueStartPoint.x, p.y - leagueStartPoint.y) > tapSlop {
                    leagueMoved = true
                }
                // Firm press: finger has not travelled, but the contact patch grew noticeably.
                if !leagueMoved, !leaguePressFired, leagueStartRadius > 0,
                   t.majorRadius >= max(leagueStartRadius * pressGrowthFactor, leagueStartRadius + pressGrowthMinimum) {
                    leaguePressFired = true
                    dispatch(.press(at: p))
                }
                let d = CGPoint(x: p.x - leagueLastPoint.x, y: p.y - leagueLastPoint.y)
                leagueLastPoint = p
                if leagueMoved, d != .zero {
                    dispatch(.move(dx: d.x * trackpadSensitivity, dy: d.y * trackpadSensitivity))
                }
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
            guard duration < limit, fingers > 1 || (!leagueMoved && !leaguePressFired) else { return }
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
        case .move(let dx, let dy):
            link.send(Packet(kind: .moveRelative, dx: Float(dx), dy: Float(dy)))
        case .press:
            click(.left, .leaguePress)                  // attack-move / select at the pointer
        case .tap(let fingers, _):
            switch fingers {
            case 1: click(.right, .leagueTap)           // move command at the pointer
            case 2: click(.left, .leagueTap)            // attack-move at the pointer
            case 3: click(.back, .leagueTap)            // mouse 4: summoner
            default: click(.forward, .leagueTap)        // mouse 5: item
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

    /// Raw touches in Desktop mode: timing for tap-and-drag, and the four-finger pinch/spread that the
    /// two-touch pinch recognizer cannot see.
    private func handleDesktopRawTouches(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        switch phase {
        case .began:
            if desktopActive.isEmpty {
                lastFingerDown = CACurrentMediaTime()
                threeFingerActive = false
                threeFingerFired = false
            }
            desktopActive.formUnion(touches)
            if desktopActive.count == 3, !threeFingerActive { beginThreeFinger() }
            if desktopActive.count == 4 {
                fourFingerStartSpread = spread(of: desktopActive)
                fourFingerFired = false
            }
        case .moved:
            if threeFingerActive, desktopActive.count == 3 { trackThreeFinger() }
            guard desktopActive.count == 4, !fourFingerFired, fourFingerStartSpread > 0 else { return }
            let ratio = spread(of: desktopActive) / fourFingerStartSpread
            if ratio >= fourFingerSpreadFactor {
                fourFingerFired = true
                lastGesture = "4-finger spread: show desktop"
                key(KeyCode.f11, [])
            } else if ratio <= 1 / fourFingerSpreadFactor {
                fourFingerFired = true
                lastGesture = "4-finger pinch: Launchpad"
                key(KeyCode.f4, [])
            }
        case .ended, .cancelled:
            desktopActive.subtract(touches)
            if desktopActive.isEmpty { fourFingerStartSpread = 0 }
        default:
            break
        }
    }

    /// Three fingers are down: stop the pointer and any scroll, and start measuring the swipe from here.
    private func beginThreeFinger() {
        threeFingerActive = true
        threeFingerFired = false
        threeFingerStart = centroid(desktopActive.map { $0.location(in: view) })
        // Toggling a recognizer off and on cancels whatever it was doing with these touches.
        for r in [onePan!, pad.panGestureRecognizer] where r.state == .began || r.state == .changed {
            r.isEnabled = false
            r.isEnabled = true
        }
        pad.setContentOffset(pad.contentOffset, animated: false)   // kill any scroll momentum
        lastGesture = "3 fingers down"
    }

    /// One Space per swipe, like the trackpad: fires once, then waits for the fingers to lift.
    private func trackThreeFinger() {
        guard !threeFingerFired else { return }
        let c = centroid(desktopActive.map { $0.location(in: view) })
        let dx = c.x - threeFingerStart.x, dy = c.y - threeFingerStart.y
        if abs(dx) >= threeFingerSwipeDistance, abs(dx) >= abs(dy) * threeFingerAxisDominance {
            threeFingerFired = true
            if dx < 0 {
                lastGesture = "3-finger swipe left: next Space"; key(KeyCode.rightArrow, [.control])
            } else {
                lastGesture = "3-finger swipe right: previous Space"; key(KeyCode.leftArrow, [.control])
            }
        } else if abs(dy) >= threeFingerSwipeDistance, abs(dy) >= abs(dx) * threeFingerAxisDominance {
            threeFingerFired = true
            if dy < 0 {
                lastGesture = "3-finger swipe up: Mission Control"; key(KeyCode.upArrow, [.control])
            } else {
                lastGesture = "3-finger swipe down: App Exposé"; key(KeyCode.downArrow, [.control])
            }
        }
    }

    /// Mean distance of the touches from their centroid.
    private func spread(of touches: Set<UITouch>) -> CGFloat {
        let points = touches.map { $0.location(in: view) }
        let c = centroid(points)
        return points.reduce(0) { $0 + hypot($1.x - c.x, $1.y - c.y) } / CGFloat(max(points.count, 1))
    }

    /// Fingers are a trackpad: a tap clicks wherever the pointer already is.
    /// Whether this sequence really was an N-finger tap: exactly N fingers, all landing together.
    private func sequenceIsTap(fingers: Int, name: String) -> Bool {
        guard seqMaxFingers == fingers else {
            lastGesture = "\(name) ignored: \(seqMaxFingers) fingers touched"
            return false
        }
        let spread = seqLastLand - seqFirstLand
        guard fingers == 1 || spread <= multiTapLandingSpread else {
            lastGesture = "\(name) ignored: fingers landed \(Int(spread * 1000)) ms apart"
            return false
        }
        return true
    }

    @objc private func handleOneFingerTap(_ g: UITapGestureRecognizer) {
        guard sequenceIsTap(fingers: 1, name: "tap") else { return }
        lastOneFingerTap = CACurrentMediaTime()
        lastGesture = "1-finger tap: click"
        click(.left, .fingerTap)
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard sequenceIsTap(fingers: 2, name: "2-finger tap") else { return }
        lastGesture = "2-finger tap: right click"
        click(.right, .twoFingerTap)
    }

    @objc private func handleThreeFingerTap(_ g: UITapGestureRecognizer) {
        guard !threeFingerFired, sequenceIsTap(fingers: 3, name: "3-finger tap") else { return }
        lastGesture = "3-finger tap: look up"
        key(KeyCode.d, [.control, .command])
    }

    @objc private func handleOneFingerPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: view)
        switch g.state {
        case .began:
            fingerCircle.reset(at: p)
            strokeID &+= 1
            // Tap, then straight back down and move: hold the button so the pointer drags (Mac "tap and drag").
            // Off by default, as on the Mac: tapping and then gliding away sent a second click, which macOS
            // read as a double-click.
            tapDragging = tapToDrag && lastFingerDown - lastOneFingerTap < tapDragWindow && lastFingerDown >= lastOneFingerTap
            if tapDragging {
                lastGesture = "tap and drag"
                link.send(Packet(kind: .buttonDown, button: MouseButton.left.rawValue, flags: ClickSource.tapDrag.rawValue))
            }

        case .changed:
            rateFinger += 1
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            guard !threeFingerActive else { return }
            if !tapDragging {
                if fingerCircleScroll { sendCircle(fingerCircle.feed(p), source: "finger") }
                if fingerCircle.active { return }
            }
            let v = g.velocity(in: view)
            let gain = pointerGain(speed: hypot(v.x, v.y))
            // button = stroke, x = send time, y = worst touch age (ms) since the last packet.
            link.send(Packet(kind: .moveRelative, button: strokeID,
                             x: Float(CACurrentMediaTime() - clockStart), y: Float(worstTouchAge * 1000),
                             dx: Float(t.x * gain), dy: Float(t.y * gain)))
            worstTouchAge = 0

        case .ended, .cancelled, .failed:
            endCircle(&fingerCircle)
            if tapDragging {
                tapDragging = false
                link.send(Packet(kind: .buttonUp, button: MouseButton.left.rawValue))
            }

        default:
            break
        }
    }

    // MARK: Circle scrolling

    /// Turns detector events into scroll packets. Clockwise scrolls up, counterclockwise scrolls down.
    private func sendCircle(_ events: [CircleDetector.Event], source: String) {
        for event in events {
            switch event {
            case .began(let clockwise):
                lastGesture = "\(source) circle \(clockwise ? "clockwise: scroll up" : "counterclockwise: scroll down")"
                // button tags the start for the Mac log: 1 = finger circle, 2 = Pencil circle.
                link.send(Packet(kind: .scroll, button: source == "finger" ? 1 : 2, flags: ScrollPhase.began.rawValue))
            case .scroll(let dy):
                link.send(Packet(kind: .scroll, flags: ScrollPhase.changed.rawValue, dx: 0, dy: Float(dy)))
            case .stopped:
                lastGesture = "\(source) circle stopped"
                link.send(Packet(kind: .scroll, flags: ScrollPhase.ended.rawValue))
            }
        }
    }

    private func endCircle(_ detector: inout CircleDetector) {
        if detector.active { link.send(Packet(kind: .scroll, flags: ScrollPhase.ended.rawValue)) }
        detector.reset(at: .zero)
    }

    // MARK: Squeeze + swipe

    /// With the Pencil Pro squeezed while hovering, moving it left or right changes Space. Fires once per squeeze.
    private func checkSqueezeSwipe(at p: CGPoint) {
        let travel = p.x - squeezeStartX
        guard !squeezeSwipeFired, abs(travel) >= squeezeSwipeDistance else { return }
        squeezeSwipeFired = true
        if travel < 0 {
            lastGesture = "squeeze + swipe left: next Space"
            key(KeyCode.rightArrow, [.control])
        } else {
            lastGesture = "squeeze + swipe right: previous Space"
            key(KeyCode.leftArrow, [.control])
        }
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

    // MARK: Lock

    private func setupLockButton() {
        lockButton.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        lockButton.setTitleColor(UIColor(white: 0.5, alpha: 1), for: .normal)
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lockButton)
        // Tap locks. Unlocking needs a deliberate hold, so a stray swipe across the corner can't undo it.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(lockHeld(_:)))
        hold.minimumPressDuration = unlockHold
        let tap = UITapGestureRecognizer(target: self, action: #selector(lockTapped))
        tap.require(toFail: hold)
        lockButton.addGestureRecognizer(hold)
        lockButton.addGestureRecognizer(tap)
        refreshLock()
    }

    @objc private func lockTapped() {
        if locked {
            lastGesture = "locked: hold the Unlock button for 1 s"
            return
        }
        setLocked(true)
    }

    @objc private func lockHeld(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, locked else { return }
        setLocked(false)
    }

    private func setLocked(_ on: Bool) {
        locked = on
        refreshLock()
        if on {
            // Only a supervised (MDM-managed) iPad lets an app start Guided Access itself; on a personal
            // iPad this fails quietly and the HUD explains the triple-click instead.
            UIAccessibility.requestGuidedAccessSession(enabled: true) { [weak self] ok in
                DispatchQueue.main.async {
                    self?.lastGesture = ok ? "locked, Guided Access on" : "locked"
                }
            }
        } else {
            if UIAccessibility.isGuidedAccessEnabled {
                UIAccessibility.requestGuidedAccessSession(enabled: false) { _ in }
            }
            lastGesture = "unlocked"
        }
    }

    @objc private func guidedAccessChanged() {
        // Starting Guided Access by triple-click also locks the app's own controls.
        if UIAccessibility.isGuidedAccessEnabled, !locked { setLocked(true) }
        refreshHUD()
    }

    private var lockHint: String {
        UIAccessibility.isGuidedAccessEnabled
            ? "LOCKED · iPadOS swipes blocked by Guided Access (triple-click the top button to end it)"
            : "LOCKED · app controls hidden. To also block iPadOS swipes (Home, Control Center, app switcher), " +
              "triple-click the top button to start Guided Access. First time: Settings › Accessibility › Guided Access › on."
    }

    /// Every iPad-side control disappears while locked; only Dim and Unlock remain.
    private func refreshLock() {
        lockButton.setTitle(locked ? "Unlock (hold 1 s)" : "Lock iPad", for: .normal)
        lockButton.setTitleColor(locked ? UIColor(red: 1, green: 0.6, blue: 0.2, alpha: 1) : UIColor(white: 0.5, alpha: 1), for: .normal)
        for b in [macsButton, wiredButton, modeButton, areaButton, anchorButton, trackingButton, accelButton] {
            b.isHidden = locked
        }
        trainer.isUserInteractionEnabled = !locked
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        refreshHUD()
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
        trackingButton.alpha = dimmed ? 0.02 : 1
        accelButton.alpha = dimmed ? 0.02 : 1
        dimButton.alpha = dimmed ? 0.1 : 1
        macsButton.alpha = dimmed ? 0.02 : 1
        lockButton.alpha = dimmed ? 0.02 : 1
        refreshSetupCard()
    }

    @objc private func appWillResignActive() {
        if dimmed { screen.brightness = savedBrightness }
        // Never leave a button held on the Mac when the app goes to the background.
        if pencilDownSent, !pencilConsumed {
            link.send(Packet(kind: .buttonUp, button: pencilButton.rawValue))
        }
        pencilDownWork?.cancel()
        pencilTouch = nil
        pencilDownSent = false
        squeezeHeld = false
        squeezeSwipeFired = false
        endCircle(&fingerCircle)
        endCircle(&hoverCircle)
        leagueActive.removeAll()
        leaguePoints.removeAll()
    }

    @objc private func appDidBecomeActive() {
        if dimmed { screen.brightness = 0 }
    }

    @objc private func toggleMode() {
        mode = mode.next
    }

    @objc private func chooseMac() {
        let sheet = UIAlertController(title: "Connect to", message: link.availableMacs.isEmpty ? "No Mac running iPad Mouse was found." : nil, preferredStyle: .actionSheet)
        for name in link.availableMacs {
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                self?.link.connect(toMacNamed: name)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = macsButton
        sheet.popoverPresentationController?.sourceRect = macsButton.bounds
        present(sheet, animated: true)
    }

    @objc private func toggleWired() {
        link.preferWired.toggle()
        wiredButton.setTitle("Prefer USB: \(link.preferWired ? "on" : "off")", for: .normal)
    }

    private func refreshHUD() {
        let hint: String
        switch mode {
        case .desktop:
            hint = "Pencil: hover moves · touch clicks · double-tap right-clicks · squeeze/stab = back · hover + squeeze + move left/right = Spaces · hover in circles scrolls\n" +
                   "Fingers: 1 drag moves · 1 tap clicks\n" +
                   "2 drag scrolls · 2 tap right-clicks · 3 tap looks up · 3 swipe Spaces/Mission Control/Exposé\n" +
                   "4 spread = desktop · 4 pinch = Launchpad · pinch zooms"
        case .league:
            hint = "Finger: drag = move pointer · tap = move cmd · firm press = attack/select · 2-tap = attack · 3-tap = summoner (M4) · 4-tap = item (M5)\n" +
                   "Pencil: hover aims · tip tap = move · tip double-tap = attack-move · squeeze = M4"
        case .training:
            hint = "Training: nothing is sent to the Mac. Chase = kite a live enemy; the others are beat drills. Pick one below and press Start."
        }
        hud.text = (mode == .training ? "" : status + "\n") + (locked ? lockHint + "\n" : "") + hint
            + (rateText.isEmpty ? "" : "\n" + rateText)
            + "\ninput: " + (pencilOwnsPad ? "Pencil (fingers ignored)" : "fingers")
            + (lastSeqMaxRadius > 0 ? " · largest contact \(Int(lastSeqMaxRadius)) pt (palm ≥ \(Int(palmRadius)))" : "")
            + (mode == .desktop && !lastGesture.isEmpty ? " · last gesture: " + lastGesture : "")
    }
}

// MARK: - Two-finger scrolling via the scroll view

extension TouchpadViewController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if threeFingerActive || fingersBlocked {
            // Two of the three swipe fingers started a scroll; cancel it before it sends anything.
            pad.panGestureRecognizer.isEnabled = false
            pad.panGestureRecognizer.isEnabled = true
            return
        }
        if inMomentum {
            inMomentum = false
            link.send(Packet(kind: .scroll, flags: ScrollPhase.momentumEnded.rawValue))
        }
        lastOffset = scrollView.contentOffset
        link.send(Packet(kind: .scroll, flags: ScrollPhase.began.rawValue))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !suppressScroll, !threeFingerActive, !(fingersBlocked && scrollView.isDragging), scrollView.isDragging || scrollView.isDecelerating else { return }
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
        // Respect Settings › Apple Pencil › Double-tap: "Off" means the user doesn't want barrel taps at all.
        guard UIPencilInteraction.preferredTapAction != .ignore else {
            lastGesture = "Pencil double-tap ignored (turned off in Settings)"
            return
        }
        switch mode {
        case .desktop:
            lastGesture = "Pencil barrel double-tap: right click"
            click(.right, .pencilBarrel)
        case .league: click(.left, .pencilBarrel)                                // attack-move at the pointer
        case .training: trainer.handle(.tap(fingers: 2, at: lastPencilPoint))     // ATK prompt
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        // Where the Pencil is hovering, when the system reports it; otherwise the last hover sample.
        let hoverPoint = squeeze.hoverPose.map { interaction.view?.convert($0.location, to: view) ?? $0.location }
        switch squeeze.phase {
        case .began:
            squeezeHeld = true
            squeezeSwipeFired = false
            squeezeStartX = (hoverPoint ?? lastPencilPoint).x
            lastGesture = "squeeze held" + (hoverPoint == nil ? " (not hovering)" : ", move left/right to switch Space")
            return
        case .changed:
            if mode == .desktop, let hoverPoint { checkSqueezeSwipe(at: hoverPoint) }
            return
        case .cancelled:
            squeezeHeld = false
            return
        case .ended:
            if squeezeHeld, mode == .desktop, let hoverPoint { checkSqueezeSwipe(at: hoverPoint) }
            let swiped = squeezeHeld && squeezeSwipeFired
            squeezeHeld = false
            squeezeSwipeFired = false
            // A sideways swipe during the squeeze already did its job; don't also send "back".
            if swiped { return }
            lastGesture = "squeeze: back"
        default:
            return
        }
        if mode == .training {
            trainer.handle(.tap(fingers: 3, at: lastPencilPoint))                 // SUMM prompt
        } else {
            click(.back, .pencilSqueeze)
        }
    }
}

// MARK: - Gesture coexistence

extension TouchpadViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Palms never tap, pan, pinch or swipe.
        !(touch.type == .direct && isPalm(touch))
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // Fingers never start anything while the Pencil owns the pad.
        if fingersBlocked, desktopRecognizers.contains(where: { $0 === g }) { return false }
        // Nothing else starts while three fingers are swiping.
        return !(threeFingerActive && mode == .desktop && (g === onePan || g === pinch))
    }

    func gestureRecognizer(_ a: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        // Let pinch run alongside the scroll view's two-finger pan.
        (a === pinch && b === pad.panGestureRecognizer) || (b === pinch && a === pad.panGestureRecognizer)
    }
}

// MARK: - Circle scrolling detector

/// Detects a finger or a hovering Pencil going round in circles and turns it into a scroll wheel,
/// like an iPod click wheel. Feed it every sample; it reports when the wheel starts, how far to scroll,
/// and (if `stopArc` is set) when the circling has stopped.
struct CircleDetector {
    enum Event { case began(clockwise: Bool), scroll(dy: CGFloat), stopped }

    /// Turn (radians, one direction) before the wheel starts, and the smallest circle that counts,
    /// so jitter on a straight drag never triggers it.
    var triggerAngle: CGFloat = .pi * 1.25
    var minRadius: CGFloat = 15
    /// ...and no bigger than this, so a long gently curving stroke never adds up to a "circle".
    var maxRadius: CGFloat = 150
    /// The whole trigger turn must happen within this long; older turning is forgotten.
    var window: TimeInterval = 2.0
    private var accumulationStart: TimeInterval = 0
    /// The turn is measured between chords this long. Shorter chords are too noisy to carry a direction.
    var minStep: CGFloat = 8
    /// Turning the other way by this much means a real change of direction, not a wobble.
    var reversal: CGFloat = 0.6
    /// Scroll travel per point of travel around the circle.
    var gain: CGFloat = 0.6
    /// While the wheel turns: if the last `stopArc` points of travel turned less than `stopTurn`,
    /// the circling has stopped. 0 means only lifting ends it.
    var stopArc: CGFloat = 0
    var stopTurn: CGFloat = 0.6

    private(set) var active = false
    private var prev = CGPoint.zero
    private var prevVector = CGPoint.zero
    /// Accumulated signed turning; positive is clockwise as seen on the screen.
    private var turn: CGFloat = 0
    private var opposite: CGFloat = 0
    private var arc: CGFloat = 0
    /// Smoothed direction while active, so one straight-ish sample keeps the last direction.
    private var direction: CGFloat = 0
    private var windowTurn: CGFloat = 0
    private var windowArc: CGFloat = 0

    init(stopArc: CGFloat = 0, triggerAngle: CGFloat = .pi * 1.25, maxRadius: CGFloat = 150, window: TimeInterval = 2.0) {
        self.stopArc = stopArc
        self.triggerAngle = triggerAngle
        self.maxRadius = maxRadius
        self.window = window
    }

    mutating func reset(at p: CGPoint) {
        active = false
        prev = p
        prevVector = .zero
        turn = 0; opposite = 0; arc = 0; direction = 0
        windowTurn = 0; windowArc = 0
    }

    mutating func feed(_ p: CGPoint, at now: TimeInterval = CACurrentMediaTime()) -> [Event] {
        let v = CGPoint(x: p.x - prev.x, y: p.y - prev.y)
        let distance = hypot(v.x, v.y)
        guard distance >= minStep else { return [] }
        prev = p
        let previous = prevVector
        prevVector = v
        guard previous != .zero else { return [] }
        // Signed angle between the last two chords; with y pointing down, positive is clockwise.
        let t = atan2(previous.x * v.y - previous.y * v.x, previous.x * v.x + previous.y * v.y)

        if active {
            if stopArc > 0 {
                windowTurn += t
                windowArc += distance
                if windowArc >= stopArc {
                    if abs(windowTurn) < stopTurn {
                        reset(at: p)
                        return [.stopped]
                    }
                    windowTurn = 0
                    windowArc = 0
                }
            }
            return [.scroll(dy: scrollAmount(t, distance))]
        }

        // A circle bends gradually (under about half a radian per chord at the smallest radius). A sharper
        // bend is a corner where the stroke changed direction, not part of a circle: start the count over.
        if abs(t) > 0.9 {
            turn = 0; opposite = 0; arc = 0
            return []
        }
        // A sustained turn the other way starts the count over; a single wobbly sample does not.
        if turn != 0, (t > 0) != (turn > 0) {
            opposite += abs(t)
            if opposite >= reversal { turn = 0; opposite = 0; arc = 0 }
        } else {
            opposite = 0
        }
        if turn == 0 || now - accumulationStart > window {
            turn = 0; opposite = 0; arc = 0
            accumulationStart = now
        }
        turn += t
        arc += distance
        let radius = arc / max(abs(turn), 0.001)
        guard abs(turn) >= triggerAngle, radius >= minRadius, radius <= maxRadius else { return [] }
        active = true
        direction = turn > 0 ? 1 : -1
        windowTurn = 0
        windowArc = 0
        return [.began(clockwise: turn > 0), .scroll(dy: scrollAmount(t, distance))]
    }

    /// Sent as finger travel like a two-finger drag: positive dy (down the pad) scrolls up the page
    /// with natural scrolling, so clockwise is up and counterclockwise is down.
    private mutating func scrollAmount(_ t: CGFloat, _ distance: CGFloat) -> CGFloat {
        if abs(t) > 0.05 { direction = direction * 0.6 + (t > 0 ? 0.4 : -0.4) }
        return (direction >= 0 ? 1 : -1) * distance * gain
    }
}
