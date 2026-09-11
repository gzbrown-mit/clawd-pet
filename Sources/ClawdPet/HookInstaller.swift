import Foundation

/// Writes the forwarding scripts and merges hook entries into ~/.claude/settings.json.
enum HookInstaller {
    /// Honors $HOME so the installer can be pointed at a scratch directory for testing.
    static let homeDir: String = {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }()
    static let dir = homeDir + "/.claude/clawd-pet"
    static let settingsPath = homeDir + "/.claude/settings.json"
    static let hookCommand = "~/.claude/clawd-pet/hook.sh"
    static let statusCommand = "~/.claude/clawd-pet/statusline.sh"
    static let marker = "clawd-pet/"

    /// PermissionRequest is the one synchronous hook: it fires the instant Claude is
    /// about to ask, and a hook that prints nothing leaves the normal dialog alone.
    /// The Notification permission_prompt only arrives once the prompt has sat a while.
    static let events: [(name: String, matcher: String?, async: Bool)] = [
        ("SessionStart", nil, true), ("UserPromptSubmit", nil, true), ("PostToolUse", nil, true),
        ("Stop", nil, true), ("Notification", "permission_prompt|idle_prompt", true),
        ("PermissionRequest", nil, false), ("PreCompact", nil, true), ("PostCompact", nil, true),
        ("SessionEnd", nil, true)
    ]

    static let hookScript = """
    #!/bin/bash
    # Clawd Pet: forwards Claude Code hook JSON (stdin) to the pet app. Never blocks Claude.
    PORT="${CLAWD_PET_PORT:-4242}"
    curl -s -m 2 -o /dev/null -X POST "http://127.0.0.1:${PORT}/hook" \\
      -H 'Content-Type: application/json' -H 'Expect:' --data-binary @- 2>/dev/null
    exit 0
    """

    static let statusScript = """
    #!/bin/bash
    # Clawd Pet status line: forwards Claude Code status JSON to the pet, then prints a status line.
    PORT="${CLAWD_PET_PORT:-4242}"
    DIR="$HOME/.claude/clawd-pet"
    input="$(cat)"
    printf '%s' "$input" | curl -s -m 1 -o /dev/null -X POST "http://127.0.0.1:${PORT}/status" \\
      -H 'Content-Type: application/json' -H 'Expect:' --data-binary @- 2>/dev/null &
    if [ -s "$DIR/statusline.orig" ]; then
      orig="$(cat "$DIR/statusline.orig")"
      printf '%s' "$input" | bash -c "$orig"
      exit 0
    fi
    model=$(printf '%s' "$input" | sed -n 's/.*"display_name": *"\\([^"]*\\)".*/\\1/p' | head -1)
    dir=$(printf '%s' "$input" | sed -n 's/.*"current_dir": *"\\([^"]*\\)".*/\\1/p' | head -1)
    ctx=$(printf '%s' "$input" | sed -n 's/.*"context_window": *{[^}]*"used_percentage": *\\([0-9.]*\\).*/\\1/p' | head -1)
    fh=$(printf '%s' "$input" | sed -n 's/.*"five_hour": *{[^}]*"used_percentage": *\\([0-9.]*\\).*/\\1/p' | head -1)
    wk=$(printf '%s' "$input" | sed -n 's/.*"seven_day": *{[^}]*"used_percentage": *\\([0-9.]*\\).*/\\1/p' | head -1)
    line="${model:-Claude} · $(basename "${dir:-$PWD}")"
    [ -n "$ctx" ] && line="$line · ctx ${ctx%.*}%"
    [ -n "$fh" ] && line="$line · 5h ${fh%.*}%"
    [ -n "$wk" ] && line="$line · wk ${wk%.*}%"
    printf '%s' "$line"
    """

    static var isInstalled: Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains { groupIsOurs($0) }
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try write(hookScript, to: dir + "/hook.sh")
        try write(statusScript, to: dir + "/statusline.sh")

        var settings = try loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for e in events {
            var groups = hooks[e.name] as? [[String: Any]] ?? []
            groups.removeAll { groupIsOurs($0) }
            var hook: [String: Any] = ["type": "command", "command": hookCommand]
            if e.async { hook["async"] = true }
            var group: [String: Any] = ["hooks": [hook]]
            if let m = e.matcher { group["matcher"] = m }
            groups.append(group)
            hooks[e.name] = groups
        }
        settings["hooks"] = hooks

        if let existing = settings["statusLine"] as? [String: Any] {
            let cmd = existing["command"] as? String ?? ""
            if !cmd.contains(marker) {
                let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
                try data.write(to: URL(fileURLWithPath: dir + "/statusline.orig.json"))
                try write(cmd, to: dir + "/statusline.orig", executable: false)
            }
        } else {
            try? fm.removeItem(atPath: dir + "/statusline.orig")
            try? fm.removeItem(atPath: dir + "/statusline.orig.json")
        }
        settings["statusLine"] = ["type": "command", "command": statusCommand, "refreshInterval": 30]
        try saveSettings(settings)
    }

    static func uninstall() throws {
        var settings = try loadSettings()
        if var hooks = settings["hooks"] as? [String: Any] {
            for e in events {
                guard var groups = hooks[e.name] as? [[String: Any]] else { continue }
                groups.removeAll { groupIsOurs($0) }
                if groups.isEmpty { hooks.removeValue(forKey: e.name) } else { hooks[e.name] = groups }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        if let sl = settings["statusLine"] as? [String: Any], (sl["command"] as? String ?? "").contains(marker) {
            let origPath = dir + "/statusline.orig.json"
            if let data = FileManager.default.contents(atPath: origPath),
               let orig = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                settings["statusLine"] = orig
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        }
        try saveSettings(settings)
        try? FileManager.default.removeItem(atPath: dir)
    }

    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String ?? "").contains(marker) }
    }

    private static func write(_ text: String, to path: String, executable: Bool = true) throws {
        try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    static func loadSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath) else { return [:] }
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClawdPet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "settings.json is not a JSON object"])
        }
        return obj
    }

    private static func saveSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsPath) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? fm.copyItem(atPath: settingsPath, toPath: settingsPath + ".clawd-pet-backup-\(stamp)")
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }
}
