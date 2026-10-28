// Trainer for League mechanics. Two kinds of drill:
//  - rhythm drills: prompts appear on a beat (where to tap, with how many fingers) and
//    timing/position are judged like a rhythm game;
//  - the Chase drill: a live simulation of orb walking. Your champion and an enemy are dots
//    on the pad, both react to the same commands League would get, and the enemy runs at you.
// Drills are data where possible, so new mechanics are a few lines each.

import UIKit
import AudioToolbox

/// A discrete input produced by the League finger layout (or the Pencil).
enum FingerGesture {
    case move(dx: CGFloat, dy: CGFloat)       // relative trackpad motion
    case tap(fingers: Int, at: CGPoint)
    case press(at: CGPoint)                   // firm press: finger stays put, contact patch grows
    case pencilTap(CGPoint)
}

struct DrillStep {
    enum Expect { case fingers(Int), any }
    enum Placement { case enemy, retreat, anywhere }
    let expect: Expect
    let placement: Placement
    /// Position within the cycle, as a fraction of the period (0 = on the beat).
    let offset: Double
    let label: String
}

struct Drill {
    enum Kind { case rhythm, chase }
    let name: String
    /// Beat period for rhythm drills; attack cooldown for the chase.
    let period: Double
    let steps: [DrillStep]
    var kind: Kind = .rhythm

    static let library: [Drill] = [
        Drill(name: "Chase", period: 0.75, steps: [], kind: .chase),
        Drill(name: "Orb Walk (beat)", period: 0.75, steps: [
            DrillStep(expect: .fingers(2), placement: .enemy,   offset: 0.0,  label: "ATK"),
            DrillStep(expect: .fingers(1), placement: .retreat, offset: 0.45, label: "MOVE"),
        ]),
        Drill(name: "Kite + Summoner", period: 0.8, steps: [
            DrillStep(expect: .fingers(2), placement: .enemy,    offset: 0.0,  label: "ATK"),
            DrillStep(expect: .fingers(1), placement: .retreat,  offset: 0.4,  label: "MOVE"),
            DrillStep(expect: .fingers(3), placement: .anywhere, offset: 0.7,  label: "SUMM"),
        ]),
        Drill(name: "Burst Combo", period: 1.2, steps: [
            DrillStep(expect: .fingers(3), placement: .anywhere, offset: 0.0,  label: "SUMM"),
            DrillStep(expect: .fingers(4), placement: .anywhere, offset: 0.3,  label: "ITEM"),
            DrillStep(expect: .fingers(2), placement: .enemy,    offset: 0.55, label: "ATK"),
            DrillStep(expect: .fingers(1), placement: .retreat,  offset: 0.8,  label: "MOVE"),
        ]),
        Drill(name: "Reaction", period: 1.0, steps: [
            DrillStep(expect: .any, placement: .anywhere, offset: 0.0, label: "?"),
        ]),
    ]
}

final class TrainingView: UIView {

    // MARK: Tunables
    private let leadTime: Double = 0.7          // prompt appears this long before its beat
    private let perfectWindow: Double = 0.10
    private let goodWindow: Double = 0.22
    private let positionTolerance: CGFloat = 70
    private let promptRadius: CGFloat = 34

    // Chase. Distances are fractions of the pad's short side so a wrist-sized area plays the same.
    private let chaseWindup: Double = 0.12          // attack wind-up; a move command inside it cancels
    private let chaseAttackRangeRatio: CGFloat = 0.33
    private let chaseChampionSpeedRatio: CGFloat = 0.55   // pad short sides per second
    private let chaseEnemySpeedRatio: CGFloat = 0.50      // slower than you, so kiting works
    private let chaseFlashRangeRatio: CGFloat = 0.25
    private let chaseFlashCooldown: Double = 10
    private let chaseEnemyHits = 4                  // shots to kill the enemy: the goal per round
    private let chaseBulletTime: Double = 0.18      // bullet flight time to the enemy
    private let chaseEnemyAttackRatio: Double = 1.5 // enemy attack cooldown relative to yours
    private let chaseEnemyWindup: Double = 0.25     // enemy swing wind-up (the swell before the lunge)
    private let chaseEnemyHitsToKill = 3            // enemy hits you survive before the round is lost

    /// Where prompts may appear: the touchpad's mapped area, set by the controller.
    var playArea = CGRect.zero

    /// Pencil hover position, drawn as a small ring so you can see where you are aiming.
    var cursor: CGPoint? {
        didSet {
            guard let c = cursor else { cursorLayer.opacity = 0; return }
            cursorLayer.position = c
            cursorLayer.opacity = running ? 0.9 : 0
        }
    }

    // MARK: State
    private var drillIndex = 0
    private var drill: Drill { Drill.library[drillIndex] }
    private var tempo: Double = 1.0              // multiplies the drill's period (lower = faster)
    private var period: Double { drill.period * tempo }
    private var running = false
    private var startTime: Double = 0
    private var nextCycle = 0
    private var prompts: [Prompt] = []
    private var enemy = CGPoint.zero
    private var displayLink: CADisplayLink?

    // Stats (rhythm)
    private var hits = 0, perfects = 0, misses = 0, strays = 0
    private var streak = 0, bestStreak = 0
    private var offsetSum: Double = 0, absOffsetSum: Double = 0, positionSum: CGFloat = 0

    private final class Prompt {
        let time: Double
        let step: DrillStep
        let expect: DrillStep.Expect
        let position: CGPoint?
        var judged = false
        var judgedAt: Double = 0
        let circle = CAShapeLayer()
        let ring = CAShapeLayer()
        let text = CATextLayer()
        init(time: Double, step: DrillStep, expect: DrillStep.Expect, position: CGPoint?) {
            self.time = time; self.step = step; self.expect = expect; self.position = position
        }
    }

    // MARK: UI
    private let drillButton = UIButton(type: .system)
    private let slowerButton = UIButton(type: .system)
    private let fasterButton = UIButton(type: .system)
    private let startButton = UIButton(type: .system)
    private let stats = UILabel()
    private let hint = UILabel()
    private let cursorLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for (button, title, action) in [
            (drillButton, Drill.library[0].name, #selector(cycleDrill)),
            (slowerButton, "Slower", #selector(slower)),
            (fasterButton, "Faster", #selector(faster)),
            (startButton, "Start", #selector(toggleRun)),
        ] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
            button.setTitleColor(UIColor(white: 0.8, alpha: 1), for: .normal)
            button.backgroundColor = UIColor(white: 0.15, alpha: 1)
            button.layer.cornerRadius = 8
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            button.addTarget(self, action: action, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        for label in [stats, hint] {
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = UIColor(white: 0.6, alpha: 1)
            label.textAlignment = .center
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            drillButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            drillButton.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -150),
            slowerButton.bottomAnchor.constraint(equalTo: drillButton.bottomAnchor),
            slowerButton.leadingAnchor.constraint(equalTo: drillButton.trailingAnchor, constant: 12),
            fasterButton.bottomAnchor.constraint(equalTo: drillButton.bottomAnchor),
            fasterButton.leadingAnchor.constraint(equalTo: slowerButton.trailingAnchor, constant: 12),
            startButton.bottomAnchor.constraint(equalTo: drillButton.bottomAnchor),
            startButton.leadingAnchor.constraint(equalTo: fasterButton.trailingAnchor, constant: 12),
            stats.bottomAnchor.constraint(equalTo: drillButton.topAnchor, constant: -14),
            stats.centerXAnchor.constraint(equalTo: centerXAnchor),
            stats.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            hint.bottomAnchor.constraint(equalTo: stats.topAnchor, constant: -6),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
        ])
        cursorLayer.path = UIBezierPath(ovalIn: CGRect(x: -6, y: -6, width: 12, height: 12)).cgPath
        cursorLayer.fillColor = UIColor.clear.cgColor
        cursorLayer.strokeColor = UIColor.white.cgColor
        cursorLayer.lineWidth = 1.5
        cursorLayer.opacity = 0
        still(cursorLayer)
        layer.addSublayer(cursorLayer)
        refreshHint()
        refreshStats()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Only the buttons are interactive; everything else passes through to the touchpad.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for button in [drillButton, slowerButton, fasterButton, startButton]
        where button.frame.contains(point) {
            return button
        }
        return nil
    }

    // MARK: Controls

    @objc private func cycleDrill() {
        stop()
        drillIndex = (drillIndex + 1) % Drill.library.count
        drillButton.setTitle(drill.name, for: .normal)
        resetStats()
        refreshHint()
    }

    @objc private func slower() { tempo = min(2.0, tempo + 0.1); refreshStats() }
    @objc private func faster() { tempo = max(0.4, tempo - 0.1); refreshStats() }

    @objc private func toggleRun() { running ? stop() : start() }

    func start() {
        resetStats()
        clearPrompts()
        running = true
        let now = CACurrentMediaTime()
        startTime = now + 1.0
        nextCycle = 0
        enemy = CGPoint(x: area.midX, y: area.midY)
        if drill.kind == .chase { chaseStart(now: now) }
        startButton.setTitle("Stop", for: .normal)
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
        if let c = cursor { cursor = c }
    }

    func stop() {
        running = false
        displayLink?.invalidate()
        displayLink = nil
        clearPrompts()
        chaseTeardown()
        cursorLayer.opacity = 0
        startButton.setTitle("Start", for: .normal)
        refreshStats()
    }

    private func refreshHint() {
        switch drill.kind {
        case .chase:
            hint.text = "Blue is you, red runs at you. 1-finger tap / Pencil tip = move · 2 fingers, firm press or Pencil double-tap = attack-move · 3 fingers / squeeze = Flash\n" +
                        "Land 4 shots before it reaches you; it swells before each swing and three swings kill you. Attack-move when the ring is white, move away while the orange ring refills. Moving during the wind-up cancels the shot."
        case .rhythm:
            hint.text = "ATK = firm press, 2 fingers or Pencil barrel double-tap · MOVE = 1-finger tap or Pencil tip · SUMM = 3 · ITEM = 4"
        }
    }

    // MARK: Input

    func handle(_ gesture: FingerGesture) {
        guard running else { return }
        let now = CACurrentMediaTime()
        let fingers: Int
        let point: CGPoint
        switch gesture {
        case .move: return
        case .tap(let n, let p): fingers = n; point = p
        case .press(let p): fingers = 2; point = p          // a firm press counts as an attack
        case .pencilTap(let p): fingers = 1; point = p
        }
        if drill.kind == .chase {
            chaseCommand(fingers: fingers, at: point, now: now)
            return
        }
        // Nearest unjudged prompt in time that accepts this gesture.
        let candidates = prompts.filter { !$0.judged && abs(now - $0.time) <= goodWindow && accepts($0.expect, fingers) }
        guard let prompt = candidates.min(by: { abs(now - $0.time) < abs(now - $1.time) }) else {
            strays += 1
            streak = 0
            refreshStats()
            return
        }
        let offset = now - prompt.time
        var distance: CGFloat = 0
        if let target = prompt.position {
            distance = hypot(point.x - target.x, point.y - target.y)
        }
        if distance > positionTolerance {
            judge(prompt, result: "OFF", color: .systemOrange, now: now)
            misses += 1
            streak = 0
        } else {
            let perfect = abs(offset) <= perfectWindow
            judge(prompt, result: perfect ? "PERFECT" : (offset < 0 ? "EARLY" : "LATE"),
                  color: perfect ? .systemGreen : .systemYellow, now: now)
            hits += 1
            if perfect { perfects += 1 }
            streak += 1
            bestStreak = max(bestStreak, streak)
            offsetSum += offset
            absOffsetSum += abs(offset)
            positionSum += distance
        }
        refreshStats()
    }

    private func accepts(_ expect: DrillStep.Expect, _ fingers: Int) -> Bool {
        switch expect {
        case .any: return true
        case .fingers(let n): return n >= 4 ? fingers >= 4 : fingers == n
        }
    }

    // MARK: Scheduling and drawing (rhythm)

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if drill.kind == .chase {
            chaseTick(now: now)
            return
        }
        // Generate prompts up to one lead time ahead.
        while startTime + Double(nextCycle) * period < now + leadTime + period {
            spawnCycle(nextCycle)
            nextCycle += 1
        }
        for prompt in prompts {
            if !prompt.judged, now > prompt.time + goodWindow {
                judge(prompt, result: "MISS", color: .systemRed, now: now)
                misses += 1
                streak = 0
                refreshStats()
            }
            let remaining = prompt.time - now
            if prompt.judged {
                let age = now - prompt.judgedAt
                let alpha = max(0, 1 - Float(age / 0.35))
                prompt.circle.opacity = alpha
                prompt.ring.opacity = 0
                prompt.text.opacity = alpha
            } else if remaining <= leadTime {
                let progress = max(0, remaining / leadTime)            // 1 far away, 0 on the beat
                let scale = 1 + 1.6 * CGFloat(progress)
                prompt.ring.transform = CATransform3DMakeScale(scale, scale, 1)
                prompt.circle.opacity = 1
                prompt.ring.opacity = 1
                prompt.text.opacity = 1
            }
        }
        let cutoff = now - 0.4
        prompts.removeAll { p in
            if p.judged, p.judgedAt < cutoff {
                p.circle.removeFromSuperlayer(); p.ring.removeFromSuperlayer(); p.text.removeFromSuperlayer()
                return true
            }
            return false
        }
    }

    /// Prompt area, inset so circles stay fully inside the mapped region.
    private var area: CGRect {
        let base = playArea.isEmpty ? bounds.insetBy(dx: 120, dy: 160) : playArea
        let inset = promptRadius + 8
        let r = base.insetBy(dx: inset, dy: inset)
        return r.isNull || r.width <= 0 || r.height <= 0 ? base : r
    }

    private func spawnCycle(_ cycle: Int) {
        let area = self.area
        // Distances scale with the area so a small wrist-sized pad still gets real kiting motion.
        let drift = min(area.width, area.height) * 0.18
        let kite = min(area.width, area.height) * 0.45
        // The enemy drifts each cycle so you keep re-aiming; the retreat point is away from it.
        if cycle > 0 {
            let angle = Double.random(in: 0 ..< 2 * .pi)
            enemy.x += CGFloat(cos(angle)) * drift
            enemy.y += CGFloat(sin(angle)) * drift
        }
        enemy.x = min(max(enemy.x, area.minX), area.maxX)
        enemy.y = min(max(enemy.y, area.minY), area.maxY)
        let awayAngle = atan2(enemy.y - area.midY, enemy.x - area.midX) + .pi + CGFloat.random(in: -0.6 ... 0.6)
        var retreat = CGPoint(x: enemy.x + cos(awayAngle) * kite, y: enemy.y + sin(awayAngle) * kite)
        retreat.x = min(max(retreat.x, area.minX), area.maxX)
        retreat.y = min(max(retreat.y, area.minY), area.maxY)

        let cycleStart = startTime + Double(cycle) * period
        if cycle > 0 { AudioServicesPlaySystemSound(1104) }
        for step in drill.steps {
            let position: CGPoint?
            switch step.placement {
            case .enemy: position = enemy
            case .retreat: position = retreat
            case .anywhere: position = CGPoint(x: CGFloat.random(in: area.minX ... area.maxX),
                                               y: CGFloat.random(in: area.minY ... area.maxY))
            }
            var expect = step.expect
            var label = step.label
            if case .any = step.expect {
                let n = Int.random(in: 1 ... 4)
                expect = .fingers(n)
                label = ["MOVE", "ATK", "SUMM", "ITEM"][n - 1]
            }
            let prompt = Prompt(time: cycleStart + step.offset * period, step: step, expect: expect, position: position)
            addLayers(for: prompt, label: label)
            prompts.append(prompt)
        }
    }

    private func addLayers(for prompt: Prompt, label: String) {
        let center = prompt.position ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let color: UIColor
        switch prompt.expect {
        case .fingers(1): color = .systemBlue
        case .fingers(2): color = .systemRed
        case .fingers(3): color = .systemPurple
        default: color = .systemTeal
        }
        let path = UIBezierPath(ovalIn: CGRect(x: -promptRadius, y: -promptRadius,
                                               width: promptRadius * 2, height: promptRadius * 2)).cgPath
        prompt.circle.path = path
        prompt.circle.fillColor = color.withAlphaComponent(0.35).cgColor
        prompt.circle.strokeColor = color.cgColor
        prompt.circle.lineWidth = 2
        prompt.circle.position = center
        prompt.circle.opacity = 0

        prompt.ring.path = path
        prompt.ring.fillColor = UIColor.clear.cgColor
        prompt.ring.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        prompt.ring.lineWidth = 2
        prompt.ring.position = center
        prompt.ring.opacity = 0

        prompt.text.string = label
        prompt.text.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        prompt.text.fontSize = 15
        prompt.text.foregroundColor = UIColor.white.cgColor
        prompt.text.alignmentMode = .center
        prompt.text.contentsScale = UIScreen.main.scale
        prompt.text.frame = CGRect(x: center.x - 60, y: center.y - 9, width: 120, height: 20)
        prompt.text.opacity = 0

        for l in [prompt.ring, prompt.circle, prompt.text] {
            still(l)
            layer.addSublayer(l)
        }
    }

    private func judge(_ prompt: Prompt, result: String, color: UIColor, now: Double) {
        prompt.judged = true
        prompt.judgedAt = now
        prompt.text.string = result
        prompt.text.foregroundColor = color.cgColor
        prompt.circle.strokeColor = color.cgColor
    }

    private func clearPrompts() {
        for p in prompts {
            p.circle.removeFromSuperlayer(); p.ring.removeFromSuperlayer(); p.text.removeFromSuperlayer()
        }
        prompts.removeAll()
    }

    /// Core Animation would otherwise animate every property change over 0.25 s; we drive frames ourselves.
    private func still(_ l: CALayer) {
        l.actions = ["opacity": NSNull(), "transform": NSNull(), "position": NSNull(), "path": NSNull(),
                     "strokeEnd": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(),
                     "bounds": NSNull(), "backgroundColor": NSNull(), "lineWidth": NSNull()]
    }

    // MARK: - Chase simulation

    private struct ChaseState {
        var champion = CGPoint.zero
        var enemy = CGPoint.zero
        var championHP: CGFloat = 1
        var enemyHP: CGFloat = 1
        var moveTarget: CGPoint?
        var attackMoving = false            // walking under an attack-move: auto-attacks once in range
        var windupEnd: Double?
        var attackReadyAt: Double = 0
        var inRangeSince: Double?
        var cooldownActive = false
        var cooldownMoved = false           // a move command was issued during this cooldown (= kiting)
        var flashReadyAt: Double = 0
        var jukeAngle: CGFloat = 0
        var nextJuke: Double = 0
        var lastTick: Double = 0
        var bullet: (from: CGPoint, launchedAt: Double)?
        var targetShownAt: Double = -1
        var enemyWindupEnd: Double?
        var enemyAttackReadyAt: Double = 0
        var enemyHitAt: Double = -1
        var hitsTaken = 0
        var shotsBeforeContact: Int?            // shots landed before the enemy first hit you
        // Stats
        var roundShots = 0, bestRoundShots = 0, lastRoundShots = 0, rounds = 0, totalRoundShots = 0
        var lastClean = 0, bestClean = 0, totalClean = 0
        var kills = 0, caught = 0, attacks = 0, cancels = 0
        var cooldowns = 0, kitedCooldowns = 0
        var readyDelaySum: Double = 0, readyDelays = 0
    }

    private var chase = ChaseState()
    private let championLayer = CAShapeLayer()
    private let enemyLayer = CAShapeLayer()
    private let rangeLayer = CAShapeLayer()
    private let cooldownLayer = CAShapeLayer()
    private let enemyCooldownLayer = CAShapeLayer()
    private let targetLayer = CAShapeLayer()
    private let bulletLayer = CAShapeLayer()
    private let championHPBack = CALayer(), championHPFill = CALayer()
    private let enemyHPBack = CALayer(), enemyHPFill = CALayer()
    private var captions: [(layer: CATextLayer, at: Double)] = []
    private var chaseInstalled = false

    private var unit: CGFloat { min(area.width, area.height) }
    private var dotRadius: CGFloat { max(9, unit * 0.035) }
    private var attackRange: CGFloat { unit * chaseAttackRangeRatio }
    private var reach: CGFloat { dotRadius * 2 + unit * 0.02 }          // enemy melee reach

    private func chaseStart(now: Double) {
        chase = ChaseState()
        chase.lastTick = now
        chaseInstall()
        chaseResetRound(now: now)
    }

    private func chaseInstall() {
        let r = dotRadius
        let dot = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).cgPath
        championLayer.path = dot
        championLayer.fillColor = UIColor.systemBlue.cgColor
        championLayer.strokeColor = UIColor.white.cgColor
        championLayer.lineWidth = 1.5
        enemyLayer.path = dot
        enemyLayer.fillColor = UIColor.systemRed.cgColor
        enemyLayer.strokeColor = UIColor.white.cgColor
        enemyLayer.lineWidth = 1.5

        let range = attackRange
        rangeLayer.path = UIBezierPath(ovalIn: CGRect(x: -range, y: -range, width: 2 * range, height: 2 * range)).cgPath
        rangeLayer.fillColor = UIColor.clear.cgColor
        rangeLayer.lineWidth = 1.5
        rangeLayer.lineDashPattern = [6, 6]

        let arcR = r + 7
        cooldownLayer.path = UIBezierPath(arcCenter: .zero, radius: arcR, startAngle: -.pi / 2,
                                          endAngle: 1.5 * .pi, clockwise: true).cgPath
        cooldownLayer.fillColor = UIColor.clear.cgColor
        cooldownLayer.lineWidth = 4
        cooldownLayer.lineCap = .round
        cooldownLayer.strokeEnd = 0
        enemyCooldownLayer.path = cooldownLayer.path
        enemyCooldownLayer.fillColor = UIColor.clear.cgColor
        enemyCooldownLayer.lineWidth = 4
        enemyCooldownLayer.lineCap = .round
        enemyCooldownLayer.strokeEnd = 0

        targetLayer.path = UIBezierPath(ovalIn: CGRect(x: -8, y: -8, width: 16, height: 16)).cgPath
        targetLayer.fillColor = UIColor.clear.cgColor
        targetLayer.lineWidth = 2
        targetLayer.opacity = 0

        bulletLayer.path = UIBezierPath(ovalIn: CGRect(x: -4, y: -4, width: 8, height: 8)).cgPath
        bulletLayer.fillColor = UIColor.white.cgColor
        bulletLayer.strokeColor = UIColor.systemYellow.cgColor
        bulletLayer.lineWidth = 1.5
        bulletLayer.opacity = 0

        for (back, fill) in [(championHPBack, championHPFill), (enemyHPBack, enemyHPFill)] {
            back.bounds = CGRect(x: 0, y: 0, width: 40, height: 5)
            back.backgroundColor = UIColor(white: 0.25, alpha: 1).cgColor
            back.cornerRadius = 2.5
            fill.bounds = CGRect(x: 0, y: 0, width: 40, height: 5)
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.position = CGPoint(x: 0, y: 2.5)
            fill.cornerRadius = 2.5
            back.addSublayer(fill)
        }
        championHPFill.backgroundColor = UIColor.systemGreen.cgColor
        enemyHPFill.backgroundColor = UIColor.systemRed.cgColor

        if !chaseInstalled {
            for l in [rangeLayer, targetLayer, bulletLayer, cooldownLayer, enemyCooldownLayer, enemyLayer, championLayer,
                      championHPBack, championHPFill, enemyHPBack, enemyHPFill] {
                still(l)
            }
            for l in [rangeLayer, targetLayer, bulletLayer, cooldownLayer, enemyCooldownLayer, enemyLayer, championLayer,
                      championHPBack, enemyHPBack] {
                layer.insertSublayer(l, below: cursorLayer)
            }
            chaseInstalled = true
        }
        for l in [rangeLayer, cooldownLayer, enemyCooldownLayer, enemyLayer, championLayer, championHPBack, enemyHPBack] {
            l.isHidden = false
        }
    }

    private func chaseTeardown() {
        guard chaseInstalled else { return }
        for l in [rangeLayer, targetLayer, bulletLayer, cooldownLayer, enemyCooldownLayer, enemyLayer, championLayer,
                  championHPBack, enemyHPBack] {
            l.isHidden = true
        }
        targetLayer.opacity = 0
        bulletLayer.opacity = 0
        for c in captions { c.layer.removeFromSuperlayer() }
        captions.removeAll()
    }

    private func chaseResetRound(now: Double) {
        let area = self.area
        chase.champion = CGPoint(x: area.midX, y: area.midY)
        chase.championHP = 1
        chase.moveTarget = nil
        chase.attackMoving = false
        chase.windupEnd = nil
        chase.attackReadyAt = now
        chase.cooldownActive = false
        chase.inRangeSince = nil
        chase.bullet = nil
        chase.roundShots = 0
        chase.hitsTaken = 0
        chase.shotsBeforeContact = nil
        chase.enemyWindupEnd = nil
        chase.enemyAttackReadyAt = now
        chase.enemyHitAt = -1
        chaseSpawnEnemy()
    }

    private func chaseEndRound() {
        chase.rounds += 1
        chase.lastRoundShots = chase.roundShots
        chase.totalRoundShots += chase.roundShots
        chase.bestRoundShots = max(chase.bestRoundShots, chase.roundShots)
        let clean = chase.shotsBeforeContact ?? chase.roundShots
        chase.lastClean = clean
        chase.totalClean += clean
        chase.bestClean = max(chase.bestClean, clean)
    }

    /// The enemy appears on the edge of the pad, as far from you as a few random picks allow.
    private func chaseSpawnEnemy() {
        let area = self.area
        var best = CGPoint(x: area.minX, y: area.minY)
        var bestDistance: CGFloat = -1
        for _ in 0 ..< 6 {
            let t = CGFloat.random(in: 0 ..< 1)
            let p: CGPoint
            switch Int.random(in: 0 ..< 4) {
            case 0: p = CGPoint(x: area.minX + t * area.width, y: area.minY)
            case 1: p = CGPoint(x: area.minX + t * area.width, y: area.maxY)
            case 2: p = CGPoint(x: area.minX, y: area.minY + t * area.height)
            default: p = CGPoint(x: area.maxX, y: area.minY + t * area.height)
            }
            let d = hypot(p.x - chase.champion.x, p.y - chase.champion.y)
            if d > bestDistance { best = p; bestDistance = d }
        }
        chase.enemy = best
        chase.enemyHP = 1
        chase.inRangeSince = nil
    }

    private func chaseCommand(fingers: Int, at p: CGPoint, now: Double) {
        switch fingers {
        case 1:                                                     // move
            if chase.windupEnd != nil {
                chase.windupEnd = nil
                chase.cancels += 1
                caption("CANCEL", color: .systemOrange, at: chase.champion, now: now)
            }
            chase.moveTarget = p
            chase.attackMoving = false
            if chase.cooldownActive { chase.cooldownMoved = true }
            showTarget(p, color: .systemGreen, now: now)
        case 2:                                                     // attack-move
            guard chase.windupEnd == nil else { return }            // already swinging
            chase.attackMoving = true
            chase.moveTarget = p
            showTarget(p, color: .systemRed, now: now)
        case 3:                                                     // Flash toward the tap
            guard now >= chase.flashReadyAt else {
                caption("FLASH \(Int(ceil(chase.flashReadyAt - now)))s", color: .systemYellow, at: chase.champion, now: now)
                return
            }
            let dx = p.x - chase.champion.x, dy = p.y - chase.champion.y
            let d = max(hypot(dx, dy), 0.001)
            let step = min(d, unit * chaseFlashRangeRatio)
            chase.champion.x += dx / d * step
            chase.champion.y += dy / d * step
            clamp(&chase.champion)
            chase.windupEnd = nil
            chase.flashReadyAt = now + chaseFlashCooldown
            caption("FLASH", color: .systemYellow, at: chase.champion, now: now)
            AudioServicesPlaySystemSound(1057)
        default:
            break
        }
        refreshStats()
    }

    private func chaseTick(now: Double) {
        let dt = min(0.05, max(0, now - chase.lastTick))
        chase.lastTick = now
        let speedScale = CGFloat(1 / tempo)
        let cooldown = period
        let windup = chaseWindup * tempo

        // Enemy: runs at you with a slight weave so you keep re-aiming, stops at reach.
        var dx = chase.champion.x - chase.enemy.x, dy = chase.champion.y - chase.enemy.y
        var distance = hypot(dx, dy)
        if now >= chase.nextJuke {
            chase.jukeAngle = CGFloat.random(in: -0.6 ... 0.6)
            chase.nextJuke = now + Double.random(in: 0.5 ... 1.0)
        }
        if distance > reach * 0.9, chase.enemyWindupEnd == nil {              // plants its feet to swing
            var angle = atan2(dy, dx)
            if distance > reach * 2.5 { angle += chase.jukeAngle }
            let step = min(unit * chaseEnemySpeedRatio * speedScale * CGFloat(dt), distance - reach * 0.9)
            chase.enemy.x += cos(angle) * step
            chase.enemy.y += sin(angle) * step
            clamp(&chase.enemy)
        }

        // Champion: wind-up, attack-move, or plain move.
        dx = chase.enemy.x - chase.champion.x; dy = chase.enemy.y - chase.champion.y
        distance = hypot(dx, dy)
        let inRange = distance <= attackRange
        if inRange {
            if chase.inRangeSince == nil { chase.inRangeSince = now }
        } else {
            chase.inRangeSince = nil
        }
        let ready = now >= chase.attackReadyAt
        if chase.cooldownActive && ready {
            chase.cooldownActive = false
            chase.cooldowns += 1
            if chase.cooldownMoved { chase.kitedCooldowns += 1 }
            refreshStats()
        }

        if let end = chase.windupEnd {
            if now >= end { chaseFire(now: now, cooldown: cooldown) }      // stands still only for the wind-up
        } else if chase.attackMoving, inRange, ready {
            chaseBeginWindup(now: now, windup: windup)
        } else if let t = chase.moveTarget {
            if walk(toward: t, speedScale: speedScale, dt: dt) { chase.moveTarget = nil }
        }

        // Bullet in flight: homes on the enemy, damage lands on arrival.
        if let b = chase.bullet, now - b.launchedAt >= chaseBulletTime {
            chase.bullet = nil
            chaseBulletLands(now: now)
        }

        // Enemy swings: winds up in reach, lands at the end of the wind-up even if you step away.
        let enemyWindup = chaseEnemyWindup * tempo
        if let end = chase.enemyWindupEnd {
            if now >= end { chaseEnemyHits(now: now, cooldown: cooldown * chaseEnemyAttackRatio) }
        } else if distance <= reach, now >= chase.enemyAttackReadyAt {
            chase.enemyWindupEnd = now + enemyWindup
        }

        chaseDraw(now: now, inRange: inRange, ready: ready, cooldown: cooldown, windup: windup, enemyWindup: enemyWindup)
    }

    private func chaseEnemyHits(now: Double, cooldown: Double) {
        chase.enemyWindupEnd = nil
        chase.enemyAttackReadyAt = now + cooldown
        chase.enemyHitAt = now
        chase.hitsTaken += 1
        if chase.shotsBeforeContact == nil { chase.shotsBeforeContact = chase.roundShots }
        chase.championHP -= 1 / CGFloat(chaseEnemyHitsToKill)
        AudioServicesPlaySystemSound(1105)
        if chase.championHP <= 0.001 {
            chase.caught += 1
            chaseEndRound()
            caption("CAUGHT · \(chase.roundShots) shots", color: .systemRed, at: chase.champion, now: now)
            AudioServicesPlaySystemSound(1053)
            chaseResetRound(now: now)
        }
        refreshStats()
    }

    private func chaseBeginWindup(now: Double, windup: Double) {
        chase.windupEnd = now + windup
        // How long the attack sat available (ready AND in range) before you used it.
        let possibleSince = max(chase.attackReadyAt, chase.inRangeSince ?? now)
        chase.readyDelaySum += max(0, now - possibleSince)
        chase.readyDelays += 1
    }

    private func chaseFire(now: Double, cooldown: Double) {
        chase.windupEnd = nil
        chase.attacks += 1
        chase.roundShots += 1
        chase.attackReadyAt = now + cooldown
        chase.cooldownActive = true
        chase.cooldownMoved = false
        chase.bullet = (chase.champion, now)
        AudioServicesPlaySystemSound(1104)
        refreshStats()
    }

    private func chaseBulletLands(now: Double) {
        chase.enemyHP -= 1 / CGFloat(chaseEnemyHits)
        if chase.enemyHP <= 0 {
            chase.kills += 1
            chaseEndRound()
            caption("KILL · \(chase.roundShots) shots", color: .systemGreen, at: chase.enemy, now: now)
            chaseResetRound(now: now)
        }
        refreshStats()
    }

    /// Moves the champion toward a point; returns true on arrival.
    @discardableResult
    private func walk(toward t: CGPoint, speedScale: CGFloat, dt: Double) -> Bool {
        let dx = t.x - chase.champion.x, dy = t.y - chase.champion.y
        let d = hypot(dx, dy)
        let step = unit * chaseChampionSpeedRatio * speedScale * CGFloat(dt)
        if d <= step {
            chase.champion = t
            clamp(&chase.champion)
            return true
        }
        chase.champion.x += dx / d * step
        chase.champion.y += dy / d * step
        clamp(&chase.champion)
        return false
    }

    private func clamp(_ p: inout CGPoint) {
        let area = self.area
        p.x = min(max(p.x, area.minX), area.maxX)
        p.y = min(max(p.y, area.minY), area.maxY)
    }

    private func chaseDraw(now: Double, inRange: Bool, ready: Bool, cooldown: Double, windup: Double, enemyWindup: Double) {
        championLayer.position = chase.champion
        rangeLayer.position = chase.champion
        cooldownLayer.position = chase.champion
        enemyCooldownLayer.position = chase.enemy

        // Enemy swing animation: swells through the wind-up, lunges at you on the hit.
        var enemyPos = chase.enemy
        var enemyScale: CGFloat = 1
        if let end = chase.enemyWindupEnd {
            let progress = CGFloat(1 - max(0, (end - now) / enemyWindup))
            enemyScale = 1 + 0.4 * progress
            enemyCooldownLayer.strokeColor = UIColor.systemRed.cgColor
            enemyCooldownLayer.strokeEnd = progress
        } else {
            enemyCooldownLayer.strokeColor = UIColor.systemRed.withAlphaComponent(0.45).cgColor
            let enemyCooldown = cooldown * chaseEnemyAttackRatio
            enemyCooldownLayer.strokeEnd = now >= chase.enemyAttackReadyAt ? 0
                : CGFloat(1 - max(0, (chase.enemyAttackReadyAt - now) / enemyCooldown))
        }
        let sinceHit = now - chase.enemyHitAt
        if chase.enemyHitAt >= 0, sinceHit < 0.15 {
            let lunge = reach * 0.6 * CGFloat(1 - sinceHit / 0.15)
            let dx = chase.champion.x - chase.enemy.x, dy = chase.champion.y - chase.enemy.y
            let d = max(hypot(dx, dy), 0.001)
            enemyPos.x += dx / d * lunge
            enemyPos.y += dy / d * lunge
            championLayer.strokeColor = UIColor.systemRed.cgColor
            championLayer.lineWidth = 4
        } else {
            championLayer.strokeColor = UIColor.white.cgColor
            championLayer.lineWidth = 1.5
        }
        enemyLayer.position = enemyPos
        enemyLayer.transform = CATransform3DMakeScale(enemyScale, enemyScale, 1)
        let r = dotRadius
        championHPBack.position = CGPoint(x: chase.champion.x, y: chase.champion.y - r - 10)
        enemyHPBack.position = CGPoint(x: chase.enemy.x, y: chase.enemy.y - r - 10)
        championHPFill.transform = CATransform3DMakeScale(max(0, chase.championHP), 1, 1)
        enemyHPFill.transform = CATransform3DMakeScale(max(0, chase.enemyHP), 1, 1)

        // Range ring: grey out of range, yellow in range but cooling, white when you can attack now.
        let rangeColor: UIColor = !inRange ? UIColor(white: 0.45, alpha: 1)
            : (ready && chase.windupEnd == nil ? .white : .systemYellow)
        rangeLayer.strokeColor = rangeColor.cgColor
        rangeLayer.lineWidth = inRange && ready && chase.windupEnd == nil ? 2.5 : 1.5

        if let end = chase.windupEnd {
            cooldownLayer.strokeColor = UIColor.systemRed.cgColor
            cooldownLayer.strokeEnd = CGFloat(1 - max(0, (end - now) / windup))
        } else if !ready {
            cooldownLayer.strokeColor = UIColor.systemOrange.cgColor
            cooldownLayer.strokeEnd = CGFloat(1 - max(0, (chase.attackReadyAt - now) / cooldown))
        } else {
            cooldownLayer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
            cooldownLayer.strokeEnd = 1
        }

        if chase.targetShownAt >= 0 {
            targetLayer.opacity = Float(max(0, 1 - (now - chase.targetShownAt) / 0.6))
        }
        if let b = chase.bullet {
            let t = CGFloat(min(1, (now - b.launchedAt) / chaseBulletTime))
            bulletLayer.position = CGPoint(x: b.from.x + (chase.enemy.x - b.from.x) * t,
                                           y: b.from.y + (chase.enemy.y - b.from.y) * t)
            bulletLayer.opacity = 1
        } else {
            bulletLayer.opacity = 0
        }
        captions.removeAll { c in
            let age = now - c.at
            if age > 0.8 { c.layer.removeFromSuperlayer(); return true }
            c.layer.opacity = Float(max(0, 1 - age / 0.8))
            c.layer.transform = CATransform3DMakeTranslation(0, CGFloat(-24 * age), 0)
            return false
        }
    }

    private func showTarget(_ p: CGPoint, color: UIColor, now: Double) {
        targetLayer.position = p
        targetLayer.strokeColor = color.cgColor
        chase.targetShownAt = now
        targetLayer.opacity = 1
    }

    private func caption(_ text: String, color: UIColor, at p: CGPoint, now: Double) {
        let t = CATextLayer()
        t.string = text
        t.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        t.fontSize = 15
        t.foregroundColor = color.cgColor
        t.alignmentMode = .center
        t.contentsScale = UIScreen.main.scale
        t.frame = CGRect(x: p.x - 60, y: p.y - dotRadius - 34, width: 120, height: 20)
        still(t)
        layer.addSublayer(t)
        captions.append((t, now))
    }

    // MARK: Stats

    private func resetStats() {
        hits = 0; perfects = 0; misses = 0; strays = 0
        streak = 0; bestStreak = 0
        offsetSum = 0; absOffsetSum = 0; positionSum = 0
        refreshStats()
    }

    private func refreshStats() {
        if drill.kind == .chase {
            let kited = chase.cooldowns == 0 ? 0 : chase.kitedCooldowns * 100 / chase.cooldowns
            let delay = chase.readyDelays == 0 ? 0 : Int(chase.readyDelaySum / Double(chase.readyDelays) * 1000)
            let avg = chase.rounds == 0 ? 0 : Double(chase.totalClean) / Double(chase.rounds)
            stats.text = String(format: "%@ · you %.2fs / enemy %.2fs · this round %d shots, %d hits taken · shots before contact: last %d · best %d · avg %.1f · goal 4\nkills %d · caught %d · cancelled %d · kited during %d%% of cooldowns · ready → attack %d ms",
                                drill.name, period, period * chaseEnemyAttackRatio, chase.roundShots, chase.hitsTaken,
                                chase.lastClean, chase.bestClean, avg,
                                chase.kills, chase.caught, chase.cancels, kited, delay)
            return
        }
        let total = hits + misses
        let accuracy = total == 0 ? 0 : Int(Double(hits) / Double(total) * 100)
        let meanOffset = hits == 0 ? 0 : Int(offsetSum / Double(hits) * 1000)
        let meanAbs = hits == 0 ? 0 : Int(absOffsetSum / Double(hits) * 1000)
        let meanPos = hits == 0 ? 0 : Int(positionSum / CGFloat(hits))
        let bias = meanOffset < 0 ? "early" : "late"
        stats.text = String(format: "%@ · beat %.2fs · %d%% hits (%d/%d) · %d perfect · streak %d (best %d) · stray %d\ntiming ±%d ms, %d ms %@ · position %d pt",
                            drill.name, period, accuracy, hits, total, perfects, streak, bestStreak, strays,
                            meanAbs, abs(meanOffset), bias, meanPos)
    }
}
