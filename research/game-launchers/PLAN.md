# Plan: Macximesed game launchers for Minecraft and Roblox

**Status: to be researched.** Lao (2026-11-25): "make plans to make game launchers for minecraft and roblox, just put as to be research and don't do research". Nothing here has been checked yet; every point below is a question for the research step, which needs Lao's go first.

## Minecraft launcher
The idea: launch a Prism/Modrinth instance (or our own) with the Mac tuned for it, instead of only checking it (`macx games minecraft`).
- **Wrap or replace?** Launch the user's existing Prism/Modrinth instances (their command lines) with Boost and the While-playing hooks, or be a launcher ourselves (accounts, versions, mods, Java).
- **Microsoft sign-in:** what a third-party launcher needs to sign in legally (Azure app registration, the rules for launchers).
- **Java:** pick an arm64 Java per Minecraft version automatically; GC flags that help on Apple silicon (to be measured, not copied).
- **Memory:** set it from the pack size and the Mac's RAM (the check's rule), per instance.
- **Mods:** offer the speed mods per loader (Sodium/Lithium/FerriteCore, Embeddium/Canary on Forge) through Modrinth's API, with the user's OK per mod.
- **Measure:** FPS with the Metal HUD before and after, per instance.

## Roblox launcher
- **What's allowed:** Roblox's terms for third-party launchers and bootstrappers; which existing ones are tolerated and which got users banned.
- **What a launcher can do safely:** launch with Boost and the While-playing hooks, pick the frame-rate cap from the display's refresh rate through Roblox's own setting, never by injecting into or editing the client.
- **Updates:** how Roblox updates itself on the Mac, so a launcher doesn't break it.
- **Measure:** FPS with the Metal HUD before and after.

## Not doing (without research saying it's safe)
- Anything that touches Roblox's memory or files (ban risk), or a cracked/offline-account Minecraft.
