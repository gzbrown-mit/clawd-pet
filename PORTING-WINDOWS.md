# Porting Clawd Pet to Windows

Clawd is a native Swift/AppKit app. The pet's brain ports cleanly; everything that touches the
desktop does not. This is the checklist of what to rewrite and what will bite, file by file.

## What ports as-is

These files are plain logic with no platform calls and can be translated line for line into any
language (C#, Rust, TypeScript):

| File | What it is |
|---|---|
| `Sprites.swift` | Palette, 24x24 character grids, body composer, every animation, sheet renderer |
| `PetModel.swift` | Sessions, attention rules, happiness, sickness stages, death and rebirth |
| `TranscriptScanner.swift` (parsing half) | Reading the tail of a `.jsonl` transcript for cwd, title, last message |
| `HookServer.swift` (parsing half) | The tiny HTTP request parser |

Keep the frame data as strings of palette letters exactly as they are; only the renderer changes.

## Pick a framework first

Swift runs on Windows but AppKit does not, and a per-pixel transparent, click-through,
always-on-top window is the one thing the whole app hangs on. Realistic choices:

- **C# / .NET (WPF or WinForms)**: layered windows and tray icons are well trodden. Best fit.
- **Electron or Tauri**: `transparent: true`, `alwaysOnTop`, `setIgnoreMouseEvents(true, {forward: true})`
  give the click-through panel almost for free; heavier, and the hook server becomes Node.
- **Rust (winit + softbuffer)**: light, but you write the Win32 glue yourself.

## The floating panel (`PetPanel.swift`)

| macOS today | Windows equivalent | Watch out |
|---|---|---|
| `NSPanel`, borderless, `.nonactivatingPanel`, clear background | `WS_EX_LAYERED` + `WS_EX_TOPMOST` + `WS_EX_TOOLWINDOW` + `WS_EX_NOACTIVATE`, per-pixel alpha via `UpdateLayeredWindow` | `WS_EX_TOOLWINDOW` keeps it off the taskbar and Alt-Tab. Without `NOACTIVATE` a click steals focus from the editor. |
| `hitTest` returns nil on transparent pixels so clicks fall through | Answer `WM_NCHITTEST` with `HTTRANSPARENT` when the pixel under the cursor is transparent, or toggle `WS_EX_TRANSPARENT` | You need the current frame's alpha at the cursor; keep the last rendered grid around. |
| `level = .statusBar`, `.canJoinAllSpaces`, `.fullScreenAuxiliary` | Topmost is the best you get | Exclusive-fullscreen games hide topmost windows. Virtual desktops: a window lives on one desktop; pinning it to all needs the undocumented `IVirtualDesktopPinnedApps` COM interface. |
| `NSScreen.visibleFrame` for clamping and the toss floor | `MonitorFromPoint` + `GetMonitorInfo().rcWork` (excludes the taskbar) | The virtual screen can have negative coordinates on multi-monitor setups. |
| Cocoa coordinates: origin bottom-left, y grows upward | Origin top-left, y grows downward | Every `pos.y`, the gravity sign in `fly()`, `cursorTarget()`, `defaultHome()` and the floor test flip. Easiest: convert once at the window boundary and keep the physics in y-up. |
| Sprites drawn at a fixed 4x scale | Per-monitor DPI awareness v2 | Without it Windows bitmap-stretches the window on high-DPI screens and cursor coordinates come back scaled. |
| Self-pacing `Timer` on the main run loop: 30 Hz while he moves, otherwise woken when the next frame is due, throttled while the display sleeps (`NSWorkspace` screen sleep/wake and app activation notifications) | `DispatcherTimer` rescheduled after each tick; `RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)` for display sleep, `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` for foreground changes | Sleep and hibernate pause timers; the physics assumes a fixed 1/30 s step while moving, which is fine. Keep the self-pacing or the tray app will burn a few percent of CPU around the clock. |
| `NSEvent.mouseLocation`, `mouseDown/Dragged/Up` | `GetCursorPos`, `WM_LBUTTONDOWN` + `SetCapture` + `WM_MOUSEMOVE` + `WM_LBUTTONUP` | Release the capture on `WM_CANCELMODE`. The toss velocity sampler wants timestamps in the same units. |
| Right-click `NSMenu` popup | `TrackPopupMenu` or the framework's context menu | Fine. |

## Finding the front window and raising the right one (`WindowRaiser.swift`)

This gets easier: Windows has no Accessibility permission for reading window titles, so the whole
TCC / codesign designated-requirement dance disappears. What replaces it:

| macOS today | Windows equivalent | Watch out |
|---|---|---|
| `AXIsProcessTrusted`, `AXUIElementCopyAttributeValue(kAXWindowsAttribute)` | `EnumWindows` + `GetWindowText`, filter with `IsWindowVisible` and by owning process | Skip tool windows and cloaked UWP windows (`DwmGetWindowAttribute(DWMWA_CLOAKED)`). |
| Frontmost app via bundle id (`com.microsoft.VSCode`) | `GetForegroundWindow` + `GetWindowThreadProcessId` + `QueryFullProcessImageName` | Match on exe names: `Code.exe`, `Code - Insiders.exe`, `Cursor.exe`, `Windsurf.exe`, `WindowsTerminal.exe`, `cmd.exe`, `powershell.exe`, `pwsh.exe`, `alacritty.exe`, `wezterm-gui.exe`. Zed has no stable Windows build. |
| `kAXRaiseAction` + `kAXMinimizedAttribute` + Launch Services activation | `ShowWindow(SW_RESTORE)` if `IsIconic`, then `SetForegroundWindow` | **`SetForegroundWindow` is the Windows headache.** A background process is refused unless it owns the current foreground window or the last input. Standard workarounds: call `AllowSetForegroundWindow`, briefly `AttachThreadInput` to the foreground thread, send a no-op Alt key with `SendInput` first, or use `SwitchToThisWindow`. Budget time for this. |
| Title split on " — " / " - " / " – " to find the folder | Same code | VS Code on Windows always appends " - Visual Studio Code" and uses a plain hyphen, so the folder is the second-to-last segment, not the last. |
| Window on another Space | Window on another virtual desktop | `SetForegroundWindow` switches desktops; if not, `IVirtualDesktopManager.MoveWindowToDesktop`. |
| Hidden/minimised windows are still listed | Minimised windows are still enumerated; windows on other desktops are too | Good. |

## Hooks and the status line (`HookInstaller.swift`, `hook.sh`, `statusline.sh`)

| macOS today | Windows equivalent | Watch out |
|---|---|---|
| `~/.claude/settings.json` | `%USERPROFILE%\.claude\settings.json` | The code reads `$HOME`; on Windows read `USERPROFILE`. Same file layout. |
| Hook command `~/.claude/clawd-pet/hook.sh` (bash + curl) | **Verify which shell Claude Code uses to run hook commands on native Windows before writing anything.** Then ship a `.cmd` or PowerShell script, or a tiny `.exe`, and write the absolute path into settings.json | `~` does not expand in cmd or PowerShell. `curl.exe` exists on Windows 10+, but quoting `-H "Expect:"` and `--data-binary @-` differs between cmd and PowerShell (PowerShell aliases `curl` to `Invoke-WebRequest` unless you write `curl.exe`). |
| Hooks are async except `PermissionRequest` | Same | A synchronous hook must return fast; PowerShell startup is 200 to 500 ms, so prefer a compiled helper or cmd for that one. |
| Status line script prints a line and forwards JSON in the background | Same idea | Background forwarding in cmd is awkward (`start /b`); a helper exe is simpler. |
| Claude Code running in WSL | Hooks run inside Linux | The pet listens on Windows `127.0.0.1:4242`; from WSL2 that is a different loopback. Either enable WSL mirrored networking, have the hook post to the host IP from `/etc/resolv.conf`, or run the pet's listener inside WSL and forward. Transcripts then live in the Linux home too. |

## Session discovery (`TranscriptScanner.swift`)

| macOS today | Windows equivalent | Watch out |
|---|---|---|
| `~/.claude/projects/*/*.jsonl` | `%USERPROFILE%\.claude\projects\*\*.jsonl` | Project folder names encode the path with dashes; on Windows they start with the drive letter (`C--Users-name-project`). Do not parse the folder name; the `cwd` inside the file is authoritative and uses backslashes. |
| `NSString.lastPathComponent` in `WindowRaiser.names(for:)` | `Path.GetFileName` / `Path.GetDirectoryName` | These must handle both separators; stop walking up at the user profile directory, not `/`. Comparisons are already lowercased, which suits a case-insensitive filesystem. |
| Reading the tail of a file another process is writing | Open with `FileShare.ReadWrite` (or `FILE_SHARE_WRITE`) | Otherwise the read fails while Claude Code has the transcript open. Also handle a partial last line. |
| Modification time with `attributesOfItem` | `File.GetLastWriteTimeUtc` | NTFS timestamps are fine; FAT-formatted drives have 2 s granularity. |

## Menu bar, settings, sounds, launch at login

| macOS today | Windows equivalent | Watch out |
|---|---|---|
| `NSStatusItem` with a badge count in its title | Tray icon via `Shell_NotifyIcon` / `NotifyIcon` | The tray cannot show text; draw the count into the icon or put it in the tooltip. Icons are `.ico`, not the rendered NSImage. |
| `UserDefaults` | JSON in `%APPDATA%\ClawdPet\` or the registry | Keep the same keys so settings semantics stay documented in one place. |
| `NSSound(named: "Pop")` | `SystemSounds.Asterisk.Play()` or a bundled `.wav` via `PlaySound` | No built-in "Pop". |
| `SMAppService` launch at login | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value, or a shortcut in the Startup folder | No /Applications requirement. |
| `NSAlert` first-run install offer | `TaskDialog` / `MessageBox` | Fine. |
| Accessibility prompt at launch | Not needed | Delete `requestTrust`, `openAccessibilitySettings`, the Settings toggle, and the README paragraph about TCC. |

## Local listener (`HookServer.swift`)

| macOS today | Windows equivalent | Watch out |
|---|---|---|
| `NWListener` on `127.0.0.1:4242` | A raw `TcpListener` on loopback with the same hand-rolled HTTP parser | Prefer this over `HttpListener`, which wants URL ACL reservations (`netsh http add urlacl`) for anything but a few reserved prefixes. Loopback listeners normally do not trigger the Windows Firewall prompt, but some third-party firewalls do. |
| Port 4242, overridable with `--port` | Same | Check for a conflict and report it in the tray menu as the Mac app does. |

## Build and packaging (`scripts/*.sh`, `Info.plist`)

| macOS today | Windows equivalent | Watch out |
|---|---|---|
| `swift build`, `iconutil`, ad-hoc `codesign` with a pinned designated requirement | `dotnet publish` (or the framework's build) plus an `.ico` | The signing trick exists only to keep the macOS Accessibility grant; nothing to port. An unsigned exe gets a SmartScreen warning for people who download it, which a code-signing certificate fixes. |
| `scripts/simulate.sh` (bash, curl, `date +%s`) | A PowerShell script using `Invoke-RestMethod` and `[DateTimeOffset]::Now.ToUnixTimeSeconds()` | Handy for testing the tray app without Claude. |
| `--render-sheet`, `--render-icon`, `--scan`, `--raise` flags | Keep them | They are how the art and the window matching get checked without clicking around. |

## Things that are simply different

- **No Spaces, but virtual desktops.** "Hide while the editor is in front" works the same via the foreground window; "come out over the editor" works because topmost windows show over normal ones.
- **Fullscreen editors.** A maximised VS Code is a normal window; a true fullscreen (F11) one is borderless and still lets topmost windows show.
- **Multiple users of the same machine.** `%USERPROFILE%` is per user, as on macOS.
- **Unicode in menus.** The menu uses `♥ ♡ · …`; Windows menus render them, but pick a font that has the hearts if you draw them into the tray icon.

## Suggested order

1. Layered click-through window drawing the idle animation from the ported `Sprites` data.
2. Tray icon and menu.
3. Hook listener and a Windows hook script; confirm events arrive from a real session.
4. Chase, click, and `SetForegroundWindow` for the right VS Code window.
5. Transcript scanner, physics, sickness and the rest of the model.
