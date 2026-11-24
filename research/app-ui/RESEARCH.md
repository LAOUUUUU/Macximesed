# Research: Macximesed's Mac app and menu bar item
**Date:** 2026-11-23
**Status:** Waiting for Lao's approval (design mockup linked at the end)
**Researcher:** Claude Code

## Question
Lao: "make a ui and not using swift simple ui shit like a super good one with no ai look ui stuff and the menubar too". Everything Macximesed does today is a `macx` command. Roadmap step 11 is "root daemon + menu bar app", and the daemon half is done. What do we build the app in, how does it reach MacxCore, what goes on which screen, and what does it look like?

## Constraints (from the repo)
- **Full Disk Access belongs to `~/Applications/Macximesed.app`:** bundle id `dev.macximesed.macx`, signed with "Macximesed Local Signing". The TCC entry keeps the code requirement it captured when it was added (identifier + certificate leaf). The daemon (`/Library/LaunchDaemons/dev.macximesed.watch.plist`) runs `Contents/MacOS/macx watch --background`. Nothing here may change the bundle id, the identity or the daemon's path.
- **No new external dependencies** without asking. Today there's one (swift-argument-parser).
- **macOS 15 minimum, Swift 6, universal binary.** CI builds with warnings as errors on macos-15, macos-26 and macos-26-intel.
- **What the app can read without root** (checked on Lao's Mac, 2026-11-23):
  - `launchctl print system/dev.macximesed.watch` answers as a normal user: state and pid.
  - `/Library/Logs/Macximesed/status.json` is mode 644: watching, refused or stopped, plus a message and a time.
  - `~/Library/Logs/Macximesed/watch.jsonl` is the user's own file. `AlertRecord.parse` already reads it.
- **What needs root:** `daemon install`, `uninstall` and `restart`, and any pause.
- **The real alert log is loud.** Lao's log has 721 alerts on 2026-11-23. 568 are `quarantine-removed` and 70 are `exec-from-hidden-or-temp`, almost all from development builds. A flat list would be useless. **The app has to group repeats** (same rule + same program) and let you mark a program as expected. This is the biggest design finding.

## Findings

### Which UI technology

| Option | Look | Polish and feel | Size | Reaching MacxCore | Verdict |
|---|---|---|---|---|---|
| **Stock SwiftUI** (List, Form, NavigationSplitView, toolbar, MenuBarExtra) | The look Lao rejected. On macOS 26+ the sidebar, toolbar and popover are drawn as Liquid Glass, and there's no opt-out any more: the `com.apple.SwiftUI.DisableSolarium` default went in 26.1, and `UIDesignRequiresCompatibility` is iOS-side and is being retired. | Native | ~0 | Direct | No |
| **AppKit, all custom drawing** (NSView `draw(_:)`, layers) | Anything | Native | ~0 | Direct | Works, but 3–4× the code of the next option for the same pixels |
| **AppKit chrome + our own SwiftUI components** | Anything we draw. AppKit owns the window (full-size content, hidden title, no NSToolbar), so no glass toolbar or sidebar. The menu bar uses an NSStatusItem plus our own borderless NSPanel, not an NSPopover, so no glass popover. Inside, we use our own views (rows, buttons, tables, switches), never Form, List, GroupBox or the stock toolbar. | Native scrolling, text, focus, VoiceOver, dark mode, keyboard | ~0 (system frameworks) | Direct | **Recommended** |
| **WKWebView with local HTML** | Easy editorial look | Feels like a web page in a frame: scrolling, focus rings, selection, context menus. Caching traps (the `?v=` lesson from Barely-free) | ~0 | A JS bridge to MacxCore | No |
| **Electron or Tauri** | Anything | Non-native | 100+ MB | A sidecar process | No: new dependency, a second signed binary, Full Disk Access tangle |

Menu bar: SwiftUI's `MenuBarExtra` gives no first-party way to reach its status item or window (that's why the MenuBarExtraAccess package exists). Our own NSStatusItem lets us draw the glyph per state, use a right-click menu, and open a borderless panel. There's a macOS 27 beta report that views inside an NSStatusItem button stopped getting hover events. We don't need hover: a click opens the panel.

### How the app reaches MacxCore and keeps Full Disk Access
- **Option A, recommended: one executable.** `macx` gains an app mode.
  - `Info.plist` gets `LSEnvironment = {MACX_APP: 1}`. LaunchServices sets it only when the app is opened from Finder, the Dock, `open` or login items; it has no effect when the binary is run from a shell. With no arguments and that variable set, `macx` starts NSApplication. Otherwise it's the CLI, exactly as now.
  - The bundle id, `CFBundleExecutable`, the signature and the daemon's path don't change, so the existing Full Disk Access grant covers the app's own process. Clean and Apps then see Documents and Downloads with no popups.
  - Cost: the CLI and the daemon also link AppKit and SwiftUI. Both are system frameworks in the shared cache: the binary grows by about our UI code only, and the root daemon never creates an NSApplication. I'll measure binary size and the daemon's memory before and after, and report the numbers.
- **Option B: a second executable.** `Contents/MacOS/Macximesed` becomes `CFBundleExecutable` and `macx` sits beside it, signed separately with the same identifier. This changes the main executable the TCC requirement was captured against: the Settings round trip Lao is tired of. Only if A's numbers turn out bad.
- **Data:** MacxCore is linked directly, so there's no JSON round trip through `macx`. The views read Swift types (`AlertRecord`, `DaemonStatus`, `PersistenceItem`, scan and app reports). A `DispatchSource` file watcher on `watch.jsonl` updates the alerts as lines arrive, and the menu bar re-reads the status every few seconds.
- **Root actions** (install, uninstall, restart, pause): the app runs its own `macx daemon …` through the standard admin prompt (`do shell script … with administrator privileges`), and macOS asks for the password or Touch ID. `SMAppService.daemon` would need the plist inside the bundle and a Login Items approval. Not now: it changes how the daemon is installed.
- **Pause must need admin, never a file the user can write.** If the app could pause the watch by writing to `~/…`, so could a stealer. Proposal: `sudo macx daemon pause --for 1h` writes a root-owned `/Library/Logs/Macximesed/pause.json`. The daemon stops alerting until that time and then **resumes on its own**. `macx daemon resume` clears it. The menu bar shows "Paused until 21:40" in amber. This is a new CLI subcommand plus a daemon change, built test-first.

### Reference apps
- **Little Snitch 6** (Objective Development): a network monitor with a menu bar item and a main window. What to copy: the menu bar is a *place*, not a launcher. It shows recent activity and recent blocks at a glance, switches modes, flashes on a block, and shows a warning mark when the filter is off. What not to copy: the dense, chart-heavy main window.
- **Things 3** (Cultured Code): type and space do the work. There are no boxes, the hierarchy comes from size and weight, the sidebar is plain text with quiet counts, and a single accent is kept for meaning.
- **Panic's apps** (Transmit, Nova): custom chrome that still behaves natively. They prove a non-stock look doesn't have to feel like a web page.
- **Objective-See's LuLu and BlockBlock**: honest alert wording ("what, who, where" and an action), but stock, cramped AppKit. We take their wording discipline, not their look.

## Proposed information architecture
**Sidebar:** plain text, with counts set in mono at the right.
1. **Protection** (opens here)
   - One sentence that says the state: *Watching.* / *Paused until 21:40.* / *Not running.* / *Can't watch: Full Disk Access is off.*
   - Under it, facts in one line: since when, Full Disk Access, freeze-on-critical, the last alert.
   - **Alerts**, grouped by rule + program. Each group shows a count, the first and last time, and the severity.
   - Opening a group shows what happened (detail lines), the program path (mono), and actions:
     - Open incident case… (`macx incident`)
     - Show in Finder
     - Expected, don't group-alert again (a local allowlist; never for critical)
   - Filter: Critical and high / All.
2. **Startup items** (`persist`)
   - Items found with their verdict, sorted dangerous first.
   - A baseline: "Mark everything as known now", then later "3 new since 20 Nov".
   - Remove goes to the undo store.
3. **Check a file** (`check`)
   - A drop target that's just a hairline rectangle with one line of text, or Choose….
   - The verdict in plain words (*Looks fine* / *Partly unknown* / *Don't open this*), the reasons as a list, and the hash in mono.
   - When the chamber lands: "Run it in the chamber" (the other session owns that).
4. **Clean** (`scan` + `clean`, Safe tier)
   - The disk heading with free space, then the categories with sizes as tabular numerals and checkboxes.
   - Clean 4.2 GB. Every clean goes into the undo store, and the "Undo last clean" link stays visible.
5. **Apps** (`apps`)
   - A table: name, size, last used, leftovers.
   - Remove with leftovers, with undo. Built-in apps say *hidden, not deleted*.
6. **Settings**
   - Full Disk Access: on/off, with Open Settings and the exact steps.
   - Background watch: installed or not, with Install, Uninstall and Restart, each of which asks for the admin password.
   - Freeze on critical.
   - Updates: the channel, the last check, Check now.
   - Open at login.
   - Version.

**Menu bar item:**
- **The glyph:** a small monochrome template mark, drawn in code.
  - Normal: solid.
  - Paused: outline only.
  - Not running: outline with a slash.
  - An unread critical alert adds a dot in the system red, the one place colour shows in the menu bar.
- **Left click opens a panel**, 340 pt wide:
  - The state sentence.
  - The last 4 alert groups.
  - Pause for 1 hour… / Resume.
  - Open Macximesed.
- **Right click** opens a plain menu with the same actions plus Quit.

## Visual direction
- **Type:**
  - Headings in **New York** (Apple's serif, built into macOS, so nothing to bundle and no licence).
  - Body in SF Pro.
  - Paths, hashes, rules and times in SF Mono with tabular numerals.
  - One contrasting voice: small capitals spaced 0.12 em for section labels only.
  - Scale: 28 / 20 / 15 / 13 / 11.
- **Colour:**
  - Light: warm paper `#F3F1EC`, ink `#1B1B19`, grey `#5F5D58`, hairlines `#D9D5CC`.
  - Dark: `#141413`, ink `#E9E7E1`, grey `#9D9A93`, hairlines `#2F2E2B`.
  - One signal colour, red `#B3261E` (dark `#E8705C`), only for critical and high, and for "not running".
  - Amber `#8A5A00` (dark `#D9A441`), only for paused.
  - Everything else is ink. Severity also shows as a word and a mark shape, never colour alone.
- **Form:**
  - Hairline rules instead of boxes, square corners (2 pt at most), a 4 pt spacing grid.
  - Buttons are plain rectangles: primary filled ink, secondary a 1 px outline.
  - No gradients, glass, shadows (except the system's window shadow), pills, emoji, icon tiles or three-card rows.
  - Motion only where state changes, and none under Reduce Motion.
- **Helper text goes behind an info button** (Lao, 2026-11-23: "the small info text make into the info thingy"). The screen shows only the facts and the state. Explanations, paths, pids and signing details sit behind a 14 pt outlined ⓘ button that opens a small popover on click (hairline border, 4 pt corners, Escape or a click outside closes it), with the same text on hover as a tooltip. In AppKit that's an NSPopover-free panel of our own, so it doesn't get the glass look either.
- **Follows the system:** light/dark and accessibility text sizes (Dynamic Type isn't on macOS, so we scale our own sizes from the user's preferred text size) and Increase Contrast (hairlines become 1 px ink).

## Recommendation
- **Technology:** AppKit-owned windows and a status item, with our own SwiftUI components inside.
- **Packaging:** one executable that starts the app when opened from Finder (`LSEnvironment`). The bundle id, signature and daemon path stay the same, so Full Disk Access isn't touched.
- **Data:** MacxCore linked directly.
- **Root actions:** through the admin prompt.
- **Pause:** a new root-only, self-expiring `macx daemon pause`.
- **Build order:**
  1. App mode switch
  2. Menu bar
  3. Protection
  4. Settings
  5. Startup items
  6. Check a file
  7. Clean
  8. Apps

## Risks
- **The `LSEnvironment` switch** is old Apple documentation. I'll test it on 27.0.1 first. If it doesn't hold, the fallback is that LaunchServices passes no arguments and the parent is launchd (ppid 1), while a shell run always has a terminal parent.
- **Linking AppKit in the root daemon:** I'll measure memory before and after. If it costs more than about 10 MB, I'll switch to option B.
- **macOS 27.3's Full Disk Access changes** (early December) might add a menu-bar list of apps with access. That's not a problem for us, just more reason to keep the signature stable.
- **Groups and the "expected" allowlist** are new behaviour: test-first, and critical alerts can never be allowlisted.

## Sources
- [Apple forums: UIDesignRequiresCompatibility and iOS 27](https://developer.apple.com/forums/thread/832710); [Clarification on its planned removal](https://developer.apple.com/forums/thread/832543); [applech2: DisableSolarium removed in macOS 26.1](https://applech2.com/archives/20251025-apple-will-remove-liquid-glass-disable-flag-in-macos-26-1-tahoe.html)
- [MenuBarExtraAccess (no first-party access to MenuBarExtra's status item/window)](https://www.github.com/orchetect/MenuBarExtraAccess); [Pushing the limits of NSStatusItem](https://multi.app/blog/pushing-the-limits-nsstatusitem); [NSStatusItem issues on macOS 27](https://origin-devforums.apple.com/forums/thread/836113); [Are NSStatusItem interactions still allowed?](https://developer.apple.com/forums/thread/832823)
- [Apple: Launch Services keys (LSEnvironment)](https://developer.apple.com/library/watchos/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html); [LSEnvironment only applies to LaunchServices launches](https://lists.apple.com/archives/xcode-users/2006/Nov/msg00473.html)
- [Little Snitch 6 press release](https://obdev.at/press/pr/2024-05-21-Objective-Development-Releases-Little-Snitch-6.html); [Little Snitch 6 Help: status menu](https://help.obdev.at/littlesnitch6/pref-statusmenu); [MacRumors on Little Snitch 6](https://www.macrumors.com/2024/05/22/little-snitch-6-released-macos-sonoma/)

## Mockup
Design canvas (private Artifact): https://claude.ai/artifact/WsiwurZLB87PMLooT5NBt3. It has Protection in light and dark, the menu bar panel in light and dark with the glyph states, Startup items, Settings (dark), and a type and colour specimen. The browser shows New York through Source Serif 4 as a stand-in; the app uses the real New York.
