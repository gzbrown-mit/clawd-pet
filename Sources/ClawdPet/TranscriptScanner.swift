import Foundation

/// Finds live Claude Code sessions by watching transcript files in ~/.claude/projects.
/// This catches sessions that started before the hooks were installed, and gives every
/// session its AI-generated title.
struct TranscriptSnapshot {
    let id: String
    let cwd: String
    let title: String?
    let lastKind: TranscriptScanner.LastKind
    let modified: Date
}

final class TranscriptScanner {
    enum LastKind: String { case userPrompt, toolResult, assistantWorking, assistantDone, unknown }

    static let projectsDir = HookInstaller.homeDir + "/.claude/projects"
    private let queue = DispatchQueue(label: "clawdpet.scanner", qos: .utility)
    private var cache: [String: (mtime: Date, snap: TranscriptSnapshot)] = [:]
    private var timer: Timer?
    private var lastScanStarted = Date.distantPast
    var window: TimeInterval = 2 * 3600
    var onResult: (([TranscriptSnapshot]) -> Void)?
    /// While the display is asleep nobody is watching, so one scan a minute is plenty.
    var throttled = false

    func start(interval: TimeInterval = 5) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.throttled, Date().timeIntervalSince(self.lastScanStarted) < 60 { return }
            self.scanAsync()
        }
        timer!.tolerance = interval * 0.2
        RunLoop.main.add(timer!, forMode: .common)
        scanAsync()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func scanAsync() {
        lastScanStarted = Date()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.scan()
            DispatchQueue.main.async { self.onResult?(result) }
        }
    }

    func scan() -> [TranscriptSnapshot] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: Self.projectsDir) else { return [] }
        let now = Date()
        var out: [TranscriptSnapshot] = []
        for p in projects {
            let dir = Self.projectsDir + "/" + p
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let path = dir + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let m = attrs[.modificationDate] as? Date else { continue }
                if now.timeIntervalSince(m) > window { continue }
                if let c = cache[path], c.mtime == m {
                    out.append(c.snap)
                    continue
                }
                let id = String(f.dropLast(".jsonl".count))
                if let snap = parseTail(path: path, id: id, modified: m) {
                    cache[path] = (m, snap)
                    out.append(snap)
                }
            }
        }
        cache = cache.filter { now.timeIntervalSince($0.value.mtime) <= window }
        return out.sorted { $0.modified > $1.modified }
    }

    func parseTail(path: String, id: String, modified: Date) -> TranscriptSnapshot? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tailLen: UInt64 = 192 * 1024
        let start = size > tailLen ? size - tailLen : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var cwd = ""
        var title: String?
        var lastKind: LastKind = .unknown
        var foundLast = false
        for line in lines.reversed() {
            guard line.first == "{",
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if cwd.isEmpty, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if title == nil, type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty { title = t }
            if !foundLast, type == "user" || type == "assistant",
               (obj["isSidechain"] as? Bool) != true, (obj["isMeta"] as? Bool) != true {
                let msg = obj["message"] as? [String: Any] ?? [:]
                if type == "assistant" {
                    lastKind = (msg["stop_reason"] as? String) == "end_turn" ? .assistantDone : .assistantWorking
                } else if let parts = msg["content"] as? [[String: Any]],
                          parts.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                    lastKind = .toolResult
                } else {
                    lastKind = .userPrompt
                }
                foundLast = true
            }
            if foundLast, title != nil, !cwd.isEmpty { break }
        }
        if !foundLast && cwd.isEmpty { return nil }
        return TranscriptSnapshot(id: id, cwd: cwd, title: title, lastKind: lastKind, modified: modified)
    }
}
