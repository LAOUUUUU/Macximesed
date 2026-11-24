# More of what eslogger sees: research brief

*2026-11-24. Status: approved by Lao and built; the real capture on Lao's Mac is still to do.*

## Question
The live watch subscribes to 5 of eslogger's 110 events (`exec`, `create`, `rename`, `deleteextattr`, `btm_launch_item_add`). Which others catch stealers and remote-control malware, without flooding the user with alerts?

## Sources
- Apple's Endpoint Security headers in the macOS 27.2 SDK (`usr/include/EndpointSecurity/ESMessage.h`, `ESTypes.h`): field names and enum values. eslogger's JSON follows these names (its man page), and the current parser was built the same way.
- `eslogger --list-events` on macOS 27.0.1: the 110 event names.

## What to add
Picked for being serious **and** rare. Events that fire thousands of times a minute (`open`, `get_task`, `mmap`, `authentication`, `setextattr`, `write`) stay out: `open` alone cost 88% CPU in the runtime eval.

| Event | What it means | Alert |
|---|---|---|
| `xp_malware_detected` | Apple's XProtect found malware (`malware_identifier`, `detected_path`) | **critical**: case recorded. Never freezes: the event's process is XProtect itself |
| `xp_malware_remediated` | XProtect tried to remove it (`success`, `remediated_path`) | high if it worked (you were still infected, check what it touched), **critical** if it failed |
| `tcc_modify` | A privacy permission changed (`service`, `identity`, `right`, `reason`) | Only Full Disk Access, Accessibility, Screen Recording, Input Monitoring and sending keystrokes, and only when access is *granted*: medium when you clicked it yourself; high when a program granted it without your click, or when the app getting it lives in a hidden or temp folder (the AMOS look) |
| `profile_add` | A configuration profile was installed (`display_name`, `organization`, `install_source`) | medium, pointing at `sudo macx persist` for what it can do; low when MDM installed it |
| `od_create_user` | A new user account | high |
| `od_group_add` to `admin` | An account was made an administrator | high when macOS's own Settings did it; **critical** (and frozen) when a third-party program did |
| `od_modify_password` | An account password changed | medium when macOS's own tools did it (you, in Settings), high otherwise |
| `od_delete_user` | An account was deleted | high |
| `gatekeeper_user_override` | You chose *Open Anyway* on something Gatekeeper blocked: the trick stealer installers walk people through | medium; **critical** if its SHA-256 is in the malware feed |
| `remote_thread_create` | A program started a thread inside another one (code injection) | **critical** and frozen for an unsigned program; high for a signed one (debuggers do this) |
| `screensharing_attach` | Someone connected to your screen (`source_address`) | high |
| `openssh_login` | An SSH login (`source_address`, `username`) | medium for a successful login; nothing for failures |

## Things to watch
- **False alarms:** every rule above starts at medium or lower when macOS's own tools did it on your click, and the event's process (XProtect, tccd, opendirectoryd) is never the one frozen.
- **Shapes not seen yet:** the JSON for these events comes from the header, not a real capture. After the first build, a short capture (`sudo eslogger tcc_modify profile_add …` while you flip one permission and reinstall the test profile) checks them. Until then every field is optional, as now.
- **`sha256` in `gatekeeper_user_override`** is 32 raw bytes in the header; the parser accepts hex text or a byte array.
- **Cost:** these events are rare (a few a day), so the subscription adds next to nothing.

## Next steps
1. Lao approves the alert levels.
2. Test first: fixtures in the header's layout for each event, including the not-frozen and macOS-did-it cases.
3. Build, add the events to `WatchRules.events`, update the README's event table.
4. The real capture on Lao's Mac.
