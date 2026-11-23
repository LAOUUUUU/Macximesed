#!/usr/bin/env python3
"""Miss rate of macx's network polling for short connections.

Starts a TCP server on 127.0.0.1 and a client process that opens N connections for each hold time
(connect, wait, close), while `macx net PID --every --loopback` watches the client. A connection
counts as seen if macx printed its local port. No root, no network: everything stays on this Mac.

Usage: python3 -I scripts/eval/network.py [path/to/macx] [interval_ms ...]
"""
import os, re, socket, subprocess, sys, threading, time

MACX = sys.argv[1] if len(sys.argv) > 1 else ".build/debug/macx"
INTERVALS = [int(x) for x in sys.argv[2:]] or [100, 20]
HOLDS_MS = [0, 5, 20, 50, 100, 200, 500]
N = 20
GAP_MS = 30

CLIENT = r'''
import socket, sys, time
port = int(sys.argv[1]); holds = [int(x) for x in sys.argv[2].split(",")]; n = int(sys.argv[3]); gap = int(sys.argv[4])
time.sleep(1.0)  # let macx start watching
for h in holds:
    for _ in range(n):
        s = socket.create_connection(("127.0.0.1", port))
        print(h, s.getsockname()[1], flush=True)
        time.sleep(h / 1000)
        s.close()
        time.sleep(gap / 1000)
'''

def serve(srv):
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=lambda c=c: (c.recv(1), c.close()), daemon=True).start()

def run(interval):
    srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(64)
    port = srv.getsockname()[1]
    threading.Thread(target=serve, args=(srv,), daemon=True).start()
    client = subprocess.Popen([sys.executable, "-I", "-c", CLIENT, str(port), ",".join(map(str, HOLDS_MS)), str(N), str(GAP_MS)],
                              stdout=subprocess.PIPE, text=True)
    watcher = subprocess.Popen([MACX, "net", str(client.pid), "--every", "--loopback", "--interval", str(interval)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env={**os.environ, "MACX_NO_UPDATE_CHECK": "1"})
    made = [tuple(map(int, l.split())) for l in client.stdout]
    client.wait()
    out = watcher.communicate(timeout=10)[0]
    srv.close()
    seen = {int(m) for m in re.findall(rf"127\.0\.0\.1:{port}\b.*local port (\d+)", out)}
    print(f"\nInterval {interval} ms ({N} connections per hold time):")
    print("  hold ms   seen   miss rate")
    for h in HOLDS_MS:
        ports = [p for hh, p in made if hh == h]
        got = sum(p in seen for p in ports)
        print(f"  {h:>7}   {got:>2}/{len(ports)}   {100 * (len(ports) - got) / len(ports):5.0f}%")
    if not made:
        print("  client made no connections:", out[:300])

for i in INTERVALS:
    run(i)
