import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let demo: Bool
    private var controller: PetController!
    private var statusBar: StatusBarController!
    private var server: HookServer?
    let scanner = TranscriptScanner()

    init(demo: Bool) {
        self.demo = demo
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PetController()
        controller.demoMode = demo
        statusBar = StatusBarController(controller: controller)
        PetModel.shared.onChange = { [weak self] in
            self?.statusBar.refresh()
            self?.controller.poke()
        }

        do {
            let s = try HookServer(port: Prefs.port)
            s.onHook = { PetModel.shared.handle(event: $0) }
            s.onStatus = { PetModel.shared.handle(status: $0) }
            s.onToss = { [weak self] json in
                let vx = (json["vx"] as? Double) ?? 1500, vy = (json["vy"] as? Double) ?? 900
                self?.controller.toss(CGPoint(x: vx, y: vy))
            }
            s.onFeed = { [weak self] _ in
                let fed = self?.controller.feed() ?? false
                PetModel.shared.note(fed ? "Fed a cookie through /feed" : "Cookie through /feed refused: he cannot eat right now")
            }
            s.onRaise = { json in
                guard let cwd = json["cwd"] as? String else { return }
                let outcome = PetController.openInEditor(cwd: cwd)
                PetModel.shared.note("Raise test for \((cwd as NSString).lastPathComponent): \(outcome)")
            }
            s.start()
            server = s
        } catch {
            statusBar.serverError = "\(error)"
            NSLog("ClawdPet: could not listen on port \(Prefs.port): \(error)")
        }

        controller.start()
        watchPower()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Diag.log("launched \(version) pid \(ProcessInfo.processInfo.processIdentifier), Accessibility trusted: \(WindowRaiser.isTrusted)")

        // The grant was wanted before but is missing now (a rebuild used to drop it):
        // ask macOS to show the "control this computer" prompt so it can be re-added.
        if !WindowRaiser.isTrusted, Prefs.offeredAccessibility, !demo {
            WindowRaiser.requestTrust()
        }

        scanner.onResult = { snaps in
            if Prefs.scanTranscripts { PetModel.shared.apply(snapshots: snaps) }
        }
        scanner.start()

        if !HookInstaller.isInstalled && !Prefs.offeredInstall && !demo {
            Prefs.offeredInstall = true
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Connect Clawd to Claude Code?"
            a.informativeText = "This adds a few async hooks and a status line to ~/.claude/settings.json so Clawd knows when your sessions are working, finished, or waiting on you. A backup is kept. You can undo it from the menu bar."
            a.addButton(withTitle: "Install hooks")
            a.addButton(withTitle: "Not now")
            if a.runModal() == .alertFirstButtonReturn {
                statusBar.installHooks()
            }
        }
    }

    /// The frame loop reacts to app switches and to waking up the moment they happen
    /// rather than polling for them, and idles while the display is asleep. The
    /// transcript scanner slows down then too.
    private func watchPower() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.poke()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.poke()
        }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.screenAsleep = true
            self?.scanner.throttled = true
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.screenAsleep = false
            self?.scanner.throttled = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
