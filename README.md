# Clawd Pet

An 8-bit desk pet for macOS that keeps an eye on your Claude Code sessions. Native Swift menu-bar
app. No Xcode, Node, or Electron needed: the Command Line Tools are enough.

## Meet Clawd

Clawd is a small orange pixel critter with four stubby legs and one very important job: watching
Claude work so you don't have to.

While Claude is busy, so is Clawd. He hammers away on a tiny laptop, drifts off to think in a little
grey bubble, and ambles left and right when his legs get restless. Every so often he treats himself
to a cookie, a coffee, a bouncy ball, or a short victory dance. When nothing has happened for a
while he curls up in his dog bed and snores Zs at the ceiling.

The moment a session finishes, or Claude stops to ask permission, Clawd drops everything. He
scuttles across the screen to wherever your mouse is, plants himself next to it, and hops up and
down waving a red `!` (or a yellow `?` for permissions) until you click him. He will even squeeze
out from behind VS Code to do it. He is polite about it, though: if you are already looking at that
window, he keeps quiet. Once you have clicked him, he takes you back to the window Claude is
running in, then trots home to his spot and gets on with his day.

He is not without feelings. His happiness sinks while finished sessions sit unanswered, and he is
delighted when you pet him. A nearly full context window leaves him bloated and sweaty. Hit the
5-hour usage limit and he faints, X-eyed, until it resets. And after a compaction he leaves a small
pile behind that he really would like you to clean up.

## What sets him off

| Claude Code signal | Clawd |
|---|---|
| `UserPromptSubmit`, tool use | Busy. Long stretches of typing on his laptop (2 to 5 min), thinking in a grey thought bubble (1 to 2.5 min), ambling left and right (1 to 3 min), or sitting and breathing, broken up by short treats: a cookie, a coffee, a ball, a dance (10 to 30 s) |
| `Stop` (Claude finished a turn) | Runs to your cursor with a red `!` and hops until you click him, then trots home |
| `Notification` permission_prompt / idle_prompt | Same, with a yellow `?` |
| Session finishes in the window you are looking at | Nothing. He assumes you saw it (needs Accessibility, see below) |
| Context window over 80% | Bloated body and sweat drop. Time for `/compact` |
| `PreCompact` / `PostCompact` | Thinks, then leaves a little pile you click to clean up |
| 5-hour limit at 75%+ | Sick: fades to a washed-out orange with a frown and sweat |
| 5-hour limit hit | Faints, washed out with X eyes, until the window resets |
| Weekly limit over 85% | Permanent sweat drop |
| Nothing for 90 s | Sleeps in his dog bed with Zs drifting up |
| Happiness under 25 | Sad and teary |
| You click him when nothing is waiting | Petted and beaming |
| You drag him | That is his new home spot |

When he chases your cursor he parks as soon as he gets close and stays put while your cursor is
nearby, so he is easy to click. He only sets off again if you move more than about 260 px away.
Chasing is a reaction, never something he does on his own. As soon as the alert is over, whether you
clicked him, muted the session, or came back to the editor, he heads straight back to his home spot.

Happiness drops while finished sessions sit unattended and while the poop pile sits there. It rises
when you pet Clawd, clean up, or answer a session within three minutes.

## Build and run

```sh
./scripts/run.sh          # build dist/ClawdPet.app and launch it
./scripts/build.sh        # build only
cp -R dist/ClawdPet.app /Applications/   # optional, needed for Launch at login
```

On first launch it offers to install the Claude Code hooks. You can also do it from the terminal:

```sh
.build/release/ClawdPet --install-hooks     # or --uninstall-hooks
```

That adds async `command` hooks and a status line to `~/.claude/settings.json` (a backup is written
next to it). If you already had a status line it keeps running; ours forwards the JSON to the pet
and then calls yours. Restart open Claude sessions so they pick up the hooks.

## Clicking Clawd

Click him to acknowledge the oldest finished session and get back to VS Code.

Without extra permission that only brings VS Code (or, if no editor is running, your terminal) to
the front with all its windows. It never opens the project folder, so you will not get a second
window. Grant the app Accessibility permission (Settings menu, or System Settings > Privacy &
Security > Accessibility) and Clawd instead finds the editor or terminal window whose title carries
the project name and brings that one forward, even if it is minimised or on another Space. The same
permission lets him read the title of the window in front, which is how he knows to stay quiet when
you are already looking at the session that just finished.

The app is ad-hoc signed, so after a rebuild macOS treats it as a new app and silently drops that
grant: untick and re-tick ClawdPet in the Accessibility list if raising stops working. To keep the
grant across rebuilds, make a self-signed code-signing certificate once (Keychain Access >
Certificate Assistant > Create a Certificate, type Code Signing) and build with
`CLAWDPET_SIGN_IDENTITY="<its name>" ./scripts/run.sh`.

Click him when nothing is waiting to pet him. Drag him to set a new home spot. Right-click or use
the menu bar icon for sessions, meters, settings, and a Playground that fakes every state.

## How sessions are found

Two sources, merged by session id:

1. **Hooks** (installed into settings.json). Instant, and the only way to see permission prompts.
   Sessions that were already open when the hooks were installed do not have them until restarted.
2. **Transcripts.** Every 5 s the app checks `~/.claude/projects/*/*.jsonl` for files touched in the
   last two hours and reads the tail. That gives each session its AI title (the same one Claude Code
   shows), its folder, and whether the last message ended the turn. A session found this way still
   triggers the chase when it goes from working to finished. Turn this off in Settings if you like.

`ClawdPet --scan` prints what the scanner sees. The menu lists every session as
`title · folder · state · last activity`, and its submenu shows the full path, which source found it,
and the session id.

## Choosing which chats he nags about

Tick marks in the menu mean watched. Open a session's submenu to mute it, mark it seen, or forget
it. Muted sessions still show in the list but never trigger the chase.

## Settings

- Hide while VS Code is in front (default on). Clawd stays out of the way while you are in the
  editor.
- Come out over VS Code when Claude needs me (default on). Even while hidden, he appears and chases
  your cursor the moment a session finishes or needs permission. Turn this off if you only want him
  when you have clicked away.
- Stay quiet about the window I'm looking at (default on, needs Accessibility). No alert when the
  session that finished is in the frontmost window.
- Calm down when I return to VS Code (default on). Sessions that were already waiting when you come
  back to the editor are marked seen after 8 s. A session that finishes while you are already in the
  editor stays until you click him.
- Play a sound when Claude finishes (default off).
- Find sessions by watching transcripts (default on).
- Launch at login. Requires the app to live in `/Applications`.
- Port: `ClawdPet --port 4343` or set `CLAWD_PET_PORT` for the hook scripts.

## Testing without Claude

```sh
./scripts/simulate.sh          # a fake session: start, work, compact, finish
./scripts/simulate.sh limit    # hit the 5-hour limit
./scripts/simulate.sh reset
open dist/ClawdPet.app --args --demo      # cycle every animation
.build/release/ClawdPet --render-sheet sheet.png   # all frames on light, dark and mid grey
```

## Editing the art

Everything is in `Sources/ClawdPet/Sprites.swift`. Frames are 24x24 character grids drawn at 4x.
The body is built by `compose()` from eyes, mouth, legs, and overlays drawn over or under it, so
adding an animation is a new case in `Activity` plus a list of `FrameSpec`s. Palette letters are in
`Palette.colors`.

Two rules keep it legible on any wallpaper:

- Props are filled with mid tones, which read on both black and white, and coloured props need no
  outline. Only the laptop, whose screen is pale, carries a dark border.
- Check every change on all three backgrounds:

```sh
.build/release/ClawdPet --render-sheet sheet.png   # writes sheet-light, sheet-dark, sheet-mid
```

Pacing lives in `PetController.routine`: each entry has a weight and a duration range. Long actions
run for minutes, treats for seconds, and the same action never repeats twice in a row. Per-frame
speed is in `Sprites.frameDuration`.

## Layout

```
Sources/ClawdPet/
  main.swift              CLI flags, app start
  AppDelegate.swift       wires everything, first-run hook offer
  Sprites.swift           palette, body composer, animations, icon renderers
  PetModel.swift          sessions, meters, happiness, hook event handling
  PetPanel.swift          transparent floating panel, pixel view, behaviour loop
  HookServer.swift        local HTTP listener on 127.0.0.1:4242
  TranscriptScanner.swift finds sessions by reading transcript tails in ~/.claude/projects
  HookInstaller.swift     merges hooks + status line into ~/.claude/settings.json
  WindowRaiser.swift      raises the existing editor window for a project (Accessibility API)
  StatusBarController.swift  menu bar icon and menus
scripts/                  build, run, simulate
```
