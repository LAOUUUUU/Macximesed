# Research: first-run welcome and setup
**Date:** 2026-11-24
**Status:** Approved by Lao 2026-11-24 and built
**Researcher:** Claude Code

## Question
Lao: "like here at the start when u install the app it should welcome u with like coolish animations and stuff a nd some stuff to enbale before u start the app fully". What does the first open of Macximesed.app show, which permissions and parts does it switch on, how does each step know it worked, and how does it move without looking AI-made?

## Constraints
- **Lao's taste:** the app's look from [research/app-ui/RESEARCH.md](../app-ui/RESEARCH.md) (paper and ink, New York for state, SF Mono for technical text, helper text behind ⓘ buttons).
  - No gradients, glows, pills, emoji, confetti or icon tiles.
  - The motion has to be "coolish" but calm: it shows something happening, never decoration that loops.
- **Nothing about the app's identity changes:** same bundle, signature and Full Disk Access. Root steps go through `AppModel.runAdmin(_:why:)`, which passes the user and says what the password is for (fixed on dev in 561f306).
- **macOS adds its own lines to the password dialog**, including "could not verify this script". The flow says so before the dialog appears, so it doesn't look like an attack.

## Findings
- **Apple's guidance:** onboarding should be fast, optional and skippable, and it shouldn't be part of launch. Ask for a permission when a feature needs it, not all at once ([HIG: Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding.md)). Macximesed is the exception that proves the rule: without Full Disk Access and the daemon, its main feature doesn't work. So the setup asks for exactly those, explains each, and every step can be skipped and done later from Settings.
- **Full Disk Access:**
  - **Dragging the app into the list works**: an Apple DTS engineer confirmed it, but people get confused dragging between two half-covered windows ([mjtsai, 2019](https://mjtsai.com/blog/2019/01/28/people-dont-read-similar-dialogs/)). So the main path is *Open Settings* plus three short numbered steps. The drag is offered as a second way, from a small handle beside the steps.
  - **On macOS 27.3 and later** people can grant only specific folders ([Apple support 149699](https://support.apple.com/en-bn/149699)). eslogger needs full access, so the step says to choose full access.
  - **The step checks by itself**, every second, with `PrivacyPolicy.probeFullDiskAccess()`, which never sets off a popup. There's nothing to press when it turns on.
  - **"Listed but refused":** if the switch is on but the check still fails, that's the known stale-code-requirement case (see the `macx privacy` notes). The step then shows the fix: remove it with − and add it again with +.
- **Notifications:** today the daemon notifies through `osascript display notification`, run as you. Those notifications most likely belong to Script Editor or osascript in System Settings > Notifications, not to Macximesed. That means Macximesed can't check or ask for the permission. (Unverified: I'll check on the Mac before building.)
  - **Proposal:** the app posts alert notifications itself through UNUserNotificationCenter, with its own permission, which this step asks for and checks ([Apple: asking permission](https://developer.apple.com/tutorials/data/documentation/usernotifications/asking-permission-to-use-notifications.md)). The daemon keeps its osascript notifications only while the app isn't running: it checks for the app's own process, not a file a stealer could touch.
- **Background watch:** Install… goes through the admin prompt, and the step watches `launchctl` and the status file until the watch says *watching* (usually 2–5 s). If eslogger is refused, it goes back to the Full Disk Access step.
- **Optional extras:**
  - **The detonation chamber** (`macx chamber setup`, about 50 MB from Alpine Linux): off unless you choose it, and it says the size first.
  - **The update channel and hash feed check:** one quiet check, with its result shown.
  - **Open at login:** SMAppService.

## Proposed flow
It's a separate 760×560 window that opens instead of the main window on first launch. The main window opens when setup finishes or is skipped. Settings gets a *Run setup again* button. Each screen has the same parts:
- a small-caps step label ("2 of 5");
- a New York sentence;
- one line of reason;
- the live check;
- the buttons, on the right: *Continue* filled, *Skip* as plain text.

0. **Welcome.** The menu bar mark draws itself, then the name and one line: *"It watches for the tricks stealers use, and tells you when it sees one."* Button: *Set it up*. Under it, in mono: `About 2 minutes · nothing leaves your Mac`.
1. **Full Disk Access.** Live state: *Off* → *On*. Open Settings, the three steps, the drag handle, and the macOS 27.3 note behind ⓘ.
2. **Background watch.** *Install…*, with the freeze-on-critical choice as an On | Off control. Live state: *Not installed* → *Starting* → *Watching*.
3. **Notifications.** *Allow…* opens the system prompt. Live state.
4. **Extras.** Three rows with On | Off: open at login (on), the chamber (off, *50 MB*), check for updates now (on).
5. **Ready.** *"Watching."* plus a list of what's on, and *What else is in here*: `macx top`, Boost, Tune, Games, Check a file, the chamber, each on one line. Button: *Open Macximesed*.

## Motion
The rules:
- every animation is 200–600 ms and ease-out;
- nothing loops except a waiting check;
- Reduce Motion turns movement into a plain crossfade.

What moves:
- **The welcome mark:**
  - **draws:** its outline strokes on, from one corner around the square, in 600 ms;
  - **fills:** the centre fills, in 250 ms;
  - **text:** the name and the line fade up 8 pt, staggered by 80 ms.
- **Between steps:** the old screen moves 24 pt left and fades, and the new one comes in from 24 pt right (300 ms). The progress line along the bottom fills to the step's share.
- **A live check:**
  - **while waiting**, a 7 pt square outline breathes between 40% and 100% opacity every 1.6 s. That's the only loop.
  - **when the check passes**, the square fills (the same move as the menu bar mark) and the state word crossfades to *On*, *Watching* and so on. Continue becomes the filled button.
- **Ready:** the list of what's on appears one line at a time, 60 ms apart.

## Risks
- **Notifications:** the proposal moves alert notifications from the daemon to the app while it's running. That's a behaviour change, built test-first; the daemon's fallback stays.
- **SwiftUI and macOS 15:** the stroke-on needs `trim(from:to:)` on a Path, which works on macOS 15.
- **A first-run flag in UserDefaults** (`setupDone` plus the version). If Full Disk Access later goes off, the main window says so; setup doesn't open again by itself.

## Mockup
Design canvas, page "Welcome": https://claude.ai/artifact/WsiwurZLB87PMLooT5NBt3. The flow on it is clickable (Play).
