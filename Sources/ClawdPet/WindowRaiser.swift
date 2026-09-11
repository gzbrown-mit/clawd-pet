import AppKit
import ApplicationServices

/// Raises the existing editor or terminal window for a project instead of opening a new one.
/// Uses the Accessibility API, so it needs the app ticked under
/// System Settings > Privacy & Security > Accessibility.
enum WindowRaiser {
    static let terminalBundleIDs = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty"
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open the Accessibility settings pane.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Candidate names for a project, deepest folder first, stopping at the home directory.
    static func names(for cwd: String) -> [String] {
        let home = NSHomeDirectory()
        var path = cwd
        var out: [String] = []
        while !path.isEmpty, path != "/", path != home {
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { out.append(name) }
            path = (path as NSString).deletingLastPathComponent
        }
        return out
    }

    enum Outcome {
        case raised(title: String, app: String)
        case notTrusted
        case noMatch(name: String, titles: [String])

        var summary: String {
            switch self {
            case .raised(let t, let a): return "raised \"\(t)\" in \(a)"
            case .notTrusted: return "Accessibility is off"
            case .noMatch(let n, let titles):
                return "no window titled like \"\(n)\"" + (titles.isEmpty ? "" : " among: " + titles.joined(separator: " | "))
            }
        }
    }

    /// Raises the window whose title carries the project name, if allowed and found.
    static func raise(cwd: String) -> Outcome {
        let wanted = names(for: cwd)
        let name = wanted.first ?? cwd
        guard isTrusted else { return .notTrusted }
        guard !wanted.isEmpty else { return .noMatch(name: name, titles: []) }
        let running = NSWorkspace.shared.runningApplications
        let apps = (PetController.editorBundleIDs + terminalBundleIDs)
            .compactMap { id in running.first { $0.bundleIdentifier == id } }

        var candidates: [(app: NSRunningApplication, window: AXUIElement, title: String)] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for w in windows {
                var t: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
                      let title = t as? String, !title.isEmpty else { continue }
                candidates.append((app, w, title))
            }
        }
        guard !candidates.isEmpty else { return .noMatch(name: name, titles: []) }

        // Pass 1: a title segment equals the folder name ("file.py — miniASKCOS").
        // Pass 2: the folder name appears anywhere in the title.
        for name in wanted {
            let lower = name.lowercased()
            if let hit = candidates.first(where: { segments($0.title).contains(lower) }) {
                bring(hit.window, of: hit.app)
                return .raised(title: hit.title, app: hit.app.localizedName ?? "editor")
            }
        }
        for name in wanted {
            let lower = name.lowercased()
            if let hit = candidates.first(where: { $0.title.lowercased().contains(lower) }) {
                bring(hit.window, of: hit.app)
                return .raised(title: hit.title, app: hit.app.localizedName ?? "editor")
            }
        }
        return .noMatch(name: name, titles: candidates.map { $0.title })
    }

    /// Title of the window the user is looking at, when the frontmost app is an editor
    /// or terminal and Accessibility allows us to ask.
    static func frontWindowTitle() -> String? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier,
              (PetController.editorBundleIDs + terminalBundleIDs).contains(id) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &w) == .success,
              let win = w, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return nil }
        return t as? String
    }

    /// True when the window in front carries this project's name, i.e. the user is
    /// already looking at the session. Always false without Accessibility.
    static func frontWindowShows(cwd: String) -> Bool {
        guard let title = frontWindowTitle() else { return false }
        let segs = segments(title)
        return names(for: cwd).contains { segs.contains($0.lowercased()) }
    }

    /// Splits a window title on any dash surrounded by whitespace, so
    /// "file.py — project", "file.py - project" and "file.py – project" all work.
    static func segments(_ title: String) -> [String] {
        let lower = title.lowercased()
        let ns = lower as NSString
        let dash = try! NSRegularExpression(pattern: "\\s+[-\u{2013}\u{2014}]\\s+")
        var parts: [String] = []
        var last = 0
        for m in dash.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "● ", with: "") }
    }

    private static func bring(_ window: AXUIElement, of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        activate(app)
    }

    /// Brings an app to the front through Launch Services. A plain
    /// NSRunningApplication.activate() from a background accessory app is often
    /// refused on macOS 14 and later, so the window would be raised inside the
    /// editor without the editor itself coming forward.
    static func activate(_ app: NSRunningApplication) {
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app.activate(options: [.activateAllWindows])
        }
    }
}
