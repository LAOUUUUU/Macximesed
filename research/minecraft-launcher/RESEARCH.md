# Research: Macximesed's own Minecraft launcher

Asked by Lao on 2026-11-25: "we make our own launcher that doesn't start Prism or the Minecraft launcher or Modrinth, we gotta make our own, and add like suggest Java edition for this Mac". Replaces the "launch Prism/Modrinth" recommendation in [research/game-launchers/RESEARCH.md](../game-launchers/RESEARCH.md). Nothing built yet: needs Lao's OK, and one step only Lao can do (below).

## Findings (checked 2026-11-25)

### Signing in: needs Mojang's permission, which only Lao can apply for
- Minecraft Java uses a Microsoft account → Xbox Live → XSTS → `login_with_xbox` on `api.minecraftservices.com`. The Azure app has to be registered for **personal Microsoft accounts only** ([minecraft-launcher-lib](https://minecraft-launcher-lib.readthedocs.io/en/latest/tutorial/microsoft_login.html), [Minecraft Wiki](https://minecraft.wiki/w/Minecraft_Wiki:Projects/wiki.vg_merge/Microsoft_Authentication_Scheme)).
- **A new app gets 403 until Mojang adds it to their allow list.** Mojang reviews API integration requests by hand ([Mojang help](https://help-redesign.zendesk.com/hc/en-us/articles/38994884924941-Java-Edition-Game-Service-API-Review-or-Application-Process)). No published timeline; a non-commercial hobby launcher asked in Feb 2026 whether individuals get approved, with no answer ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5768276/how-to-get-xboxlive-signin-permission-for-azure-ap)); another developer did get accepted ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/1416915/how-to-get-azure-ad-xbox-live-api-access)).
- Using another launcher's app ID (Prism's, Modrinth's) to get around this is not an option: it's their registration, not ours.
- **So:** Lao registers the Azure app and sends Mojang's review form. Everything else can be built while that's pending; signing in works the day it's approved.

### Java for this Mac ("suggest Java edition")
Mojang's own runtime list (`piston-meta…/java-runtime/…/all.json`, read 2026-11-25), `mac-os-arm64`:
| Component | Java | Native on Apple silicon |
|---|---|---|
| java-runtime-epsilon | 25.0.5.1 (2026-11-18) | yes |
| java-runtime-delta | 21.0.7 | yes |
| java-runtime-gamma | 17.0.15 | yes |
| java-runtime-alpha / beta (Java 16) | none | **no** |
| jre-legacy (Java 8) | none | **no** |

Each version's JSON names the component it wants (`javaVersion.component`) ([minecraft-kit](https://loontail.github.io/minecraft-kit/guides/runtime)). So for 1.17+ the launcher downloads Mojang's own arm64 Java. For older versions there's no Mojang arm64 Java: use an arm64 build of Java 8/16 from another vendor (Azul Zulu has them; to confirm its API).

### Graphics libraries on Apple silicon
- Native Apple-silicon support arrived in **1.19** ([AppleInsider](https://appleinsider.com/articles/22/06/08/minecraft-java-edition-gets-native-apple-silicon-support)). 1.13–1.18 use LWJGL 3 and run natively if the launcher swaps in LWJGL 3.3.0/3.3.1 arm64 natives ([m1craft](https://www.github.com/ezfe/m1craft)). Before 1.13 (LWJGL 2) needs separately built arm64 natives ([ManyMC](https://github.com/MinecraftMachina/ManyMC), [m1-multimc-hack](https://github.com/ankleBowl/m1-multimc-hack-1.8)). Without native libraries, the game runs through Rosetta whatever Java is used ([Forge issue](https://www.github.com/MinecraftForge/MinecraftForge/issues/7558)).

### Versions, mods
- Version list: `piston-meta.mojang.com/mc/game/version_manifest_v2.json` (read 2026-11-25). Each version's JSON lists libraries, natives, assets and launch arguments.
- Mod loaders: Fabric publishes ready launch profiles through its meta API (simplest). Forge/NeoForge need their installer's processors (harder; later).
- Mods: Modrinth's API, by Minecraft version and loader.

## Recommendation: build order
1. **Java for this Mac:** `macx games java` lists each Minecraft version family with the best Java: Mojang's arm64 runtime for 1.17+, a third-party arm64 Java 8/16 for older versions, and a warning when a version would run through Rosetta. Downloads into `~/Library/Application Support/Macximesed/minecraft/runtime`, checked against Mojang's hashes. Useful on its own, even before the launcher (can suggest it for Prism/Modrinth instances too).
2. **Game files:** versions, libraries (with arm64 LWJGL for 1.13–1.18), assets; all hash-checked. Instances in `…/Macximesed/minecraft/instances/NAME`.
3. **Sign in** (once Mojang approves the app): device-code sign-in in the app; the refresh token in the Keychain, never in files.
4. **Launch:** builds the command line from the version JSON, with Boost, the While-playing hooks, memory from the check's rule, and the Metal HUD option. Owners only: no sign-in, no launch.
5. **Fabric** profiles, then **one-click speed mods** from Modrinth (Sodium, Lithium, FerriteCore, ImmediatelyFast), then Forge/NeoForge.
6. **The app:** a Minecraft page with instances, versions, mods, memory and Java.

## Lao's step
1. Register an app at portal.azure.com (App registrations → New → "Personal Microsoft accounts only", public client, redirect for device code).
2. Send Mojang's Java Edition API review form with that app ID ([Mojang help](https://help-redesign.zendesk.com/hc/en-us/articles/38994884924941-Java-Edition-Game-Service-API-Review-or-Application-Process)).
3. The app ID (a public client ID, not a secret) goes into the code.

## Not doing
- Playing without a Microsoft account that owns the game (no offline or cracked accounts), and borrowing another launcher's app ID.
- Our own Lunar-style client mods: the speed comes from Sodium/Lithium/FerriteCore, which we install, not rewrite.
