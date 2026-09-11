import AppKit

/// Appends diagnostics to ~/Library/Logs/ClawdPet.log so raise and alert decisions
/// can be inspected without a debugger.
enum Diag {
    static let path = NSHomeDirectory() + "/Library/Logs/ClawdPet.log"
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func log(_ line: String) {
        let text = "\(fmt.string(from: Date()))  \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); h.closeFile()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard

    static var port: UInt16 {
        let v = d.integer(forKey: "port")
        return v > 0 && v < 65536 ? UInt16(v) : 4242
    }
    static func setPort(_ p: UInt16) { d.set(Int(p), forKey: "port") }

    private static func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? def
    }

    static var hideWhenEditorFront: Bool {
        get { bool("hideWhenEditorFront", default: true) }
        set { d.set(newValue, forKey: "hideWhenEditorFront") }
    }
    static var calmWhenEditorFront: Bool {
        get { bool("calmWhenEditorFront", default: true) }
        set { d.set(newValue, forKey: "calmWhenEditorFront") }
    }
    /// Even while hidden behind the editor, come out when a session needs you.
    static var peekWhenAttention: Bool {
        get { bool("peekWhenAttention", default: true) }
        set { d.set(newValue, forKey: "peekWhenAttention") }
    }
    /// Stay quiet when the session's window is the one in front (needs Accessibility).
    static var skipFrontWindow: Bool {
        get { bool("skipFrontWindow", default: true) }
        set { d.set(newValue, forKey: "skipFrontWindow") }
    }
    static var playSound: Bool {
        get { bool("playSound", default: false) }
        set { d.set(newValue, forKey: "playSound") }
    }
    static var offeredAccessibility: Bool {
        get { bool("offeredAccessibility", default: false) }
        set { d.set(newValue, forKey: "offeredAccessibility") }
    }
    static var offeredInstall: Bool {
        get { bool("offeredInstall", default: false) }
        set { d.set(newValue, forKey: "offeredInstall") }
    }
    static var home: CGPoint? {
        get {
            guard d.object(forKey: "homeX") != nil else { return nil }
            return CGPoint(x: d.double(forKey: "homeX"), y: d.double(forKey: "homeY"))
        }
        set {
            if let p = newValue { d.set(p.x, forKey: "homeX"); d.set(p.y, forKey: "homeY") }
            else { d.removeObject(forKey: "homeX"); d.removeObject(forKey: "homeY") }
        }
    }
    static var happiness: Double {
        get { d.object(forKey: "happiness") as? Double ?? 70 }
        set { d.set(newValue, forKey: "happiness") }
    }
    static var birth: Date {
        if let b = d.object(forKey: "birth") as? Date { return b }
        let now = Date()
        d.set(now, forKey: "birth")
        return now
    }
    static func resetBirth() { d.set(Date(), forKey: "birth") }
    static var totalPets: Int {
        get { d.integer(forKey: "totalPets") }
        set { d.set(newValue, forKey: "totalPets") }
    }
    static var totalFinished: Int {
        get { d.integer(forKey: "totalFinished") }
        set { d.set(newValue, forKey: "totalFinished") }
    }
    static var scanTranscripts: Bool {
        get { bool("scanTranscripts", default: true) }
        set { d.set(newValue, forKey: "scanTranscripts") }
    }
    static var mutedSessions: Set<String> {
        get { Set(d.stringArray(forKey: "mutedSessions") ?? []) }
        set { d.set(Array(newValue), forKey: "mutedSessions") }
    }
}

enum Attention: String {
    case finished, permission, idle

    var label: String {
        switch self {
        case .finished: return "finished"
        case .permission: return "needs permission"
        case .idle: return "waiting for you"
        }
    }
}

struct Session {
    let id: String
    var cwd: String
    var working = false
    var attention: Attention?
    var attentionSince: Date?
    var lastSeen = Date()
    let started = Date()
    var contextUsed: Double?
    var model: String?
    var title: String?
    var hooked = false            // at least one hook event arrived for this session
    var transcriptModified: Date?

    var name: String {
        let n = (cwd as NSString).lastPathComponent
        return n.isEmpty ? "session" : n
    }
    var displayTitle: String { title ?? name }
    var sourceLabel: String { hooked ? "hooks" : "transcript" }
    var watched: Bool { !Prefs.mutedSessions.contains(id) }
}

struct RateLimit {
    var used: Double
    var resetsAt: Date?
}

final class PetModel {
    static let shared = PetModel()

    private(set) var sessions: [String: Session] = [:]
    private var endedAt: [String: Date] = [:]
    var lastScanAt: Date?
    var fiveHour: RateLimit?
    var sevenDay: RateLimit?
    var happiness: Double = Prefs.happiness { didSet { Prefs.happiness = max(0, min(100, happiness)) } }
    var mess = false
    var messSince: Date?
    var lastActivityAt = Date.distantPast
    var thinkingUntil = Date.distantPast
    var nibbles = 0
    private(set) var recentEvents: [String] = []
    private var wasDead = false
    private var loggedStatus = false
    var onChange: (() -> Void)?
    var onAttention: ((Session) -> Void)?
    var onReborn: (() -> Void)?

    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Derived state

    var orderedSessions: [Session] { sessions.values.sorted { $0.lastSeen > $1.lastSeen } }
    var workingSessions: [Session] { orderedSessions.filter { $0.working } }
    var attentionSessions: [Session] {
        orderedSessions.filter { $0.attention != nil && $0.watched }
            .sorted { ($0.attentionSince ?? .distantPast) < ($1.attentionSince ?? .distantPast) }
    }
    var hasAttention: Bool { !attentionSessions.isEmpty }
    var energy: Double { 100 - (fiveHour?.used ?? 0) }
    var isFainted: Bool {
        guard let f = fiveHour, f.used >= 100 else { return false }
        if let r = f.resetsAt { return Date() < r }
        return true
    }
    /// 5-hour limit stages: 0 fine, 1 sick (75%+), 2 very sick (90%+).
    var sickness: Int {
        guard !isFainted, let f = fiveHour else { return 0 }
        if f.used >= 90 { return 2 }
        if f.used >= 75 { return 1 }
        return 0
    }
    var isTired: Bool { sickness >= 1 }
    /// Weekly limit hit: a gravestone until it resets, then he is reborn.
    var isDead: Bool {
        guard let w = sevenDay, w.used >= 100 else { return false }
        if let r = w.resetsAt { return Date() < r }
        return true
    }
    var weeklyHigh: Bool { (sevenDay?.used ?? 0) >= 85 }
    var isBloated: Bool { workingSessions.contains { ($0.contextUsed ?? 0) >= 80 } }
    var isSad: Bool { happiness < 25 }
    var ageDays: Int { Int(Date().timeIntervalSince(Prefs.birth) / 86400) }

    var moodLine: String {
        if isDead { return "RIP: weekly limit hit, " + (sevenDay?.resetsAt.map { "reborn when it " + formatCountdown(to: $0) } ?? "waiting for the reset") }
        if isFainted { return "Fainted: 5-hour limit hit" }
        if let s = attentionSessions.first {
            let extra = attentionSessions.count > 1 ? " (+\(attentionSessions.count - 1) more)" : ""
            return "\(s.name) \(s.attention!.label)\(extra)"
        }
        if isBloated { return "Bloated: context nearly full, try /compact" }
        if !workingSessions.isEmpty { return "Busy with \(workingSessions.count) session\(workingSessions.count == 1 ? "" : "s")" }
        if isSad { return "Sad and neglected" }
        switch sickness {
        case 2: return "Very sick: 5-hour limit at \(Int(fiveHour?.used ?? 0))%"
        case 1: return "Sick: 5-hour limit at \(Int(fiveHour?.used ?? 0))%"
        default: break
        }
        return sessions.isEmpty ? "No Claude sessions" : "Idle"
    }

    // MARK: Hook events

    func handle(event: [String: Any]) {
        guard let name = event["hook_event_name"] as? String,
              let sid = event["session_id"] as? String else { return }
        let cwd = event["cwd"] as? String ?? ""
        let now = Date()
        var s = sessions[sid] ?? Session(id: sid, cwd: cwd)
        s.lastSeen = now
        s.hooked = true
        if !cwd.isEmpty { s.cwd = cwd }
        lastActivityAt = now
        var newAttention: Attention?

        switch name {
        case "SessionStart":
            s.working = false
            s.attention = nil
        case "UserPromptSubmit":
            s.working = true
            s.attention = nil
        case "PreToolUse", "PostToolUse", "PostToolBatch", "SubagentStart", "SubagentStop":
            s.working = true
            nibbles += 1
            // Tools are running again, so any permission prompt has been answered.
            if s.attention == .permission { s.attention = nil; s.attentionSince = nil }
        case "Stop", "StopFailure":
            s.working = false
            if s.attention == nil || s.attention == .permission {
                s.attention = nil
                newAttention = .finished
                Prefs.totalFinished += 1
            }
        case "Notification":
            let type = (event["notification_type"] as? String)
                ?? (event["matcher"] as? String) ?? ""
            let message = (event["message"] as? String ?? "").lowercased()
            Diag.log("Notification \(type.isEmpty ? "(no type)" : type) for \(s.name): \(message.prefix(80))")
            if type == "permission_prompt" || type == "agent_needs_input" || message.contains("permission") {
                s.working = false
                if s.attention != .permission { newAttention = .permission }
            } else if type == "idle_prompt", s.attention == nil {
                s.working = false
                newAttention = .idle
            }
        case "PermissionRequest":
            Diag.log("PermissionRequest for \(s.name): \(event["tool_name"] as? String ?? "?")")
            s.working = false
            if s.attention != .permission { newAttention = .permission }
        case "PreCompact":
            thinkingUntil = now.addingTimeInterval(8)
        case "PostCompact":
            thinkingUntil = now
            mess = true
            messSince = now
        case "SessionEnd":
            sessions.removeValue(forKey: sid)
            endedAt[sid] = now
            log("\(name) \(s.name)")
            onChange?()
            return
        default:
            break
        }
        var seenAlready = false
        if let a = newAttention, userIsLooking(at: s, for: a) {
            // You are looking right at it: nothing to announce.
            newAttention = nil
            seenAlready = true
        }
        if let a = newAttention {
            s.attention = a
            s.attentionSince = now
        }
        sessions[sid] = s
        if name != "PostToolUse" && name != "PreToolUse" { log("\(name) \(s.name)" + (seenAlready ? " (you were looking)" : "")) }
        onChange?()
        if newAttention != nil, s.watched { onAttention?(s) }
    }

    func handle(status: [String: Any]) {
        guard let sid = status["session_id"] as? String else { return }
        var s = sessions[sid] ?? Session(id: sid, cwd: status["cwd"] as? String ?? "")
        s.lastSeen = Date()
        s.hooked = true
        if let cwd = status["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if let m = status["model"] as? [String: Any], let n = m["display_name"] as? String { s.model = n }
        if let cw = status["context_window"] as? [String: Any] {
            if let p = cw["used_percentage"] as? Double { s.contextUsed = p }
            else if let p = cw["used_percentage"] as? Int { s.contextUsed = Double(p) }
        }
        if let rl = status["rate_limits"] as? [String: Any] {
            fiveHour = parseLimit(rl["five_hour"]) ?? fiveHour
            sevenDay = parseLimit(rl["seven_day"]) ?? sevenDay
        }
        if !loggedStatus {
            loggedStatus = true
            Diag.log("first status line: keys \(status.keys.sorted().joined(separator: ",")); rate_limits: \(status["rate_limits"].map { "\($0)" } ?? "absent")")
        }
        sessions[sid] = s
        onChange?()
    }

    /// Merges what the transcript scanner found. Hooked sessions only gain title/cwd;
    /// hook-less sessions get their working/finished state from the transcript.
    func apply(snapshots: [TranscriptSnapshot]) {
        let now = Date()
        lastScanAt = now
        var newlyFinished: [Session] = []
        for snap in snapshots {
            if let ended = endedAt[snap.id], snap.modified <= ended { continue }
            let isNew = sessions[snap.id] == nil
            var s = sessions[snap.id] ?? Session(id: snap.id, cwd: snap.cwd)
            if !snap.cwd.isEmpty { s.cwd = snap.cwd }
            if let t = snap.title { s.title = t }
            s.transcriptModified = snap.modified
            if snap.modified > s.lastSeen { s.lastSeen = snap.modified }
            if !s.hooked {
                let stale = now.timeIntervalSince(snap.modified) > 600
                let wasWorking = s.working
                switch snap.lastKind {
                case .assistantDone:
                    s.working = false
                    if wasWorking, !isNew, s.attention == nil, !userIsLooking(at: s, for: .finished) {
                        s.attention = .finished
                        s.attentionSince = now
                        Prefs.totalFinished += 1
                        newlyFinished.append(s)
                    }
                case .userPrompt:
                    s.working = !stale
                    if !stale { s.attention = nil; s.attentionSince = nil }
                case .toolResult, .assistantWorking:
                    s.working = !stale
                case .unknown:
                    break
                }
                if s.working, snap.modified > lastActivityAt { lastActivityAt = snap.modified }
            }
            sessions[snap.id] = s
        }
        onChange?()
        for s in newlyFinished where s.watched { onAttention?(s) }
    }

    /// True when the user is already looking at this session's window.
    private func userIsLooking(at s: Session, for a: Attention) -> Bool {
        guard Prefs.skipFrontWindow else { return false }
        let looking = WindowRaiser.frontWindowShows(cwd: s.cwd)
        Diag.log("\(s.name) \(a.label); user already looking at it: \(looking)")
        return looking
    }

    private func parseLimit(_ any: Any?) -> RateLimit? {
        guard let d = any as? [String: Any] else { return nil }
        let used: Double
        if let u = d["used_percentage"] as? Double { used = u }
        else if let u = d["used_percentage"] as? Int { used = Double(u) }
        else { return nil }
        var reset: Date?
        if let r = d["resets_at"] as? Double { reset = Date(timeIntervalSince1970: r) }
        else if let r = d["resets_at"] as? Int { reset = Date(timeIntervalSince1970: Double(r)) }
        return RateLimit(used: used, resetsAt: reset)
    }

    // MARK: Interactions

    /// Clears the oldest attention request and returns its session.
    @discardableResult
    func acknowledgeOne() -> Session? {
        guard let s = attentionSessions.first else { return nil }
        if let since = s.attentionSince, Date().timeIntervalSince(since) < 180 { happiness += 5 }
        var m = s
        m.attention = nil
        m.attentionSince = nil
        sessions[s.id] = m
        onChange?()
        return s
    }

    func acknowledge(id: String) {
        guard var s = sessions[id] else { return }
        s.attention = nil
        s.attentionSince = nil
        sessions[id] = s
        onChange?()
    }

    /// Calms every request that arrived before `cutoff` (you are back in the editor).
    /// Requests that arrive while you are already there are left alone.
    func acknowledgeAll(before cutoff: Date) {
        var changed = false
        for (id, s) in sessions where s.attention != nil && (s.attentionSince ?? .distantPast) < cutoff {
            var m = s
            m.attention = nil
            m.attentionSince = nil
            sessions[id] = m
            changed = true
        }
        if changed { onChange?() }
    }

    func toggleMute(id: String) {
        var muted = Prefs.mutedSessions
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        Prefs.mutedSessions = muted
        onChange?()
    }

    func pet() {
        happiness += 12
        Prefs.totalPets += 1
        onChange?()
    }

    func thrown() {
        happiness -= 15
        log("Thrown across the screen")
        onChange?()
    }

    func cleanMess() {
        mess = false
        messSince = nil
        happiness += 5
        onChange?()
    }

    func removeSession(id: String) {
        sessions.removeValue(forKey: id)
        onChange?()
    }

    /// Once a second: happiness drift, stale-session cleanup.
    func tick() {
        let now = Date()
        let perSecond = 1.0 / 60.0
        if hasAttention {
            happiness -= perSecond * Double(attentionSessions.count)
        } else if happiness < 60 {
            happiness += 0.2 * perSecond
        }
        if mess, let since = messSince, now.timeIntervalSince(since) > 600 {
            happiness -= perSecond
        }
        var changed = false
        for (id, s) in sessions {
            let idle = now.timeIntervalSince(s.lastSeen)
            let limit: TimeInterval = s.attention != nil ? 4 * 3600 : (s.transcriptModified != nil ? 2 * 3600 : 30 * 60)
            if idle > limit {
                sessions.removeValue(forKey: id)
                changed = true
            }
        }
        if let f = fiveHour, f.used >= 100, let r = f.resetsAt, now > r {
            fiveHour = RateLimit(used: 0, resetsAt: nil)
            changed = true
        }
        if let w = sevenDay, w.used >= 100, let r = w.resetsAt, now > r {
            sevenDay = RateLimit(used: 0, resetsAt: nil)
            changed = true
        }
        let dead = isDead
        if dead && !wasDead {
            wasDead = true
            log("Weekly limit hit. RIP")
            Diag.log("Weekly limit hit: RIP until \(sevenDay?.resetsAt.map { "\($0)" } ?? "a lower reading arrives")")
            changed = true
        } else if !dead && wasDead {
            wasDead = false
            Prefs.resetBirth()
            happiness = 70
            log("Reborn: the weekly limit reset. Age starts over")
            Diag.log("Reborn: weekly limit reset, age reset to 0")
            onReborn?()
            changed = true
        }
        if changed { onChange?() }
    }

    func simulate(_ what: String) {
        let sid = "playground"
        let cwd = NSHomeDirectory() + "/playground-project"
        func ev(_ name: String, _ extra: [String: Any] = [:]) {
            var e: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": cwd]
            extra.forEach { e[$0.key] = $0.value }
            handle(event: e)
        }
        switch what {
        case "working": ev("SessionStart"); ev("UserPromptSubmit"); ev("PostToolUse")
        case "finished": ev("SessionStart"); ev("Stop")
        case "permission": ev("SessionStart"); ev("Notification", ["notification_type": "permission_prompt"])
        case "compact": ev("SessionStart"); ev("UserPromptSubmit"); ev("PreCompact"); ev("PostCompact")
        case "limit":
            handle(status: ["session_id": sid, "cwd": cwd,
                            "rate_limits": ["five_hour": ["used_percentage": 100.0,
                                                          "resets_at": Date().timeIntervalSince1970 + 120]]])
        case "tired":
            handle(status: ["session_id": sid, "cwd": cwd,
                            "rate_limits": ["five_hour": ["used_percentage": 82.0,
                                                          "resets_at": Date().timeIntervalSince1970 + 3600]]])
        case "verysick":
            handle(status: ["session_id": sid, "cwd": cwd,
                            "rate_limits": ["five_hour": ["used_percentage": 93.0,
                                                          "resets_at": Date().timeIntervalSince1970 + 3600]]])
        case "weekly":
            // Dead for 90 s, then reborn for real (age resets).
            handle(status: ["session_id": sid, "cwd": cwd,
                            "rate_limits": ["seven_day": ["used_percentage": 100.0,
                                                          "resets_at": Date().timeIntervalSince1970 + 90]]])
        case "bloated":
            ev("SessionStart"); ev("UserPromptSubmit")
            handle(status: ["session_id": sid, "cwd": cwd, "context_window": ["used_percentage": 88.0]])
        case "reset":
            sessions.removeValue(forKey: sid)
            fiveHour = nil
            sevenDay = nil
            wasDead = false   // a pretend death cleared this way is not a rebirth
            mess = false
            onChange?()
        default: break
        }
    }

    /// Adds a line to the Recent events menu and the system log.
    func note(_ line: String) {
        Diag.log(line)
        log(line)
        onChange?()
    }

    private func log(_ line: String) {
        recentEvents.insert("\(timeFmt.string(from: Date()))  \(line)", at: 0)
        if recentEvents.count > 14 { recentEvents.removeLast() }
    }
}

func formatCountdown(to date: Date?) -> String {
    guard let d = date else { return "" }
    let secs = Int(d.timeIntervalSinceNow)
    if secs <= 0 { return "resetting" }
    let h = secs / 3600, m = (secs % 3600) / 60
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(max(m, 1))m"
}
