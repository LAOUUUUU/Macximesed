# External research: Step 8, Games (macOS 27)
**Date:** 2026-11-24. **By:** research-scout agent (Haiku, high effort), saved by the main session.
Sources inline with dates; confidence High / Medium / Low.

## 1. Game Mode
- **What it does** (Apple WWDC26 session 356, 2026, High): higher CPU/GPU priority, less background-task impact, double Bluetooth sampling. It's automatic for apps categorised as games. https://developer.apple.com/videos/play/wwdc2026/356/
- **When it's on** (Apple support, current, High): on in full screen, off on quit. The toggle is in Game Overlay (Command-Esc or the Game menu), and a manual off sticks for that game. https://support.apple.com/105118
- **Keys** (Apple DTS, Jul 2025, Medium-High): `LSSupportsGameMode` (macOS 26+) and `GCSupportsGameMode` (macOS 14+). They only make an app eligible; the OS decides. https://developer.apple.com/forums/thread/782343
- **Launchers** (Apple forum, Jun 2026, Medium): a game launched by Steam inherits Game Mode. A launcher's own child process doesn't. https://developer.apple.com/forums/thread/830674
- **Logs** (Eclectic Light, Oct 2023, Medium-Low for 27): gamepolicyd logs "Game mode enabled", and GamePolicyAgent logs "Game mode is on, with N user game processes". https://eclecticlight.co/2023/10/17/what-does-game-mode-do/
- **`gamepolicyctl`** (torqer.app, Oct 2026, Low): it claims an Xcode-bundled `gamepolicyctl game-mode set on|auto`. Unconfirmed, and not present on Lao's 27.0.1 without Xcode's developer tools. Don't build on it. https://torqer.app/how-to-enable-game-mode-on-mac-for-crossover-sikarugir-and-wine-games/
- **Checking it's on:** there's no public API. The Metal HUD shows Game Mode, but only inside the app.

## 2. Metal Performance HUD
- **Switches:** `MTL_HUD_ENABLED=1` works outside Xcode. `MetalForceHudEnabled` in user defaults applies to later launches (Apple tech talk 110339, ~2022; existence High, behaviour on 27 unverified). https://developer.apple.com/videos/play/tech-talks/110339
- **macOS 26.0:** HUD variables worked apart from the value range (Apple DTS, Sep 2025, Medium). https://developer.apple.com/forums/thread/801396
- **`open --env NAME=VALUE`** exists (man page, 2017); unverified on 27. https://keith.github.io/xcode-man-pages/open.1.html
- **MetalHUDEnabler:** writes `MetalForceHudEnabled` into an app's defaults, and `MTL_HUD_ENABLED` into a CrossOver bottle's `cxbottle.conf`. Deleting the keys undoes it. https://github.com/precisionetica/MetalHUDEnabler
- **Steam and CrossOver** launch the game process themselves, so `open --env` probably doesn't reach the game (inference).
- **Apple's 2026 HUD docs:** `MTL_HUD_INSIGHTS_ENABLED=1` (native apps and GPTK only), a Rosetta line for x86_64, and no system-wide GPU-utilisation metric. https://developer.apple.com/documentation/xcode/gaining-performance-insights-with-metal-performance-hud

## 3. Finding games
- **`LSApplicationCategoryType`:** Apple's key page has no value list. The `public.app-category.*-games` values are unverified. https://developer.apple.com/app-store/categories/
- **Steam:** `~/Library/Application Support/Steam/steamapps/appmanifest_<id>.acf`. Third-party sources only; unverified on 27.
- **Epic:** `/Users/Shared/Epic Games` (one third-party snippet). **GOG Galaxy and Battle.net:** not found.
- **CrossOver bottles:** `~/Library/Application Support/CrossOver/Bottles`, moved by `BottleDir`; `drive_c` is C: (CodeWeavers, 2023-09-28, High). https://support.codeweavers.com/advanced-crossover-mac-configuration
- **CrossOver** has no way to list installed Windows apps; the user browses for the `.exe` (CodeWeavers, High). https://support.codeweavers.com/2-creating-a-launcher-for-a-windows-application
- **GeForce NOW:** bundle id `com.nvidia.gfnpc.mall` (catalogue, Medium). https://doesitarm.com/app/nvidia-geforce-now

## 4. Running it in 2026
- **Rosetta** (Apple developer news, 1 Sep 2026, High): "macOS 27: final release to support Rosetta." Intel-only apps stop working after macOS 27. Rosetta stays for older, unmaintained games that rely on Intel frameworks, with no end date given. https://developer.apple.com/news/?id=w5ngl9k2
- **Warnings:** macOS 26.4+ warns when a Rosetta app launches (MacRumors, 16 Feb 2026, High). https://www.macrumors.com/2026/02/16/macos-tahoe-26-4-rosetta-2-warnings
- **CrossOver 26** (11 Feb 2026, High): Wine 11.0, D3DMetal 3.0. https://alternativeto.net/news/2026/2/crossover-26-released-with-wine-11-ntsync-on-linux-and-support-for-many-new-games-on-mac
- **CrossOver 27** (Jun 2026, Medium-High): Apple silicon only, macOS Sonoma+, 32-bit bottles removed. https://borncity.com/news/crossover-27-codeweavers-streicht-intel-support-komplett/
- **Game Porting Toolkit 4:** a developer evaluation tool, not a way for players to run games. https://developer.apple.com/games/game-porting-toolkit
- **GeForce NOW** has a native Apple-silicon app (NVIDIA release notes, Medium). https://www.nvidia.com/en-gb/geforce-now/release-highlights/

## 5. Heat and GPU without root
- **`ProcessInfo.thermalState`:** nominal, fair, serious, critical (High). https://stanislas.blog/2025/12/macos-thermal-throttling-app/
- **Notify `com.apple.system.thermalpressurelevel`:** no root, levels 0–4, undocumented (Medium).
- **WWDC26 388:** thermal state shifts under load; `metalperftrace` is a developer CLI. https://developer.apple.com/videos/play/wwdc2026/388/
- **MetricKit Metal frame rate:** only for apps that ship with it. https://developer.apple.com/wwdc26/guides/games/
- **Temperature:** `IOPMPowerSource` stops returning Temperature on macOS 27 (FB24621108, Sep 2026, Medium). https://developer.apple.com/forums/thread/844418
- **GPU utilisation:** no public API (High). https://developer.apple.com/forums/thread/746722 The undocumented `IOAccelerator` `PerformanceStatistics` "Device Utilization %" is readable without root, with keys that vary by GPU (Medium-Low). https://docs.rs/crate/vor/0.1.0/source/src/gpu/mac.rs

## What this changes in the plan
- **Game Mode:** report only (declared keys, category, a full-screen reminder). Never force it; drop `gamepolicyctl`.
- **HUD:** `open --env` for native apps macx launches. CrossOver through `cxbottle.conf`, or skip it. Undo by deleting the key. Test on 27 first.
- **Scanner:** category, Game Mode keys, Steam manifests (test the path). Epic, GOG and Battle.net as user-added folders.
- **CrossOver:** read `BottleDir`; don't claim to list apps. CrossOver 27 needs Apple silicon and Sonoma.
- **Rosetta:** flag Intel-only games as "stops after macOS 27"; suggest native builds or GeForce NOW.
- **Heat timeline:** thermal state, the pressure notification, the game's own CPU load. No degrees. GPU utilisation only behind an experimental flag.

## Unverified
`gamepolicyctl`; the Steam, Epic, GOG and Battle.net paths; category values; Game Mode log lines on 27; `MetalForceHudEnabled` and `open --env` on 27; the hardened runtime's effect on HUD variables; GPU utilisation on 27; the end date for Rosetta's games subset.
