import AppKit

// 8-bit sprite system. Every frame is a 24x24 grid of palette characters.
// "." is transparent. The pet body is composed from parts so one body
// definition drives every animation.
//
// Contrast rule: nothing is drawn in a colour that only works on one
// background. Props use mid tones (they read on both black and white) and
// anything white or near black is enclosed by a dark outline.

typealias Grid = [[Character]]
let canvasW = 24
let canvasH = 24

enum Palette {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let colors: [Character: NSColor] = [
        "o": hex(0xD97757), // Clawd orange
        "l": hex(0xF3A984), // highlight
        "d": hex(0xB4522F), // shade / feet
        "k": hex(0x1E1A17), // ink: eyes, outlines
        "w": hex(0xFFFFFF), // white, only ever inside an outline
        "p": hex(0xF2A5A5), // blush / small hearts
        "r": hex(0xE5484D), // red
        "y": hex(0xE0A03A), // amber
        "g": hex(0x63B96F), // green
        "t": hex(0xC98A5A), // tan: cookie, mess
        "b": hex(0x7A4A2B), // dark brown: chips, coffee
        "s": hex(0x6E7A8F), // slate
        "h": hex(0x9AA7BC), // light slate
        "n": hex(0x4A78D9), // mid blue: Zs, sweat, tears, bed
        "u": hex(0x2E4E9E), // dark blue outline
        "q": hex(0xC4917A), // sickly body: washed-out orange
        "v": hex(0x9A6A55), // sickly shade
        "j": hex(0xDDB3A0)  // sickly highlight
    ]
}

enum Eyes { case open, blink, happy, droopy, x, sad, wink, down, angry }
enum Legs { case stand, walkA, walkB, tuck, spread, dangleA, dangleB }
enum Mouth { case none, open, small, smile, frown }

struct Look {
    var eyes: Eyes = .open
    var legs: Legs = .stand
    var mouth: Mouth = .none
    var bloated = false
    var squash = 0   // rows flattened off the top of the body
    var lift = 0     // rows lifted off the ground (jumping)
    var sick = false // green-tinted body
    var hidden = false // no body at all (the curled-up ball is an overlay)
}

struct Overlay {
    let rows: [String]
    let x: Int
    let y: Int
    let id: String
    /// Glyphs like "?" and "Z" must not be flipped when the pet faces left.
    let keepOrientation: Bool
    init(_ rows: [String], x: Int, y: Int, id: String = "", keepOrientation: Bool = false) {
        self.rows = rows
        self.x = x
        self.y = y
        self.id = id
        self.keepOrientation = keepOrientation
    }
}

enum Overlays {
    static func bang(y: Int = 2) -> Overlay { Overlay(["rr", "rr", "rr", "rr", "..", "rr"], x: 11, y: y, id: "bang") }
    static func query(y: Int = 1) -> Overlay {
        Overlay([".yyyy.",
                 "yy..yy",
                 "....yy",
                 "...yy.",
                 "..yy..",
                 "......",
                 "..yy.."], x: 9, y: y, id: "query", keepOrientation: true)
    }

    // Sleep: three Zs marching up and to the right.
    static func zSmall(x: Int, y: Int) -> Overlay { Overlay(["nn", ".n", "nn"], x: x, y: y, id: "z", keepOrientation: true) }
    static func zMed(x: Int, y: Int) -> Overlay { Overlay(["nnn", "..n", ".n.", "nnn"], x: x, y: y, id: "z", keepOrientation: true) }
    static func zBig(x: Int, y: Int) -> Overlay {
        Overlay(["nnnn", "...n", "..n.", ".n..", "nnnn"], x: x, y: y, id: "z", keepOrientation: true)
    }

    // Dog bed: a low cushion in front of the pet with slightly raised ends. Nothing behind the head.
    static let bed = Overlay([".uuu............uuu.",
                              "unnnuuuuuuuuuuuunnnu",
                              "unnnnnnnnnnnnnnnnnnu",
                              "unhhhhhhhhhhhhhhhhnu",
                              ".uuuuuuuuuuuuuuuuuu."], x: 1, y: 19, id: "bed")

    // Props
    static let cookieFull = Overlay([".kkkk.", "kttttk", "ktbttk", "kttbtk", "ktttbk", ".kkkk."],
                                    x: 0, y: 16, id: "food")
    static let cookieBitten = Overlay([".kkk.", "ktttk", "ktbtk", "kttbk", ".kkk."], x: 0, y: 17, id: "food")
    static let cookieCrumb = Overlay([".kk.", "kttk", ".kk."], x: 1, y: 19, id: "food")
    static func ball(x: Int, y: Int) -> Overlay {
        Overlay([".rrr.", "rwrrr", "rrrrr", "rrrrr", ".rrr."], x: x, y: y, id: "ball")
    }
    static let mug = Overlay(["rrrrr..",
                              "rbbbr..",
                              "rrrrrrr",
                              "rrrrr.r",
                              "rrrrr.r",
                              "rrrrrrr",
                              "rrrrr.."], x: 0, y: 15, id: "mug")
    static func steam(_ a: Bool) -> Overlay {
        Overlay(a ? [".h.", "h..", ".h."] : ["h..", ".h.", "h.."], x: 1, y: 11, id: "steam")
    }
    /// Thought bubbles: a trail of blue dots up to a cloud with up to three white dots inside.
    static func thought(_ dots: Int) -> Overlay {
        var inner = Array("ssssss")
        for i in 0..<min(max(dots, 0), 3) { inner[1 + i * 2] = "w" }
        return Overlay([".ssss.", "ssssss", String(inner), ".ssss."], x: 17, y: 0, id: "thought")
    }
    static let thoughtTrail = Overlay(["ss", "ss"], x: 17, y: 5, id: "thought")
    static let thoughtDot = Overlay(["s"], x: 16, y: 8, id: "thought")
    static func note(x: Int, y: Int) -> Overlay {
        Overlay(["..nn", "..n.", "nnn.", "nn.."], x: x, y: y, id: "note", keepOrientation: true)
    }
    static let mess = Overlay(["..t..", ".ttt.", "ttttt"], x: 19, y: 20, id: "mess")

    // Feelings
    static let anger = Overlay(["r.r", ".r.", "r.r"], x: 18, y: 5, id: "anger")
    static func dust(x: Int) -> Overlay { Overlay([".h.", "h.h"], x: x, y: 20, id: "dust") }
    static func sweat(x: Int = 20, y: Int = 12) -> Overlay { Overlay([".n", "nn"], x: x, y: y, id: "sweat") }
    static func tear(y: Int) -> Overlay { Overlay([".n", "nn"], x: 8, y: y, id: "tear") }
    static func heart(x: Int, y: Int) -> Overlay { Overlay([".r.r.", "rrrrr", ".rrr.", "..r.."], x: x, y: y, id: "heart") }
    static func smallHeart(x: Int, y: Int) -> Overlay { Overlay(["p.p", "ppp", ".p."], x: x, y: y, id: "heart") }
    static func dots(_ n: Int) -> Overlay {
        Overlay([(0..<n).map { _ in "n" }.joined(separator: ".")], x: 13, y: 7, id: "dots")
    }

    /// Curled into a ball for a toss. `step` 0...3 turns the four tucked feet by 22.5°
    /// each, which reads as a spin. The highlight and shade stay put: the light does
    /// not travel with him.
    static func curled(step: Int) -> Overlay {
        let n = 12
        var rows = Array(repeating: Array(repeating: Character("."), count: n), count: n)
        let c = Double(n - 1) / 2
        func diff(_ a: Double, _ b: Double) -> Double {
            var d = a - b
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            return abs(d)
        }
        for y in 0..<n {
            for x in 0..<n {
                let dx = Double(x) - c, dy = Double(y) - c
                let r = (dx * dx + dy * dy).squareRoot()
                guard r <= 5.9 else { continue }
                let a = atan2(dy, dx)                       // y grows downward
                var ch: Character = "o"
                if r >= 3.0, diff(a, -2.356) < 0.5 { ch = "l" }   // highlight, upper left
                if r >= 4.9, diff(a, 0.785) < 1.1 { ch = "d" }    // shade, lower right
                rows[y][x] = ch
            }
        }
        for k in 0..<4 {
            let a = Double(step) * (.pi / 8) + Double(k) * (.pi / 2)
            let x = Int((c + 4.0 * cos(a)).rounded()), y = Int((c + 4.0 * sin(a)).rounded())
            if x >= 0, x < n, y >= 0, y < n { rows[y][x] = "d" }
        }
        return Overlay(rows.map { String($0) }, x: 6, y: 9, id: "curled")
    }

    /// Laptop in front of the pet. The base is wider than the screen and the hinge is
    /// a distinct row, which is what makes the silhouette read as a laptop.
    /// `code` is three 6-character screen rows, `paws` two keyboard columns out of ten.
    static func laptop(code: [String], paws: [Int]) -> Overlay {
        var keys = Array(repeating: Character("s"), count: 10)
        for p in paws where p >= 0 && p < 10 { keys[p] = "o" }
        var rows = ["..kkkkkkkk.."]
        for line in code { rows.append("..k" + line + "k..") }
        rows.append(".kkkkkkkkkk.")
        rows.append("k" + String(keys) + "k")
        return Overlay(rows, x: 6, y: 18, id: "laptop")
    }

}

/// Builds one frame from a body description plus decorations. With `mirrored` the
/// body and its props face left; glyph overlays keep their orientation.
func compose(_ look: Look, overlays: [Overlay], underlays: [Overlay] = [], mirrored: Bool = false) -> Grid {
    func blank() -> Grid { Array(repeating: Array(repeating: Character("."), count: canvasW), count: canvasH) }
    func stamp(_ o: Overlay, into g: inout Grid) {
        for (dy, line) in o.rows.enumerated() {
            for (dx, ch) in line.enumerated() where ch != "." {
                let y = o.y + dy, x = o.x + dx
                guard y >= 0, y < canvasH, x >= 0, x < canvasW else { continue }
                g[y][x] = ch
            }
        }
    }
    var g = blank()
    for o in underlays { stamp(o, into: &g) }
    if !look.hidden { drawBody(look, into: &g) }
    if look.sick {
        let tint: [Character: Character] = ["o": "q", "d": "v", "l": "j"]
        for y in 0..<canvasH { for x in 0..<canvasW { if let t = tint[g[y][x]] { g[y][x] = t } } }
    }
    if mirrored { g = g.map { Array($0.reversed()) } }

    var layer = blank()
    var fixed: [Overlay] = []
    for o in overlays {
        if o.keepOrientation { fixed.append(o) } else { stamp(o, into: &layer) }
    }
    if mirrored { layer = layer.map { Array($0.reversed()) } }
    for y in 0..<canvasH { for x in 0..<canvasW where layer[y][x] != "." { g[y][x] = layer[y][x] } }
    for o in fixed { stamp(o, into: &g) }
    return g
}

/// The pet itself: body, eyes, mouth and feet.
private func drawBody(_ look: Look, into g: inout Grid) {

    let ox = 4
    let oy = 9 - look.lift
    let e = look.bloated ? 1 : 0
    let sq = look.squash

    func put(_ r: Int, _ c: Int, _ ch: Character) {
        let y = oy + r, x = ox + c
        guard y >= 0, y < canvasH, x >= 0, x < canvasW else { return }
        g[y][x] = ch
    }
    func row(_ r: Int, _ from: Int, _ to: Int, shadeLast: Bool = true) {
        guard r > sq else { return }
        for c in from...to { put(r, c, (shadeLast && c == to) ? "d" : "o") }
    }

    // Body: a squat rounded blob, 12 wide, with a shaded right edge.
    row(1, 4 - e, 11 + e, shadeLast: false)
    row(2, 3 - e, 12 + e, shadeLast: false)
    for r in 3...10 { row(r, 2 - e, 13 + e) }
    row(11, 3 - e, 12 + e)
    row(12, 4 - e, 11 + e)
    if sq < 2 { put(2, 4 - e, "l"); put(2, 5 - e, "l") }
    if sq < 3 { put(3, 3 - e, "l") }

    // Eyes: tall 2x3 rectangles like the Claude Code mascot.
    let er = 5 + sq
    let left = [4, 5], right = [10, 11]
    func eyeRows(_ rows: [Int], cols: [Int]) {
        for r in rows { for c in cols { put(r, c, "k") } }
    }
    switch look.eyes {
    case .open: eyeRows([er, er + 1, er + 2], cols: left + right)
    case .blink: eyeRows([er + 2], cols: left + right)
    case .happy:
        eyeRows([er], cols: left + right)
        put(er + 2, 3, "p"); put(er + 2, 12, "p")
    case .droopy: eyeRows([er + 1, er + 2], cols: left + right)
    case .down: eyeRows([er + 2, er + 3], cols: left + right)
    case .x:
        for a in [3, 9] {
            put(er, a, "k"); put(er, a + 2, "k")
            put(er + 1, a + 1, "k")
            put(er + 2, a, "k"); put(er + 2, a + 2, "k")
        }
    case .sad:
        eyeRows([er + 1, er + 2], cols: left + right)
        put(er + 3, 5, "n"); put(er + 4, 5, "n")
    case .wink:
        eyeRows([er, er + 1, er + 2], cols: left)
        eyeRows([er + 2], cols: right)
    case .angry:
        // Narrowed eyes under brows that slant down toward the middle.
        eyeRows([er + 1, er + 2], cols: left + right)
        put(er - 2, 3, "k"); put(er - 1, 4, "k"); put(er, 5, "k")
        put(er - 2, 12, "k"); put(er - 1, 11, "k"); put(er, 10, "k")
    }

    // Mouth
    let mr = 9 + sq
    switch look.mouth {
    case .none: break
    case .open: for r in [mr, mr + 1] { put(r, 7, "k"); put(r, 8, "k") }
    case .small: put(mr, 7, "k"); put(mr, 8, "k")
    case .smile: put(mr - 1, 6, "k"); put(mr - 1, 9, "k"); put(mr, 7, "k"); put(mr, 8, "k")
    case .frown: put(mr, 6, "k"); put(mr, 9, "k"); put(mr - 1, 7, "k"); put(mr - 1, 8, "k")
    }

    // Feet. Dangling legs (picked up) are two pixels long, and their tips swing
    // outward and inward on alternate frames so they jiggle.
    let feet: [Int]
    var tips: [Int] = []
    switch look.legs {
    case .stand: feet = [4, 6, 9, 11]
    case .walkA: feet = [3, 6, 9, 12]
    case .walkB: feet = [5, 6, 9, 10]
    case .spread: feet = [2, 5, 10, 13]
    case .tuck: feet = []
    case .dangleA: feet = [4, 6, 9, 11]; tips = [3, 6, 9, 12]
    case .dangleB: feet = [4, 6, 9, 11]; tips = [5, 7, 8, 10]
    }
    for c in feet { put(13, c, "d") }
    for c in tips { put(14, c, "d") }
}

enum Activity: String, CaseIterable {
    case idle, sleep, walk, code, ponder, eat, play, coffee, dance
    case chase, alert, ask, sick, fainted, sad, petted, thinking, carried
    case tossed, splat, grumpy

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .sleep: return "Sleeping in its bed"
        case .walk: return "Wandering"
        case .code: return "Typing on its laptop"
        case .ponder: return "Thinking"
        case .eat: return "Eating a cookie"
        case .play: return "Playing with a ball"
        case .coffee: return "Coffee break"
        case .dance: return "Dancing"
        case .chase: return "Chasing the mouse"
        case .alert: return "Claude finished"
        case .ask: return "Claude needs permission"
        case .sick: return "Sick (usage limit close)"
        case .fainted: return "Fainted (usage limit hit)"
        case .sad: return "Sad (neglected)"
        case .petted: return "Being petted"
        case .thinking: return "Compacting"
        case .carried: return "Picked up"
        case .tossed: return "Thrown across the screen"
        case .splat: return "Landed hard"
        case .grumpy: return "Sulking"
        }
    }

    /// Reactions are triggered by Claude, never chosen at random.
    var isReaction: Bool {
        switch self {
        case .chase, .alert, .ask, .fainted, .sad, .petted, .thinking, .carried, .tossed, .splat, .grumpy: return true
        default: return false
        }
    }
}

struct Animation {
    let frames: [Grid]
    let frameDuration: TimeInterval
}

struct FrameSpec {
    var look: Look
    var overlays: [Overlay]
    var underlays: [Overlay]
    init(_ look: Look, _ overlays: [Overlay] = [], under: [Overlay] = []) {
        self.look = look
        self.overlays = overlays
        self.underlays = under
    }
}

enum Sprites {
    private static var cache: [String: Animation] = [:]

    static func animation(_ a: Activity, bloated: Bool, sweat: Bool, mirrored: Bool = false) -> Animation {
        let key = "\(a.rawValue)-\(bloated)-\(sweat)-\(mirrored)"
        if let hit = cache[key] { return hit }
        var specs = frameSpecs(a)
        for i in specs.indices {
            if bloated { specs[i].look.bloated = true }
            if sweat || bloated, !specs[i].overlays.contains(where: { $0.id == "sweat" }) {
                specs[i].overlays.append(Overlays.sweat(x: 21, y: 12))
            }
        }
        let anim = Animation(frames: specs.map { compose($0.look, overlays: $0.overlays, underlays: $0.underlays, mirrored: mirrored) },
                             frameDuration: frameDuration(a))
        cache[key] = anim
        return anim
    }

    /// Seconds per frame. Deliberately slow: the pet should not twitch every second.
    static func frameDuration(_ a: Activity) -> TimeInterval {
        switch a {
        case .idle: return 1.0
        case .sleep: return 1.4
        case .walk: return 0.34
        case .code: return 0.5
        case .ponder: return 1.0
        case .eat: return 0.55
        case .play: return 0.3
        case .coffee: return 0.9
        case .dance: return 0.34
        case .chase: return 0.16
        case .alert: return 0.28
        case .ask: return 0.32
        case .sick: return 1.0
        case .fainted: return 1.0
        case .sad: return 1.1
        case .petted: return 0.35
        case .thinking: return 0.5
        case .carried: return 0.12
        case .tossed: return 0.07
        case .splat: return 0.9
        case .grumpy: return 0.7
        }
    }

    static func frameSpecs(_ a: Activity) -> [FrameSpec] {
        typealias F = FrameSpec
        let O = Overlays.self
        switch a {
        case .idle:
            // Slow breathing: the body settles by one row and rises again.
            return [F(Look()), F(Look()), F(Look(squash: 1)), F(Look(squash: 1)), F(Look()), F(Look(eyes: .blink))]
        case .sleep:
            let z1 = O.zSmall(x: 19, y: 11), z2 = O.zMed(x: 19, y: 6), z3 = O.zBig(x: 20, y: 0)
            return [F(Look(eyes: .blink, legs: .tuck), [O.bed, z1]),
                    F(Look(eyes: .blink, legs: .tuck), [O.bed, z1, z2]),
                    F(Look(eyes: .blink, legs: .tuck, squash: 1), [O.bed, z1, z2, z3]),
                    F(Look(eyes: .blink, legs: .tuck, squash: 1), [O.bed, z2, z3]),
                    F(Look(eyes: .blink, legs: .tuck), [O.bed, z3]),
                    F(Look(eyes: .blink, legs: .tuck), [O.bed])]
        case .walk:
            return [F(Look(legs: .walkA, lift: 1)), F(Look(legs: .stand)),
                    F(Look(legs: .walkB, lift: 1)), F(Look(legs: .stand))]
        case .code:
            let screens = [["kkkkhh", "kkhhhh", "hhhhhh"],
                           ["kkkkhh", "kkhkkh", "hhhhhh"],
                           ["kkhkkh", "kkkhhh", "khhhhh"],
                           ["kkkhhh", "khhhhh", "kkkkgh"]]
            let paws = [[1, 5], [2, 6], [1, 7], [3, 5]]
            return (0..<4).map { i in
                F(Look(eyes: i == 3 ? .blink : .open, mouth: .small), [O.laptop(code: screens[i], paws: paws[i])])
            }
        case .ponder:
            let trail = [O.thoughtDot, O.thoughtTrail]
            return [F(Look(mouth: .small), trail + [O.thought(1)]),
                    F(Look(mouth: .small), trail + [O.thought(2)]),
                    F(Look(mouth: .small), trail + [O.thought(3)]),
                    F(Look(eyes: .blink, mouth: .small), trail + [O.thought(3)]),
                    F(Look(mouth: .small, squash: 1), trail + [O.thought(0)])]
        case .eat:
            return [F(Look(mouth: .open), [O.cookieFull]),
                    F(Look(eyes: .happy, mouth: .small), [O.cookieBitten]),
                    F(Look(mouth: .open), [O.cookieBitten]),
                    F(Look(eyes: .happy, mouth: .small), [O.cookieCrumb]),
                    F(Look(mouth: .open), [O.cookieCrumb]),
                    F(Look(eyes: .happy, mouth: .smile))]
        case .play:
            return [F(Look(), [O.ball(x: 18, y: 19)]),
                    F(Look(legs: .tuck, lift: 1), [O.ball(x: 18, y: 14)]),
                    F(Look(eyes: .happy, legs: .tuck, lift: 2), [O.ball(x: 18, y: 9)]),
                    F(Look(legs: .tuck, lift: 1), [O.ball(x: 18, y: 14)])]
        case .coffee:
            return [F(Look(eyes: .happy, mouth: .small), [O.mug, O.steam(true)]),
                    F(Look(eyes: .happy, mouth: .small), [O.mug, O.steam(false)]),
                    F(Look(mouth: .small), [O.mug, O.steam(true)]),
                    F(Look(eyes: .blink, mouth: .small), [O.mug, O.steam(false)])]
        case .dance:
            return [F(Look(eyes: .happy, legs: .walkA, lift: 1), [O.note(x: 1, y: 7)]),
                    F(Look(eyes: .happy, legs: .walkB), [O.note(x: 19, y: 5)]),
                    F(Look(eyes: .happy, legs: .walkB, lift: 1), [O.note(x: 19, y: 7)]),
                    F(Look(eyes: .happy, legs: .walkA), [O.note(x: 1, y: 5)])]
        case .chase:
            return [F(Look(legs: .walkA), [O.bang()]), F(Look(legs: .walkB), [O.bang(y: 2)])]
        case .alert:
            return [F(Look(), [O.bang()]),
                    F(Look(legs: .tuck, lift: 2), [O.bang(y: 0)]),
                    F(Look(), [O.bang()]),
                    F(Look(eyes: .wink, mouth: .smile), [O.bang()])]
        case .ask:
            return [F(Look(), [O.query()]),
                    F(Look(legs: .tuck, lift: 1), [O.query(y: 0)]),
                    F(Look(), [O.query()]),
                    F(Look(eyes: .droopy), [O.query()])]
        case .sick:
            return [F(Look(eyes: .droopy, mouth: .frown, sick: true), [O.sweat()]),
                    F(Look(eyes: .droopy, mouth: .frown, sick: true), [O.sweat(y: 13)]),
                    F(Look(eyes: .blink, mouth: .frown, squash: 1, sick: true), [O.sweat(y: 13)]),
                    F(Look(eyes: .droopy, mouth: .frown, sick: true), [O.sweat(x: 2, y: 12)])]
        case .fainted:
            return [F(Look(eyes: .x, legs: .spread, squash: 2, sick: true)),
                    F(Look(eyes: .x, legs: .spread, squash: 2, sick: true), [O.sweat(y: 13)])]
        case .sad:
            return [F(Look(eyes: .sad, mouth: .frown), [O.tear(y: 17)]),
                    F(Look(eyes: .sad, mouth: .frown), [O.tear(y: 20)])]
        case .petted:
            return [F(Look(eyes: .happy, mouth: .smile), [O.heart(x: 9, y: 3)]),
                    F(Look(eyes: .happy, legs: .tuck, mouth: .smile, lift: 1),
                      [O.heart(x: 9, y: 2), O.smallHeart(x: 2, y: 6), O.smallHeart(x: 19, y: 4)])]
        case .thinking:
            return [F(Look(eyes: .droopy), [O.dots(1)]),
                    F(Look(eyes: .droopy), [O.dots(2)]),
                    F(Look(eyes: .droopy), [O.dots(3)])]
        case .carried:
            // Held up by the scruff: wide eyes, a little "o" mouth, legs dangling and
            // wiggling, and the body bobbing by a pixel.
            return [F(Look(legs: .dangleA, mouth: .open, lift: 1)),
                    F(Look(legs: .dangleB, mouth: .open, lift: 1)),
                    F(Look(legs: .dangleA, mouth: .open, lift: 2)),
                    F(Look(legs: .dangleB, mouth: .open, lift: 2))]
        case .tossed:
            return (0..<4).map { F(Look(hidden: true), [O.curled(step: $0)]) }
        case .splat:
            // Flattened, eyes shut, a puff of dust either side.
            return [F(Look(eyes: .blink, legs: .spread, mouth: .open, squash: 3), [O.dust(x: 1), O.dust(x: 20)])]
        case .grumpy:
            return [F(Look(eyes: .angry, mouth: .frown), [O.anger]),
                    F(Look(eyes: .angry, mouth: .frown)),
                    F(Look(eyes: .angry, mouth: .frown), [O.anger]),
                    F(Look(eyes: .sad, mouth: .frown), [O.tear(y: 17)]),
                    F(Look(eyes: .sad, mouth: .frown), [O.tear(y: 20)]),
                    F(Look(eyes: .angry, mouth: .frown, squash: 1))]
        }
    }
}

// Renders the pet's face for the menu bar and the app icon.
enum IconRenderer {
    private static let cropX = 4..<20   // 16 columns
    private static let cropY = 9..<23   // 14 rows

    static func menuBarImage(size: CGFloat) -> NSImage {
        let g = compose(Look(), overlays: [])
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let cell = size / 16
            for y in cropY {
                for x in cropX {
                    guard let c = Palette.colors[g[y][x]] else { continue }
                    c.setFill()
                    NSRect(x: CGFloat(x - cropX.lowerBound) * cell,
                           y: CGFloat(y - cropY.lowerBound) * cell + cell,
                           width: cell, height: cell).fill()
                }
            }
            return true
        }
        return img
    }

    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let g = compose(Look(), overlays: [])
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)
        ]
        for (name, px) in sizes {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let size = CGFloat(px)
            Palette.hex(0xFBEFE6).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                         xRadius: size * 0.22, yRadius: size * 0.22).fill()
            let cell = size / 20
            let inset = cell * 2
            for y in cropY {
                for x in cropX {
                    guard let c = Palette.colors[g[y][x]] else { continue }
                    c.setFill()
                    let top = CGFloat(y - cropY.lowerBound) * cell + inset + cell
                    NSRect(x: CGFloat(x - cropX.lowerBound) * cell + inset,
                           y: size - top - cell, width: cell, height: cell).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
            }
        }
    }
}

// Debug export: every animation as one row of a sprite sheet PNG, on a chosen background.
enum SheetRenderer {
    static func write(to path: String, background: UInt32 = 0xF4F1EC, scale: Int = 6, mirrored: Bool = false) {
        let acts = Activity.allCases
        let maxFrames = acts.map { Sprites.animation($0, bloated: false, sweat: false, mirrored: mirrored).frames.count }.max() ?? 1
        let cell = canvasW * scale
        let w = maxFrames * cell, h = acts.count * cell
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        Palette.hex(background).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        for (rowIdx, a) in acts.enumerated() {
            let anim = Sprites.animation(a, bloated: false, sweat: false, mirrored: mirrored)
            for (col, frame) in anim.frames.enumerated() {
                let ox = col * cell
                let oyTop = rowIdx * cell
                for (y, line) in frame.enumerated() {
                    for (x, ch) in line.enumerated() {
                        guard let c = Palette.colors[ch] else { continue }
                        c.setFill()
                        let top = oyTop + y * scale
                        NSRect(x: ox + x * scale, y: h - top - scale, width: scale, height: scale).fill()
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
