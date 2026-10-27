// Rhythm-game style trainer. Shows prompts (where to tap and with how many fingers),
// judges timing and position, and keeps running stats. Drills are data: a period plus
// steps at fractional offsets, so new mechanics are a few lines each.

import UIKit
import AudioToolbox

/// A discrete input produced by the League finger layout (or the Pencil).
enum FingerGesture {
    case aim(CGPoint)
    case tap(fingers: Int, at: CGPoint)
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
    let name: String
    let period: Double
    let steps: [DrillStep]

    static let library: [Drill] = [
        Drill(name: "Orb Walk", period: 0.75, steps: [
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

    // Stats
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
        hint.text = "ATK = 2 fingers (or Pencil) · MOVE = 1 finger · SUMM = 3 · ITEM = 4"
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
        ])
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
    }

    @objc private func slower() { tempo = min(2.0, tempo + 0.1); refreshStats() }
    @objc private func faster() { tempo = max(0.4, tempo - 0.1); refreshStats() }

    @objc private func toggleRun() { running ? stop() : start() }

    func start() {
        resetStats()
        clearPrompts()
        running = true
        startTime = CACurrentMediaTime() + 1.0
        nextCycle = 0
        enemy = CGPoint(x: bounds.midX, y: bounds.midY)
        startButton.setTitle("Stop", for: .normal)
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        running = false
        displayLink?.invalidate()
        displayLink = nil
        clearPrompts()
        startButton.setTitle("Start", for: .normal)
        refreshStats()
    }

    // MARK: Input

    func handle(_ gesture: FingerGesture) {
        guard running else { return }
        let now = CACurrentMediaTime()
        let fingers: Int
        let point: CGPoint
        switch gesture {
        case .aim: return
        case .tap(let n, let p): fingers = n; point = p
        case .pencilTap(let p): fingers = 2; point = p
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

    // MARK: Scheduling and drawing

    @objc private func tick() {
        let now = CACurrentMediaTime()
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

    private func spawnCycle(_ cycle: Int) {
        let margin: CGFloat = 120
        let area = bounds.insetBy(dx: margin, dy: margin + 60)
        // The enemy drifts each cycle so you keep re-aiming; the retreat point is away from it.
        if cycle > 0 {
            let angle = Double.random(in: 0 ..< 2 * .pi)
            enemy.x += CGFloat(cos(angle)) * 90
            enemy.y += CGFloat(sin(angle)) * 90
        }
        enemy.x = min(max(enemy.x, area.minX), area.maxX)
        enemy.y = min(max(enemy.y, area.minY), area.maxY)
        let awayAngle = atan2(enemy.y - bounds.midY, enemy.x - bounds.midX) + .pi + CGFloat.random(in: -0.6 ... 0.6)
        var retreat = CGPoint(x: enemy.x + cos(awayAngle) * 240, y: enemy.y + sin(awayAngle) * 240)
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
            l.actions = ["opacity": NSNull(), "transform": NSNull(), "position": NSNull()]
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

    // MARK: Stats

    private func resetStats() {
        hits = 0; perfects = 0; misses = 0; strays = 0
        streak = 0; bestStreak = 0
        offsetSum = 0; absOffsetSum = 0; positionSum = 0
        refreshStats()
    }

    private func refreshStats() {
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
