import AppKit
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private weak var controller: PetController?
    private let model = PetModel.shared
    var serverError: String?
    private var lastBadge = -1

    init(controller: PetController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        item.menu = menu
        item.button?.image = IconRenderer.menuBarImage(size: 18)
        item.button?.imagePosition = .imageLeading
        controller.menuProvider = { [weak self] in
            guard let self = self else { return NSMenu() }
            let m = NSMenu()
            self.populate(m)
            return m
        }
        refresh()
    }

    func refresh() {
        let n = model.attentionSessions.count
        if n != lastBadge {
            lastBadge = n
            item.button?.title = n > 0 ? " \(n)" : ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(label("Clawd: \(model.moodLine)"))
        if let err = serverError {
            menu.addItem(label("Listener error: \(err)"))
        }
        menu.addItem(.separator())

        let sessions = model.orderedSessions
        if sessions.isEmpty {
            menu.addItem(label("No Claude Code sessions found yet"))
        } else {
            menu.addItem(label("Sessions · tick = watched · newest first"))
            for s in sessions {
                let state: String
                if let a = s.attention { state = a.label.uppercased() }
                else if s.working { state = "working" }
                else { state = "idle" }
                var title = "\(truncate(s.displayTitle, 44)) · \(s.name) · \(state) · \(ago(s.lastSeen))"
                if !s.watched { title = "(muted) " + title }
                let it = NSMenuItem(title: title, action: #selector(openSession(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = s.id
                it.state = s.watched ? .on : .off
                menu.addItem(it)

                let sub = NSMenu()
                sub.addItem(action("Open in editor and mark seen", #selector(openSession(_:)), s.id))
                sub.addItem(action(s.watched ? "Mute this session" : "Watch this session", #selector(toggleMute(_:)), s.id))
                sub.addItem(action("Mark as seen", #selector(markSeen(_:)), s.id))
                sub.addItem(action("Forget session", #selector(forgetSession(_:)), s.id))
                sub.addItem(.separator())
                if s.title != nil { sub.addItem(label(s.displayTitle)) }
                sub.addItem(label(s.cwd))
                var info: [String] = []
                if let m = s.model { info.append(m) }
                if let c = s.contextUsed { info.append("context \(Int(c))%") }
                if !info.isEmpty { sub.addItem(label(info.joined(separator: " · "))) }
                sub.addItem(label("Found via \(s.sourceLabel)"))
                if !s.hooked {
                    sub.addItem(label("Restart this session to get hook events (permission prompts)"))
                }
                sub.addItem(label("Session id \(s.id)"))
                it.submenu = sub
            }
        }
        menu.addItem(action("Rescan transcripts now", #selector(rescan)))
        let scanNote = Prefs.scanTranscripts
            ? "Sessions come from Claude Code hooks and from transcripts in ~/.claude/projects"
            : "Sessions come from Claude Code hooks only (transcript scanning is off)"
        menu.addItem(label(scanNote))
        menu.addItem(.separator())

        if let f = model.fiveHour {
            menu.addItem(label("Energy: \(Int(100 - f.used))% · \(formatCountdown(to: f.resetsAt))"))
        } else {
            menu.addItem(label("Energy: unknown until a session reports usage"))
        }
        if let w = model.sevenDay {
            menu.addItem(label("Weekly limit used: \(Int(w.used))% · \(formatCountdown(to: w.resetsAt))"))
        }
        let hearts = Int((model.happiness / 20).rounded(.up))
        menu.addItem(label("Happiness: " + String(repeating: "♥", count: max(hearts, 0)) + String(repeating: "♡", count: max(5 - hearts, 0))))
        menu.addItem(label("Age: \(model.ageDays) day\(model.ageDays == 1 ? "" : "s") · fed \(Prefs.totalFinished) finished turns · petted \(Prefs.totalPets) times"))
        menu.addItem(.separator())

        let hooksInstalled = HookInstaller.isInstalled
        menu.addItem(action(hooksInstalled ? "Reinstall Claude Code hooks" : "Install Claude Code hooks…", #selector(installHooks)))
        if hooksInstalled {
            menu.addItem(action("Remove Claude Code hooks", #selector(uninstallHooks)))
        }

        let settings = NSMenu()
        settings.addItem(check("Hide while VS Code is in front", Prefs.hideWhenEditorFront, #selector(toggleHide)))
        settings.addItem(check("Come out over VS Code when Claude needs me", Prefs.peekWhenAttention, #selector(togglePeek)))
        settings.addItem(check("Stay quiet about the window I'm looking at (Accessibility)", Prefs.skipFrontWindow, #selector(toggleSkipFront)))
        settings.addItem(check("Calm down when I return to VS Code", Prefs.calmWhenEditorFront, #selector(toggleCalm)))
        settings.addItem(check("Play a sound when Claude finishes", Prefs.playSound, #selector(toggleSound)))
        settings.addItem(check("Find sessions by watching transcripts", Prefs.scanTranscripts, #selector(toggleScan)))
        settings.addItem(check("Launch at login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        settings.addItem(check("Raise the exact window (Accessibility)", WindowRaiser.isTrusted, #selector(accessibility)))
        settings.addItem(.separator())
        settings.addItem(action("Reset home position", #selector(resetHome)))
        settings.addItem(label("Listening on 127.0.0.1:\(Prefs.port)"))
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        menu.addItem(settingsItem)

        let play = NSMenu()
        play.addItem(check("Demo mode (cycle every animation)", controller?.demoMode ?? false, #selector(toggleDemo)))
        play.addItem(.separator())
        for a in Activity.allCases where !a.isReaction {
            play.addItem(action("Show: \(a.label)", #selector(forceActivity(_:)), a.rawValue))
        }
        play.addItem(.separator())
        for a in Activity.allCases where a.isReaction && a != .chase {
            play.addItem(action("Show: \(a.label)", #selector(forceActivity(_:)), a.rawValue))
        }
        play.addItem(.separator())
        for (title, key) in [("Pretend a session is working", "working"),
                             ("Pretend Claude finished", "finished"),
                             ("Pretend Claude needs permission", "permission"),
                             ("Pretend context is nearly full", "bloated"),
                             ("Pretend a compaction happened", "compact"),
                             ("Pretend the 5-hour limit is close (sick)", "tired"),
                             ("Pretend the 5-hour limit is nearly hit (very sick)", "verysick"),
                             ("Pretend the 5-hour limit is hit (fainted)", "limit"),
                             ("Pretend the weekly limit is hit (RIP, reborn in 90 s)", "weekly"),
                             ("Clear pretend state", "reset")] {
            play.addItem(action(title, #selector(simulate(_:)), key))
        }
        let playItem = NSMenuItem(title: "Playground", action: nil, keyEquivalent: "")
        playItem.submenu = play
        menu.addItem(playItem)

        if !model.recentEvents.isEmpty {
            let log = NSMenu()
            for e in model.recentEvents { log.addItem(label(e)) }
            let logItem = NSMenuItem(title: "Recent events", action: nil, keyEquivalent: "")
            logItem.submenu = log
            menu.addItem(logItem)
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit Clawd Pet", #selector(quit)))
    }

    // MARK: Helpers

    private func label(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func action(_ title: String, _ sel: Selector, _ rep: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.representedObject = rep
        return it
    }

    private func truncate(_ text: String, _ n: Int) -> String {
        text.count <= n ? text : String(text.prefix(n - 1)) + "…"
    }

    private func ago(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m ago"
    }

    private func check(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let it = action(title, sel)
        it.state = on ? .on : .off
        return it
    }

    private func alert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
        a.runModal()
    }

    // MARK: Actions

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = model.sessions[id] else { return }
        model.acknowledge(id: id)
        let outcome = PetController.openInEditor(cwd: s.cwd)
        model.note("Open \(s.name): \(outcome)")
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.toggleMute(id: id)
    }

    @objc private func markSeen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.acknowledge(id: id)
    }

    @objc private func forgetSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.removeSession(id: id)
    }

    @objc func installHooks() {
        do {
            try HookInstaller.install()
            alert("Hooks installed",
                  "Claude Code will now tell Clawd when sessions start, work, finish, or wait for you.\n\nAlready-open Claude sessions need a restart to pick up the hooks. A backup of settings.json was saved next to it.")
        } catch {
            alert("Could not install hooks", error.localizedDescription, style: .warning)
        }
    }

    @objc private func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            alert("Hooks removed", "Clawd's entries were removed from ~/.claude/settings.json and your previous status line was restored.")
        } catch {
            alert("Could not remove hooks", error.localizedDescription, style: .warning)
        }
    }

    @objc private func toggleHide() { Prefs.hideWhenEditorFront.toggle() }
    @objc private func togglePeek() { Prefs.peekWhenAttention.toggle() }
    @objc private func toggleSkipFront() { Prefs.skipFrontWindow.toggle() }
    @objc private func toggleCalm() { Prefs.calmWhenEditorFront.toggle() }
    @objc private func toggleSound() { Prefs.playSound.toggle() }
    @objc private func toggleScan() { Prefs.scanTranscripts.toggle() }

    @objc private func accessibility() {
        if WindowRaiser.isTrusted {
            alert("Accessibility is on", "Clawd can raise the window that already has a project open, and can tell when you are already looking at a session's window so it stays quiet. If this stops working after you rebuild the app, untick and re-tick ClawdPet in System Settings > Privacy & Security > Accessibility: macOS treats each rebuild as a new app.")
        } else {
            WindowRaiser.requestTrust()
            WindowRaiser.openAccessibilitySettings()
        }
    }
    @objc private func rescan() { (NSApp.delegate as? AppDelegate)?.scanner.scanAsync() }
    @objc private func toggleDemo() { controller?.demoMode.toggle() }
    @objc private func resetHome() { controller?.resetHome() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Launch at login", "macOS refused: \(error.localizedDescription)\n\nMove ClawdPet.app into /Applications and try again.", style: .warning)
        }
    }

    @objc private func forceActivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = Activity(rawValue: raw) else { return }
        controller?.force(a)
    }

    @objc private func simulate(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        model.simulate(key)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
