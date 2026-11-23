# Network watching: miss rate for short connections

**What was measured:** how often `macx net` (and so the network part of `macx watch`) sees a connection, by how long the connection stays open.

**How:** `python3 -I scripts/eval/network.py .build/release/macx 100 20`
- A TCP server on 127.0.0.1, and a client process that opens 20 connections for each hold time (connect, wait, close, 30 ms gap).
- `macx net PID --every --loopback` watches the client. A connection counts as seen if macx printed its local port.
- Run on 2026-11-23, macOS 27.0.1, Apple M3, release build. Nothing leaves the Mac.

## Results

| Held open | Seen at 100 ms | Seen at 20 ms |
|---|---|---|
| 0 ms (connect, close) | 1/20 | 0/20 |
| 5 ms | 5/20 | 15/20 |
| 20 ms | 12/20 | 16/20 |
| 50 ms | 15/20 | 20/20 |
| 100 ms | 16/20 | 20/20 |
| 200 ms | 20/20 | 20/20 |
| 500 ms | 20/20 | 20/20 |

The chance of seeing a connection is roughly *time held open ÷ interval*, capped at 100%.

**Cost:** watching one process for 10 s used 0.02 s CPU at 100 ms and 0.03 s at 20 ms (about 0.3%). An earlier version that read the whole process table on every look used 4% and 7.5%; it now asks the kernel for each watched process's children only.

**Default:** 20 ms, for both `macx watch --net-interval` and `macx net --interval`.

## What this means
- Uploads of stolen data (a zip of browser data and keychains sent with curl) stay open for hundreds of milliseconds or more, and are seen.
- A single tiny request that connects and closes within a few milliseconds is usually missed. Polling can't fix that. Seeing every connection needs a Network Extension content filter, which needs Apple's entitlement.
- Only processes behind a high or critical alert (and what they start) are watched, for 5 minutes. Other programs' connections aren't looked at.
