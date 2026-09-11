import AppKit

let usage = """
ClawdPet: an 8-bit desk pet that watches your Claude Code sessions.

  ClawdPet                  run the pet (menu bar app)
  ClawdPet --demo           run and cycle through every animation
  ClawdPet --port N         listen on a different port (default 4242)
  ClawdPet --install-hooks  add Claude Code hooks + status line to ~/.claude/settings.json
  ClawdPet --uninstall-hooks
  ClawdPet --render-icon DIR  write an .iconset folder (used by build.sh)
  ClawdPet --render-sheet PNG write a sprite sheet of every animation
  ClawdPet --scan           list the Claude sessions found in ~/.claude/projects transcripts
  ClawdPet --raise DIR      raise the editor window for a project folder and report what happened
"""

let argv = Array(CommandLine.arguments.dropFirst())

func flagValue(_ flag: String) -> String? {
    guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

if argv.contains("--help") || argv.contains("-h") {
    print(usage)
    exit(0)
}
if argv.contains("--scan") {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"
    for snap in TranscriptScanner().scan() {
        let title = snap.title ?? "(no title yet)"
        print("\(fmt.string(from: snap.modified))  \(snap.lastKind.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0))  \((snap.cwd as NSString).lastPathComponent)  —  \(title)  [\(snap.id.prefix(8))]")
    }
    exit(0)
}
if let dir = flagValue("--raise") {
    print("Accessibility trusted for this process: \(WindowRaiser.isTrusted)")
    print("Looking for: \(WindowRaiser.names(for: dir).joined(separator: ", "))")
    print(PetController.openInEditor(cwd: dir))
    RunLoop.main.run(until: Date().addingTimeInterval(1))   // let the activation request go out
    exit(0)
}
if let path = flagValue("--render-sheet") {
    // Same art on light, dark, and mid backgrounds, to prove nothing disappears.
    let base = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
    for (suffix, bg) in [("-light", UInt32(0xFFFFFF)), ("-dark", UInt32(0x000000)), ("-mid", UInt32(0x7F7F7F))] {
        SheetRenderer.write(to: base + suffix + ".png", background: bg)
        print("wrote \(base + suffix + ".png")")
    }
    SheetRenderer.write(to: base + "-mirrored.png", background: 0xFFFFFF, mirrored: true)
    print("wrote \(base + "-mirrored.png") (facing left)")
    exit(0)
}
if let dir = flagValue("--render-icon") {
    IconRenderer.writeIconset(to: dir)
    print("wrote iconset to \(dir)")
    exit(0)
}
if argv.contains("--install-hooks") {
    do {
        try HookInstaller.install()
        print("Installed Clawd Pet hooks into \(HookInstaller.settingsPath). Restart open Claude sessions.")
        exit(0)
    } catch {
        fputs("install failed: \(error)\n", stderr)
        exit(1)
    }
}
if argv.contains("--uninstall-hooks") {
    do {
        try HookInstaller.uninstall()
        print("Removed Clawd Pet hooks from \(HookInstaller.settingsPath).")
        exit(0)
    } catch {
        fputs("uninstall failed: \(error)\n", stderr)
        exit(1)
    }
}
if let p = flagValue("--port"), let port = UInt16(p) {
    Prefs.setPort(port)
}

let app = NSApplication.shared
let delegate = AppDelegate(demo: argv.contains("--demo"))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
