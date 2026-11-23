# Simulated attack scripts (harmless)

These imitate techniques from published macOS stealer write-ups (AMOS and similar ClickFix campaigns) so the
static evaluation can measure detection. They are **only read** by `macx guard inspect --no-run`, never run,
and even if run they do nothing harmful: uploads go to `127.0.0.1:1` (closed), passwords asked for are thrown away,
and no real files are copied. `PORT` is replaced with the local test server's port at run time.
