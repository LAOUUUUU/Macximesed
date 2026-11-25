# Research: Performance round 2 (SOCD, game network, raw mouse, Focus) and the app's Performance tab

Asked by Lao on 2026-11-25: "do research for performance boost and make a performance tab in the app". A friend of Lao's had asked for SOCD. This builds on [research/boost-games/RESEARCH.md](../boost-games/RESEARCH.md), which already settled these points: clocks can't be raised, Game Mode can't be forced, temperatures aren't readable, pausing Spotlight saves little, and the Metal HUD works through an environment variable. They aren't repeated here.

## The Performance tab (building now: it only puts existing features in the app)
`macx top`, `macx boost`, `macx tune` and `macx games` exist on the command line but have no page in the app. The tab shows:
- **Live:** macOS's thermal state (Nominal, Fair, Serious, Critical; Serious and above means it's throttling), and the busiest processes by real CPU time, every 2 s.
- **Boost:** on or off for the front app, and what it changed (from Boost's own ledger, so *off* puts back exactly what was there).
- **Tune:** each reversible tweak with an On | Off switch.
- **Games:** the games found, how best to run each (native, Rosetta, CrossOver, GeForce NOW), and **Play** (Boost, then the game, then Boost off when it quits).

All of it runs the app's own `macx`, the same code as the command line, and shows in the status bar.

## New boosts: findings (checked 2026-11-25)

### 1. SOCD / snap tap (last key wins between opposite directions)
- **How:** a session event tap (`CGEventTap`) that sees the movement keys and posts key-up for the opposite one. Listening needs **Input Monitoring** and changing keys needs **Accessibility** ([Apple DTS](https://developer.apple.com/forums/thread/758554), [forum](https://developer.apple.com/forums/thread/828052)). Karabiner-Elements does the same at the driver level with DriverKit, which needs a system extension ([docs](https://docsearch.algolia.com/mcp/docs/repo/pqrs-org/karabiner-elements)).
- **A real risk:** if Accessibility is revoked while a tap is active, all input can freeze until a forced restart, on Sequoia, Tahoe and 27 ([Apple forum, 2026](https://developer.apple.com/forums/thread/844416)). A tap must watch for that and remove itself first.
- **Games kick for it:** Valve kicks from official CS2 matches for SOCD, Snap Tap and null binds (Aug 2024), with some wrongful kicks reported. ESL bans it ([PC Gamer](https://www.pcgamer.com/games/fps/valve-says-weve-decided-to-draw-a-clear-line-and-bans-snap-tap-keyboard-automation-from-counter-strike-2), [Dexerto](https://dexerto.com/tech/counter-strike-2-players-report-being-wrongly-kicked-for-input-automation-after-socd-update-2868830)). I found nothing newer than 2024: re-check before shipping.
- **For an antivirus,** a keyboard tap is what keyloggers use, and macx's own watch flags an Input Monitoring grant.
- **Recommendation:** build it, but only as a per-game opt-in that is off by default. It's active only while that game is the front app, only on the keys picked (WASD by default), never logs anything, and removes the tap the moment a permission changes. Show a plain warning that CS2 and leagues kick for it.

### 2. Game network: AWDL lag spikes
- **Cause:** AWDL (AirDrop and AirPlay discovery) switches the Wi-Fi radio to another channel every 1–2 s, and traffic stalls for about 80–90 ms each time ([measurements](https://adamlovattdevops.github.io/awdl-latency-killer/), [Apple forum](https://developer.apple.com/forums/thread/97805?page=2)). It's still reported on macOS 27.2 beta, where turning off AirDrop in System Settings stopped the spikes ([Apple forum, 2026](https://developer.apple.com/forums/thread/847171)).
- **Fix:** `ifconfig awdl0 down` needs root, comes back after sleep, and turns off AirDrop and AirPlay while it's down ([Meter](https://meter.com/mac-osx-awdl-psa)). One 26.3.1 report says it stopped helping, so it must be measured, not promised.
- **Recommendation:** "Game network" in Boost for games. The root background watch is already there to do the root part (no new privileges). It puts awdl0 down while the game runs and back up when it quits or the Mac sleeps, and Boost measures gateway ping jitter before and after so you can see whether it helped on your Mac. Lao's Mac has had Wi-Fi lag spikes before, so this is the most likely real gain.

### 3. Raw mouse (pointer acceleration off) while gaming
- macOS has a *Pointer acceleration* switch (Settings > Mouse > Advanced, Sonoma and later), and `defaults write -g com.apple.mouse.scaling -1` does the same ([Apple](https://support.apple.com/en-gb/guide/mac-help/mchlp1138/26/mac), [Tom's Guide](https://www.tomsguide.com/how-to/how-to-disable-mouse-acceleration-macos)). Moving the speed slider turns it back on ([Apple Community](https://discussions.apple.com/thread/251918144)).
- **Recommendation:** a Boost option for games, written to the ledger like Boost's other settings, so the old value comes back after the game. The trackpad stays as it is.

### 4. Do Not Disturb while playing
- There's no public switch. Shortcuts can do it (`shortcuts run "<name>"` with a *Set Focus* shortcut you make once) ([guide](https://heyfocus.com/blog/how-to-turn-on-mac-focus-mode-from-the-terminal)).
- **Recommendation:** optional, in Settings: "Run this shortcut when a game starts, and this one when it ends". You make the shortcuts. macx never edits Focus itself.

## Not doing
- Raising clocks, forcing Game Mode, reading temperatures (see the first research round).
- Killing or pausing macOS's own processes (the Risky tier rule).

## Build order once approved
1. The Performance tab (no approval needed: it's existing features).
2. Raw mouse and Game network in Boost for games (reversible, measured).
3. SOCD: opt-in per game, after a permission and anti-cheat re-check.
4. Focus shortcuts hook.
