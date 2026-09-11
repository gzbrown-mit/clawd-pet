import AppKit

/// Transparent, borderless, always-on-top panel that never steals focus.
final class PetPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws one sprite frame with crisp square pixels.
final class PetView: NSView {
    var grid: Grid = [] { didSet { needsDisplay = true } }
    var decorations: [Overlay] = [] { didSet { needsDisplay = true } }
    var mirrored = false { didSet { if oldValue != mirrored { needsDisplay = true } } }
    let scale: CGFloat
    weak var controller: PetController?

    init(scale: CGFloat) {
        self.scale = scale
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(canvasW) * scale, height: CGFloat(canvasH) * scale))
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !grid.isEmpty else { return }
        var g = grid
        for o in decorations {
            for (dy, line) in o.rows.enumerated() {
                for (dx, ch) in line.enumerated() where ch != "." {
                    let y = o.y + dy, x = o.x + dx
                    if y >= 0, y < canvasH, x >= 0, x < canvasW { g[y][x] = ch }
                }
            }
        }
        if mirrored { g = g.map { Array($0.reversed()) } }
        for (y, row) in g.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = Palette.colors[ch] else { continue }
                color.setFill()
                NSRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale).fill()
            }
        }
    }

    // Clicks on transparent pixels fall through to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let x = Int(p.x / scale), y = Int(p.y / scale)
        guard y >= 0, y < grid.count, x >= 0, x < canvasW else { return nil }
        let col = mirrored ? canvasW - 1 - x : x
        if grid[y][col] != "." { return self }
        for o in decorations {
            let dy = y - o.y, dx = col - o.x
            if dy >= 0, dy < o.rows.count {
                let line = Array(o.rows[dy])
                if dx >= 0, dx < line.count, line[dx] != "." { return self }
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { controller?.showMenu(for: event, in: self) }
}

/// One entry in the pet's daily routine: how likely it is and how long it lasts.
struct RoutineEntry {
    let activity: Activity
    let weight: Int
    let range: ClosedRange<TimeInterval>
}

/// Decides what the pet does each frame and moves it around the screen.
final class PetController {
    static let scale: CGFloat = 4
    let size = CGFloat(canvasW) * PetController.scale
    let panel: PetPanel
    let view: PetView
    let model = PetModel.shared

    var menuProvider: (() -> NSMenu)?

    /// Long stretches of work, broken up by short treats.
    static let routine: [RoutineEntry] = [
        RoutineEntry(activity: .code, weight: 12, range: 120...300),
        RoutineEntry(activity: .walk, weight: 7, range: 70...180),
        RoutineEntry(activity: .ponder, weight: 5, range: 60...150),
        RoutineEntry(activity: .idle, weight: 4, range: 40...90),
        RoutineEntry(activity: .eat, weight: 3, range: 14...26),
        RoutineEntry(activity: .coffee, weight: 3, range: 18...32),
        RoutineEntry(activity: .play, weight: 2, range: 14...26),
        RoutineEntry(activity: .dance, weight: 1, range: 9...16)
    ]

    private(set) var pos: CGPoint
    private var home: CGPoint
    private(set) var activity: Activity = .idle {
        didSet { if oldValue != activity { animStart = Date(); lastFrameIndex = -1 } }
    }
    private var animStart = Date()
    private var lastFrameIndex = -1
    private var facingLeft = false

    private var subActivity: Activity = .idle
    private var subActivityUntil = Date.distantPast
    private var wanderTarget: CGPoint?
    private var wanderPauseUntil = Date.distantPast
    private var pettedUntil = Date.distantPast
    private var chaseParked = false
    var forcedActivity: Activity?
    var forcedUntil = Date.distantPast
    var demoMode = false
    private var demoIndex = 0
    private var demoNext = Date.distantPast
    private static let demoCast = Activity.allCases.filter { $0 != .chase }

    private var dragStart: CGPoint?
    private var dragOffset = CGPoint.zero
    private var dragged = false
    private var editorFrontSince: Date?
    private var stepTimer: Timer?
    private var secondTimer: Timer?

    static let editorBundleIDs = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed"
    ]

    init() {
        panel = PetPanel(size: size)
        view = PetView(scale: PetController.scale)
        panel.contentView = view
        home = Prefs.home ?? PetController.defaultHome(size: size)
        pos = home
        view.controller = self
        view.grid = Sprites.animation(.idle, bloated: false, sweat: false).frames[0]
        model.onAttention = { [weak self] s in self?.attentionArrived(s) }
    }

    static func defaultHome(size: CGFloat) -> CGPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: vf.maxX - size - 16, y: vf.minY + 4)
    }

    func start() {
        panel.setFrameOrigin(pos)
        panel.orderFrontRegardless()
        stepTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(stepTimer!, forMode: .common)
        secondTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.model.tick()
            self.view.toolTip = self.tooltip()
        }
        RunLoop.main.add(secondTimer!, forMode: .common)
    }

    func resetHome() {
        home = PetController.defaultHome(size: size)
        Prefs.home = nil
    }

    func force(_ a: Activity, seconds: TimeInterval = 10) {
        forcedActivity = a
        forcedUntil = Date().addingTimeInterval(seconds)
    }

    private func attentionArrived(_ s: Session) {
        if Prefs.playSound { NSSound(named: "Pop")?.play() }
    }

    /// Pixels per second. Wandering is a slow amble; the chase is urgent.
    private func speed(for a: Activity) -> CGFloat {
        switch a {
        case .chase: return 520
        case .walk: return 26
        default: return 140
        }
    }

    // MARK: Frame loop

    private func step() {
        let now = Date()
        if dragStart == nil {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let editorFront = PetController.editorBundleIDs.contains(front)
            if editorFront {
                if editorFrontSince == nil { editorFrontSince = now }
                // Back in the editor for a while: sessions that were already waiting
                // when you returned are marked seen. Ones that finish while you are
                // here stay until you click the pet.
                if Prefs.calmWhenEditorFront, let since = editorFrontSince,
                   now.timeIntervalSince(since) > 8, model.hasAttention {
                    model.acknowledgeAll(before: since)
                }
            } else {
                editorFrontSince = nil
            }
            // Hidden behind the editor, unless a session needs you and peeking is on.
            let peek = Prefs.peekWhenAttention && model.hasAttention
            let shouldHide = Prefs.hideWhenEditorFront && editorFront && !demoMode && !peek
            if shouldHide {
                if panel.isVisible { panel.orderOut(nil) }
                return
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }

        var (chosen, target) = chooseActivity(now)
        if dragStart != nil { target = nil }

        if let t = target {
            let dx = t.x - pos.x, dy = t.y - pos.y
            let dist = hypot(dx, dy)
            let stepLen = speed(for: chosen) / 30
            if dist > stepLen {
                pos.x += dx / dist * stepLen
                pos.y += dy / dist * stepLen
                if abs(dx) > 2 { facingLeft = dx < 0 }
                // A long trip home overrides whatever it was doing: it walks there.
                if !chosen.isReaction, chosen != .walk, dist > 14 { chosen = .walk }
            } else {
                pos = t
            }
        }
        pos = clamp(pos)
        if panel.frame.origin != pos { panel.setFrameOrigin(pos) }

        activity = chosen
        let anim = Sprites.animation(activity, bloated: model.isBloated, sweat: model.weeklyHigh)
        let idx = Int(now.timeIntervalSince(animStart) / anim.frameDuration) % anim.frames.count
        if idx != lastFrameIndex {
            lastFrameIndex = idx
            view.grid = anim.frames[idx]
        }
        view.mirrored = facingLeft
        let deco: [Overlay] = model.mess ? [Overlays.mess] : []
        if deco.count != view.decorations.count { view.decorations = deco }
    }

    private func chooseActivity(_ now: Date) -> (Activity, CGPoint?) {
        if demoMode {
            if now > demoNext {
                demoIndex = (demoIndex + 1) % PetController.demoCast.count
                demoNext = now.addingTimeInterval(3)
            }
            return (PetController.demoCast[demoIndex], home)
        }
        if let f = forcedActivity, now < forcedUntil { return (f, nil) }
        if model.isFainted { return (.fainted, home) }
        if let s = model.attentionSessions.first {
            // Chase the cursor, then park once close so it is easy to click. It only
            // sets off again if the cursor wanders far away.
            let m = NSEvent.mouseLocation
            let center = CGPoint(x: pos.x + size / 2, y: pos.y + size / 2)
            let cursorDist = hypot(m.x - center.x, m.y - center.y)
            if chaseParked && cursorDist > 260 { chaseParked = false }
            if !chaseParked {
                if cursorDist < 90 {
                    chaseParked = true
                } else {
                    let t = cursorTarget()
                    if hypot(t.x - pos.x, t.y - pos.y) > 10 { return (.chase, t) }
                    chaseParked = true
                }
            }
            return (s.attention == .permission ? .ask : .alert, nil)
        }
        chaseParked = false
        if now < pettedUntil { return (.petted, nil) }
        if now < model.thinkingUntil { return (.thinking, nil) }

        if !model.workingSessions.isEmpty {
            if now > subActivityUntil { pickRoutine(now) }
            if subActivity == .walk { return wander(now) }
            if subActivity == .idle && model.isTired { return (.sick, nil) }
            return (subActivity, nil)
        }

        if model.isSad { return (.sad, home) }
        if model.isTired { return (.sick, home) }
        if now.timeIntervalSince(model.lastActivityAt) > 90 { return (.sleep, home) }
        return (.idle, home)
    }

    /// Weighted pick, never the same activity twice in a row.
    private func pickRoutine(_ now: Date) {
        let pool = PetController.routine.filter { $0.activity != subActivity }
        let total = pool.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<max(total, 1))
        var pickedEntry = pool.last ?? PetController.routine[0]
        for entry in pool {
            if roll < entry.weight { pickedEntry = entry; break }
            roll -= entry.weight
        }
        subActivity = pickedEntry.activity
        subActivityUntil = now.addingTimeInterval(Double.random(in: pickedEntry.range))
        wanderTarget = nil
        wanderPauseUntil = .distantPast
    }

    /// Ambles left and right around home, pausing between legs of the trip.
    private func wander(_ now: Date) -> (Activity, CGPoint?) {
        if now < wanderPauseUntil { return (.idle, nil) }
        if let t = wanderTarget {
            if abs(t.x - pos.x) < 2 {
                wanderTarget = nil
                wanderPauseUntil = now.addingTimeInterval(Double.random(in: 2...5))
                return (.idle, nil)
            }
            return (.walk, t)
        }
        var nx = home.x + CGFloat.random(in: -170...170)
        if abs(nx - pos.x) < 70 { nx = pos.x + (nx > pos.x ? 90 : -90) }
        let t = clamp(CGPoint(x: nx, y: home.y))
        wanderTarget = t
        return (.walk, t)
    }

    private func cursorTarget() -> CGPoint {
        let m = NSEvent.mouseLocation
        return clamp(CGPoint(x: m.x + 18, y: m.y - size - 6), around: m)
    }

    private func clamp(_ p: CGPoint, around anchor: CGPoint? = nil) -> CGPoint {
        let ref = anchor ?? CGPoint(x: p.x + size / 2, y: p.y + size / 2)
        let screen = NSScreen.screens.first { NSPointInRect(ref, $0.frame) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return p }
        return CGPoint(x: min(max(p.x, vf.minX), vf.maxX - size),
                       y: min(max(p.y, vf.minY), vf.maxY - size))
    }

    private func tooltip() -> String {
        var lines = ["Clawd: \(model.moodLine)"]
        lines.append("Doing: \(activity.label)")
        var stats: [String] = []
        if let f = model.fiveHour { stats.append("Energy \(Int(100 - f.used))%") }
        if let w = model.sevenDay { stats.append("Weekly \(Int(w.used))%") }
        stats.append("Happiness \(Int(model.happiness))")
        lines.append(stats.joined(separator: " · "))
        if model.mess { lines.append("Click to clean up after the compaction") }
        return lines.joined(separator: "\n")
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        let m = NSEvent.mouseLocation
        dragStart = m
        dragOffset = CGPoint(x: m.x - pos.x, y: m.y - pos.y)
        dragged = false
    }

    func mouseDragged(_ event: NSEvent) {
        guard let start = dragStart else { return }
        let m = NSEvent.mouseLocation
        if hypot(m.x - start.x, m.y - start.y) > 4 { dragged = true }
        if dragged {
            pos = clamp(CGPoint(x: m.x - dragOffset.x, y: m.y - dragOffset.y))
            panel.setFrameOrigin(pos)
        }
    }

    func mouseUp(_ event: NSEvent) {
        defer { dragStart = nil }
        if dragged {
            home = pos
            Prefs.home = home
            wanderTarget = nil
            return
        }
        clicked()
    }

    private func clicked() {
        if model.mess {
            model.cleanMess()
            pettedUntil = Date().addingTimeInterval(1.5)
            return
        }
        if let s = model.acknowledgeOne() {
            PetController.openInEditor(cwd: s.cwd)
            pettedUntil = Date().addingTimeInterval(1.5)
            offerAccessibilityOnce()
            return
        }
        model.pet()
        pettedUntil = Date().addingTimeInterval(2.4)
    }

    /// One-time nudge: without Accessibility we can only bring the editor forward,
    /// not the exact window Claude is running in.
    private func offerAccessibilityOnce() {
        guard !WindowRaiser.isTrusted, !Prefs.offeredAccessibility else { return }
        Prefs.offeredAccessibility = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Raise the exact VS Code window?"
        a.informativeText = "Right now Clawd can only bring VS Code to the front. With Accessibility permission it can find the window that already has the project open and bring that one forward.\n\nTick ClawdPet under System Settings > Privacy & Security > Accessibility. You can do this later from the Settings menu."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Not now")
        if a.runModal() == .alertFirstButtonReturn {
            WindowRaiser.requestTrust()
            WindowRaiser.openAccessibilitySettings()
        }
    }

    func showMenu(for event: NSEvent, in view: NSView) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// Best case: raise the window that already has this project open (needs
    /// Accessibility). Otherwise just bring the editor, or failing that a terminal,
    /// to the front with all its windows. It never opens the folder itself: VS Code
    /// answers that with a second window.
    static func openInEditor(cwd: String) {
        if WindowRaiser.raise(cwd: cwd) { return }
        let running = NSWorkspace.shared.runningApplications
        let ids = editorBundleIDs + WindowRaiser.terminalBundleIDs
        guard let app = ids.lazy.compactMap({ id in running.first { $0.bundleIdentifier == id } }).first else { return }
        app.activate(options: [.activateAllWindows])
    }
}
