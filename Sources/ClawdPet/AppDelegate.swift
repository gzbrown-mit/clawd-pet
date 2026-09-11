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
        PetModel.shared.onChange = { [weak self] in self?.statusBar.refresh() }

        do {
            let s = try HookServer(port: Prefs.port)
            s.onHook = { PetModel.shared.handle(event: $0) }
            s.onStatus = { PetModel.shared.handle(status: $0) }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
