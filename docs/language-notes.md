# Language notes

Per-language notes for the ports. Every port implements
[`port-spec.md`](port-spec.md); this file records the toolchain used for
testing, language-specific decisions and any documented deviation from the
reference behavior. Ports are listed in the order they were added.

## Shared notes (all ports)

- **Config file**: the config keeps the reference's bash syntax. Ports run
  `bash -n` as the syntax gate (same error message and exit code) and
  interpret the file with a child bash seeded with the pre-config default
  knobs, exactly the state the reference holds when it sources the file
  (environment `THEME`/`QUOTES` pass through untouched). A config that
  `exit N`s terminates the child before the value dump is written, and the
  port exits with `N` - the same observable behavior as sourcing in-process.
  Commands in the config (e.g. `echo`, `false`) run with their stdout/stderr
  attached to the port's own stdout/stderr, like the reference.
- **Crash test marker**: every port contains a `# CRASH-INJECT-POINT`
  comment inside the tick loop. `tests/test-port.sh` replaces it with
  language-specific code that aborts the program unexpectedly, then checks
  that the exit code is preserved and the state files were reset.
- **Terminal settings**: ports switch stdin to no-echo character mode for
  the session and restore the original settings on every exit path. The
  reference restores per-`read` internally; the ports hold the mode for the
  session - same observable behavior.

## Python — `OBS.py`

- Toolchain: Python 3.12 (runs on 3.7+; no third-party packages).
- Keyboard input uses `termios`/`select` directly; timed reads distinguish
  timeout, keypress and EOF exactly like the reference's `read -t`.
- Signals are handled with the `signal` module; an unexpected exception
  (including an injected `SystemExit`) unwinds through the main guard,
  which resets the state files and logs `Protocol ended unexpectedly`
  before re-raising, preserving the exit code.
- Non-interactive `wait_for_enter` keeps partial lines across the 5-second
  slices (the reference drops a partial line into an unused variable when a
  slice times out; the port never loses typed input). Not observable in any
  test or normal use.
