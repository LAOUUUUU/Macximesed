# Research: game launchers for Roblox and Minecraft

Asked by Lao on 2026-11-25: research launchers "like AppleBlox, and Lunar Client or stuff similar"; for Roblox, people want **unlimited FPS** and **cache editing**. Replaces the to-be-researched list in [PLAN.md](PLAN.md). Nothing is built yet: this brief needs Lao's OK first.

## Findings (checked 2026-11-25)

### Roblox
- **AppleBlox** is the macOS launcher modelled on Bloxstrap: Discord Rich Presence, FastFlag presets, custom flag profiles per game, settings applied before launch, auto-close when you leave a game ([GitHub](https://github.com/AppleBlox/appleblox), [AlternativeTo](https://alternativeto.net/software/appleblox/about)).
- **FastFlags are allowlisted now.** Roblox's client only honours flags on its official allowlist; any other flag "will simply be ignored", and "no further action will be taken against a user attempting to use a restricted Fast Flag". The list can change without warning ([Roblox DevForum](https://devforum.roblox.com/t/allowlist-for-local-client-configuration-via-fast-flags/3966569)). The FPS flags (`DFIntTaskSchedulerTargetFps`, the 240 cap flag) look **not** allowlisted: users are asking for them to be added ([request](https://devforum.roblox.com/t/allow-fps-related-fast-flags/3971185), [another](https://devforum.roblox.com/t/request-of-fflags-to-be-added-to-the-allow-list/3966737)).
- **Modified clients get banned.** Roblox may terminate accounts for "custom versions of the Roblox application binary" or "running instances of the official version of Roblox modified by external tools at runtime" ([Roblox DevForum](https://devforum.roblox.com/t/an-update-on-automated-action-against-modified-clients/3640609)). Memory-patching FPS unlockers such as rbxfpsunlocker-osx fall under the second part; that tool is also marked outdated ([releases](https://github.com/lanylow/rbxfpsunlocker-osx/releases)).
- **The Mac's own cap:** macOS caps a game's frame rate at the display's refresh rate, so on a 60 Hz MacBook Air no unlocker gets past 60 FPS ([rbxfpsunlocker-osx](https://github.com/lanylow/rbxfpsunlocker-osx/releases)). Roblox's built-in *Maximum Framerate* setting already goes up to 240 for faster screens ([Roblox](https://devforum.roblox.com/t/introducing-the-maximum-framerate-setting/2995965/1)).
- **Texture/cache editing:** Bloxstrap's "mods" replace the client's content files and re-apply them after updates ([Bloxstrap wiki](https://github.com/pizzaboxer/bloxstrap/wiki/Adding-custom-mods)). Roblox staff said Bloxstrap isn't affected by the modified-client detection "as it does not modify the client binary", while not supporting it officially ([Bloxstrap and bans](https://bloxstraplabs.com/wiki/info/bloxstrap-and-bans/)). Texture swaps are a grey area; the ones that give an advantage (seeing players through walls) are what draws bans ([DevForum](https://devforum.roblox.com/t/will-i-be-banned-if-i-allow-custom-textures/2198829)).
- **Not verified yet:** where AppleBlox writes its flags and mods on macOS. Writing into `Roblox.app` would break its code signature seal, so how AppleBlox handles that (and what Roblox does with a broken seal) has to be checked before we write anything there.

**What that means for "unlimited FPS":** on Lao's Air the ceiling is 60 FPS whatever we do. On a 120–240 Hz external screen, Roblox's own setting already covers it. The only routes past 240 are a flag Roblox now ignores, or a memory patch that's a bannable modified client. **We won't ship a memory patch.**

**What that means for "cache editing":** possible the Bloxstrap way (replace content files, re-apply after updates), cosmetic and performance-only (e.g. lighter textures, no advantage textures), with a ban warning.

### Minecraft
- **Lunar Client** (and Badlion and Feather) are closed clients that bundle their own mods and FPS tweaks. Lunar runs on Apple silicon (Homebrew cask 3.7.x, macOS 13+) ([Homebrew](https://formulae.brew.sh/cask/lunar-client), [Lunar FAQ](https://www.lunarclient.com/faq)). Building a client like that means maintaining our own mod stack for every Minecraft version.
- **Signing in is the blocker for our own launcher.** A new Azure app has to apply to Mojang for permission to use the Minecraft API; without it, `api.minecraftservices.com` answers 403 ([Minecraft Wiki](https://minecraft.wiki/w/Minecraft_Wiki:Projects/wiki.vg_merge/Microsoft_Authentication_Scheme), [minecraft-launcher-lib](https://minecraft-launcher-lib.readthedocs.io/en/latest/tutorial/microsoft_login.html)). People were still asking how in Feb 2026 ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5768276/how-to-get-xboxlive-signin-permission-for-azure-ap)); approval for small projects isn't guaranteed.
- **The speed gain is in the mods, not the launcher:** Sodium/Lithium/FerriteCore (or Embeddium/Canary on Forge) are what Lunar-style clients and packs like Fabulously Optimized ship. `macx games minecraft` already finds what's missing.

## Recommendation
Build both into Macximesed's Games (Play), not as separate apps, and leave signing in to the launchers that already have permission:

**Roblox (Play Roblox):**
1. Boost and the While-playing hooks on launch (already there), and close-on-leave.
2. **Frame rate:** set Roblox's own *Maximum Framerate* to your screen's refresh rate (to verify: where Roblox stores it on the Mac, and that editing that settings file is safe). Say plainly that 60 Hz screens top out at 60.
3. **FastFlags:** only flags on Roblox's current allowlist (read from Roblox, so it follows their changes), with presets for performance (e.g. lower graphics). No hidden flags, no memory patching.
4. **Mods ("cache editing"):** a mods folder copied over the client's content files after each update, Bloxstrap-style, for cosmetic and performance files only, with a ban warning shown before it's switched on. Only after verifying how this works on the Mac without breaking the app's signature.
5. Discord Rich Presence: later, optional.

**Minecraft (Play Minecraft):**
1. Launch a Prism Launcher or Modrinth App instance from macx (to verify: Prism's `--launch INSTANCE` option, Modrinth's equivalent), with Boost and the hooks. They keep doing the signing in.
2. **One-click speed mods:** with the user's OK per instance, download the right Sodium/Lithium/FerriteCore (or Embeddium/Canary) from Modrinth's API for that Minecraft version and loader, into the instance's mods folder, with an undo.
3. **Memory:** offer to set the instance's memory from the check's rule (Prism's `instance.cfg`; Modrinth's one setting), with an undo.
4. Measure FPS with the Metal HUD before and after, per instance.

## Not doing
- Memory-patching FPS unlockers, or anything that changes Roblox's binary or running process (bannable).
- Advantage textures (see-through walls, ESP).
- Our own Microsoft sign-in, or a cracked/offline Minecraft.

## To verify before building
- Where Roblox keeps its settings, flags and content on the Mac; what AppleBlox writes, and whether that breaks the app's signature.
- How to read Roblox's current FastFlag allowlist.
- Prism's and the Modrinth App's command-line launch.
- Modrinth's API for finding a mod version by Minecraft version and loader.
