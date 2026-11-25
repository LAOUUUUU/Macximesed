# Research: Performance round 3 (Medium tier, "what's slowing me down", memory, virtual display)

Asked by Lao on 2026-11-25: "keep making more performance stuff, go to medium or do research, also add virtual display in the plan". Builds on round 1 ([research/boost-games](../boost-games/RESEARCH.md)) and round 2 ([research/performance-v2](../performance-v2/RESEARCH.md)). The rules stay: everything reversible, nothing of Apple's is stopped or deleted (that's the Risky tier), and nothing is promised without a measurement.

## Findings (checked 2026-11-25)

### Lowering resolution is the main lever for games on an Air
Reviews of the M3 Air agree that AAA games are only playable after turning the resolution and visual preset down, and that long sessions throttle on a fanless Air ([Digital Trends via Yahoo](https://tech.yahoo.com/computing/articles/played-baldur-gate-3-m3-140029867.html), [Geeky Gadgets](https://www.geeky-gadgets.com/macbook-air-gaming-performance/)). Playing on battery is slower than plugged in ([Setapp 2026](https://setapp.com/how-to/best-gaming-macbooks)).

### Virtual display
- There's **no public API**. BetterDisplay, BetterDummy and others use Core Graphics' undocumented `CGVirtualDisplay`. It can make HiDPI modes at chosen sizes, for example 800×600 points backed by 1600×1200 pixels ([go wrapper](https://pkg.go.dev/github.com/go-macos/virtualdisplay), [BetterDisplay](https://github.com/waydabber/BetterDisplay/wiki/Fully-scalable-HiDPI-desktop)).
- It can **break between macOS versions**: BetterDisplay ships a separate 5.x for macOS 27, and 26.3.1/26.4 broke several display apps ([BetterDisplay README](https://cdn.jsdelivr.net/gh/waydabber/BetterDisplay@landing/README.md), [Apple forum](https://developer.apple.com/forums/thread/819331)).
- **No source measured a gaming gain.** What it could do for performance: give a game a smaller screen to fill. Most games already have their own resolution setting, so the gain is likely only for games that don't (some ports, some CrossOver titles). It also gives streamers a second screen.
- **Recommendation:** an experiment, not a feature yet. Build a prototype that adds a virtual display at a chosen size and removes it when the game quits. Then measure frames per second with the Metal HUD (already in `macx games play --hud`) with and without it. It ships only if it measurably helps a real game, behind an "Experimental" label.

### What's slowing the Mac down: name the usual culprits instead of guessing
- **Photos' AI analysis** (`mediaanalysisd`, `photoanalysisd`) runs at 50–150% CPU for hours, especially after a macOS update, and finishes by itself when the Mac is left plugged in. Killing it doesn't help, because macOS restarts it ([9to5Mac, 2026-06](https://9to5mac.com/2026/06/03/mac-beachballs-or-lagging-performance-ai-photo-scanning-may-be-the-reason/), [Apple Community](https://discussions.apple.com/thread/256138728)).
- **WindowServer** high CPU or GPU is usually caused by one app (Photoshop's Application Frame, a paused Parallels VM) ([Adobe forum](https://community.adobe.com/bug-reports-711/p-macos26-photoshop-v27-5-later-extremely-high-gpu-usage-from-the-windowserver-process-1558221/index1.html), [Apple Community](https://discussions.apple.com/thread/256158509)).
- **Spotlight** (`mds_stores`) re-indexes after updates and big copies.
- **Recommendation:** a "Why it's slow" line on the Performance tab. When one of these known processes is at the top, say what it is in plain words and what actually helps (plug in overnight, quit the app behind WindowServer, wait for indexing). macx never stops it: they're Apple's. Matching is by exact process path under `/System`, not by name guessing.

### Memory (round 2 added the pressure level)
- When memory is tight, the biggest *user* apps are where the gain is. **Recommendation:** a *Quit* button next to non-Apple apps in the Memory view. It asks first, and it's an ordinary quit (`NSRunningApplication.terminate`), so the app can save its work. No force quit.

### Medium tier: more reversible tweaks
Candidates, each with a stored before-value and an undo, measured before it's listed:
- **Power awareness:** show on battery or plugged in, and warn that games are slower on battery. Report only.
- **Background Photos analysis while gaming:** nothing safe to switch (it's Apple's), so report only, through "Why it's slow".
- **Login items** (from `macx persist`) that start heavy apps: a link from the Performance tab to Startup items, with the biggest ones marked.

### More, added on Lao's ask (checked 2026-11-25)

#### Per-game advice for the games Lao plays
- **Minecraft (Prism Launcher, Modrinth App).** Prism runs a native ARM64 Minecraft, which is the first step on Apple silicon. Sodium (rendering) plus Lithium (game logic) is the standard pair, and FerriteCore cuts memory ([Sodium](https://modrinth.com/project/sodium), [Mac Native modpack](https://modrinth.com/modpack/mac-native)). Metal renderers exist but are alpha ([MetalRender](https://modrinth.com/mod/metalrender), [mcopt](https://github.com/noahdunnagan/mcopt/wiki)). More memory isn't always better, because bigger heaps mean longer garbage-collection pauses ([guide](https://www.online-tech-tips.com/minecraft-performance-optimization-guide/)).
  **Recommendation:** a read-only Minecraft check. macx reads each Prism/Modrinth instance's own settings and mods folder and reports whether Java is ARM64 or Intel (Rosetta), how much memory is set aside compared with the Mac's, and which of Sodium, Lithium and FerriteCore are missing, with a link to each on Modrinth. It never edits an instance.
- **Roblox.** Roblox has an official *Maximum Framerate* setting (up to 240) ([Roblox](https://devforum.roblox.com/t/introducing-the-maximum-framerate-setting/2995965/1)). The old `ClientAppSettings.json` FPS flag is marked outdated, must be redone after every update, and is unverified for 2026 ([DevForum](https://devforum.roblox.com/t/how-to-unlock-the-60-fps-cap-withwithout-software/2220352)). macOS caps the frame rate at the display's refresh rate, so above 60 FPS is wasted on the Air's 60 Hz screen ([rbxfpsunlocker-osx](https://github.com/lanylow/rbxfpsunlocker-osx/releases)).
  **Recommendation:** advice only. Use the in-game setting, at your display's refresh rate. macx doesn't touch Roblox's files or memory (that's how anti-cheat bans happen).
- **Display refresh rate:** the Games list says what your screen's refresh rate is (60 Hz on the Air, more on some external monitors), so you know when an FPS cap above it is pointless.

#### Backups and sync while gaming
- `tmutil stopbackup` stops a running Time Machine backup without root. Pausing future backups (`tmutil disable`/`enable`) needs root, and can fail silently without Full Disk Access, so the state must be checked afterwards ([Eclectic Light](https://eclecticlight.co/2020/01/22/time-machine-11-tmutil/), [Apple Community](https://discussions.apple.com/thread/254295393)).
  **Recommendation:** a *Pause backups while playing* switch in While playing. Play stops a running backup, and the background watch (root, with Full Disk Access) turns automatic backups off for the game and back on after, checking with `tmutil status`, the same way Game network does AWDL. I found no command for pausing iCloud Drive, so that's not included.

#### Disk space
- Swap needs free space, and a nearly full disk makes a memory-tight Mac much slower. **Recommendation:** warn in the header under 10% free, with a link to Clean.

### Small boosts (Lao, 2026-11-25: "even if it's a small boost, a boost is a boost")
Each one is reversible, measured on Lao's Mac where it can be, and shown with what it costs:
- **Background hogs:** an app using CPU while it isn't the front app (Roblox at 30% while Lao wasn't playing, 2026-11-25) gets a line: "Roblox is using 30% in the background. Quit it?", with Quit asking first.
- **Heavy browser tab:** `com.apple.WebKit.WebContent` or a Chrome renderer at the top says "a web page is busy", which tab-heavy browsing usually is.
- **Video decoding in the background** (`VTDecoderXPCService`) at the top: a video still playing somewhere, or a moving wallpaper.
- **Moving (Aerial) wallpapers** keep the GPU decoding video. Detect a dynamic wallpaper and offer a still one (the user's own choice in Settings; macx only explains and opens the pane).
- **Desktop widgets** refresh in the background; list them and say so (report only).
- **Brightness:** on a fanless Air a lower screen brightness means a little less heat (report only).
- **Charging heat:** charging while gaming adds heat; mention Optimized Battery Charging (report only).
- **Third-party launch agents** that start at login (already in `macx tune agents`): link them from the Performance tab, with the biggest first.

### Extreme (step 12, off by default)
With SIP off, Apple's own daemons can be turned off system-wide. On macOS 27, turning off Photos analysis per user was refused while SIP is on: *"Operation not permitted while System Integrity Protection is engaged"* (tested on Lao's Mac 2026-11-25, then put back). Extreme is the only way to the biggest background savings, and it costs a lot:
- You turn SIP off yourself in Recovery (`csrutil disable`). macx never does it, and walks you through it and back.
- With SIP off the antivirus half is weaker (malware can do the same), so every `macx` command shows a banner while it's off.
- Best on a freshly installed Mac, not a daily driver.
- What it does: system-domain `launchctl disable` of the curated list (Photos and media analysis, Siri and knowledge, intelligence agents, widgets, Game Center), each with its undo, behind the three confirmations, and `macx extreme restore` puts everything back before SIP goes back on.

## Plan
1. "Why it's slow" (known Apple culprits, exact paths, advice only).
2. Quit button in the Memory view (asks first, ordinary quit, non-Apple apps only).
3. Power awareness in the header.
4. Disk-space warning.
5. Minecraft check (Java architecture, memory, Sodium/Lithium/FerriteCore), Roblox advice, display refresh rate in Games.
6. *Pause backups while playing* (stop a running backup; automatic backups off via the background watch, checked).
7. Virtual display **experiment**: prototype, measure FPS with the Metal HUD in one game, ship only if it helps.
8. Small boosts: background hogs with Quit, busy web page and video-decode explanations, moving-wallpaper and widget notes, brightness and charging notes, login agents link.
9. Risky tier (research/risky-tier/RESEARCH.md): Spotlight indexing off, hibernation and Power Nap off, snapshot purge. Per-user Apple agent disables are out (refused with SIP on, tested).
10. Extreme (step 12): only after everything above, on Lao's explicit go, ideally on a fresh Mac.

## Not doing
- Stopping, renicing or disabling Apple's own daemons (Risky tier, step 10).
- Promising FPS gains we haven't measured.
