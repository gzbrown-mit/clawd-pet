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

    /// Returns true if a matching window was raised.
    static func raise(cwd: String) -> Bool {
        guard isTrusted else { return false }
        let wanted = names(for: cwd)
        guard !wanted.isEmpty else { return false }
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
        guard !candidates.isEmpty else { return false }

        // Pass 1: a title segment equals the folder name ("file.py — miniASKCOS").
        // Pass 2: the folder name appears anywhere in the title.
        for name in wanted {
            let lower = name.lowercased()
            if let hit = candidates.first(where: { segments($0.title).contains(lower) }) {
                return bring(hit.window, of: hit.app)
            }
        }
        for name in wanted {
            let lower = name.lowercased()
            if let hit = candidates.first(where: { $0.title.lowercased().contains(lower) }) {
                return bring(hit.window, of: hit.app)
            }
        }
        return false
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

    static func segments(_ title: String) -> [String] {
        title.lowercased()
            .replacingOccurrences(of: " — ", with: "\u{1}")
            .replacingOccurrences(of: " - ", with: "\u{1}")
            .replacingOccurrences(of: " – ", with: "\u{1}")
            .split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "● ", with: "") }
    }

    private static func bring(_ window: AXUIElement, of app: NSRunningApplication) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate()
        return raised == .success
    }
}
