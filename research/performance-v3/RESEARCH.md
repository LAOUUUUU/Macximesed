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

## Plan
1. "Why it's slow" (known Apple culprits, exact paths, advice only).
2. Quit button in the Memory view (asks first, ordinary quit, non-Apple apps only).
3. Power awareness in the header.
4. Virtual display **experiment**: prototype, measure FPS with the Metal HUD in one game, ship only if it helps.

## Not doing
- Stopping, renicing or disabling Apple's own daemons (Risky tier, step 10).
- Promising FPS gains we haven't measured.
