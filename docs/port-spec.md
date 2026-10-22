# OBS Study Panel — Port Specification (Behavior Contract)

`OBS.sh` is the **reference implementation**. This document is the behavior
contract that every language port must satisfy. Where a port genuinely cannot
match a behavior (missing OS API), the difference must be listed in
`docs/language-notes.md` — never silently changed.

---

## 1. Command line

```
Usage: <basename> [options] <rounds> <study_minutes> <break_minutes>
```

`<basename>` is the basename of the invoked program (`argv[0]`), exactly like
`basename "$0"` in the reference.

### 1.1 Option parsing

Options are parsed **left to right and only until the first positional
argument**. After the first non-option argument, everything that remains is
treated as positional.

| Argument             | Behavior                                                              |
|----------------------|-----------------------------------------------------------------------|
| `-h`, `--help`       | Print help to **stdout**, exit **0**                                   |
| `-c`, `--config FILE`| `FILE` becomes the config file. Missing argument → `Error: <opt> needs a file argument` to stderr + usage error |
| `-d`, `--dry-run`    | Durations become **seconds** instead of minutes                       |
| `-n`, `--no-alert`   | Disable the audio alert                                                |
| `-s`, `--no-sink`    | Don't create or use the OBS virtual audio sink                         |
| `-t`, `--theme NAME` | Set the color theme. Missing argument → `Error: <opt> needs a theme name` + usage error |
| `--list-themes`      | Print the theme list, exit **0** (works regardless of other arguments) |
| `--`                 | End of options; the rest is positional                                 |
| any other `-x...`    | `Error: unknown option: <arg>` to stderr + usage error                  |
| first non-option     | Positional arguments start; parsing stops                              |

Usage errors print the **full help text to stderr** and exit **1**.

### 1.2 Positional arguments

Exactly 3 are required: `<rounds> <study_minutes> <break_minutes>`.
- Any other count → usage error (exit 1).
- Each must match the regex `^[1-9][0-9]{0,3}$` (positive, no leading zero,
  at most 4 digits). Anything else → usage error (exit 1).
- Range caps, each printing its own message to stderr + usage error:
  - rounds > 50 → `Error: rounds must be <= 50`
  - study > 600 → `Error: study minutes must be <= 600`
  - break > 120 → `Error: break minutes must be <= 120`

### 1.3 Help text (exact)

```
Usage: <basename> [options] <rounds> <study_minutes> <break_minutes>

Runs a Pomodoro-style study/break loop and writes the live state to text
files that OBS Studio can display as "Text (read from file)" sources.

Options:
  -h, --help          Show this help and exit
  -c, --config FILE   Load settings from FILE (bash syntax)
  -d, --dry-run       Treat the durations as seconds (fast testing)
  -n, --no-alert      Disable the audio alert
  -s, --no-sink       Don't create or use the OBS virtual audio sink
  -t, --theme NAME    Use a color theme (see --list-themes)
      --list-themes   Show the available color themes and exit

Arguments:
  rounds             1-50   number of study rounds
  study_minutes      1-600  length of a study phase
  break_minutes      1-120  length of a break phase

Examples:
  <basename> 5 50 10           # 5 rounds, 50 min study, 10 min break
  <basename> --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  <basename> --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
```

## 2. Color themes

12 themes, each `(name, primary, secondary)` — primary for study phase /
headings / points, secondary for break phase / boxes:

| idx | Name    | Primary    | Secondary  |
|-----|---------|------------|------------|
| 0   | Purple  | `\e[1;35m` | `\e[0;35m` |
| 1   | Ocean   | `\e[1;36m` | `\e[0;34m` |
| 2   | Forest  | `\e[1;32m` | `\e[0;32m` |
| 3   | Sunset  | `\e[1;33m` | `\e[0;31m` |
| 4   | Rose    | `\e[1;95m` | `\e[0;31m` |
| 5   | Gold    | `\e[1;93m` | `\e[0;33m` |
| 6   | Mono    | `\e[1;37m` | `\e[0;37m` |
| 7   | Ice     | `\e[1;96m` | `\e[0;36m` |
| 8   | Ember   | `\e[1;91m` | `\e[0;31m` |
| 9   | Neon    | `\e[1;92m` | `\e[0;96m` |
| 10  | Cobalt  | `\e[1;34m` | `\e[0;36m` |
| 11  | Cherry  | `\e[1;91m` | `\e[0;35m` |

Other constants: `BOLD=\e[1m`, `DIM=\e[2m`, `NC=\e[0m`.

- `--list-themes` output, one line per theme (in index order):
  `  ` + name padded to 8 columns (`%-8s`) + primary + `████` + secondary + `\n`.
  No color reset after the swatch (reference behavior).
- Theme lookup by name is case-insensitive.
- Selection priority: `--theme NAME` > `$THEME` env > config `THEME` >
  first line of `theme.txt` in the state dir > default `Purple`.
- Unknown theme → stderr: `Warning: unknown theme '<name>', using Purple`
  (the warning names the current default theme), then continue normally.
- `Alt+T` while a phase runs: cycle to the next theme (wrapping), write the
  theme name to `theme.txt` (best effort), show `Theme: <name>` in the status
  line for 3 seconds, log `Theme changed to: <name>`.

## 3. Configuration precedence

Lowest to highest: **built-in default < config file < environment < CLI**.
Environment variables are captured **before** defaults are applied so they
survive the config file.

### 3.1 Built-in defaults

| Knob                    | Default                                   |
|-------------------------|-------------------------------------------|
| `ALERT_SOUND`           | `$HOME/Videos/Alarm/n_alarm.mp3` (`""` if `$HOME` unset) |
| `SINK_NAME`             | `OBS_Alert_Sink`                          |
| `STATE_DIR`             | `""` → the directory holding the program  |
| `MAX_LOG_BYTES`         | `1048576`                                 |
| `FILE_BAR_WIDTH`        | `20`                                      |
| `NON_TTY_ENTER_TIMEOUT` | `300`                                     |
| `POINTS`                | `0`                                       |
| `QUOTE_LIST`            | the 5 quotes below                        |
| `THEME`                 | unset                                     |

Default quote list (also used when the configured list is empty → subtitle
`Stay focused.`):

```
Focused effort beats scattered hours
Every round finished is progress made
Consistency beats intensity
Start now, figure out the rest along the way
A short break now means sharper focus next round
```

### 3.2 Config file lookup (first existing wins)

1. `--config FILE` — **always used**, even if missing: missing/unreadable →
   stderr `Error: config file is not readable: <file>`, exit 1.
2. `$OBS_PANEL_CONFIG`
3. `${XDG_CONFIG_HOME:-$HOME/.config}/obs-study-panel/config` if it exists
4. `obs-panel.conf` next to the program, if it exists

### 3.3 Loading the config file

The config file is **bash source code** in the reference. Ports must
replicate its observable effect with a child bash process (all ports require
bash on the host, like the reference itself):

1. Syntax gate: run `bash -n <file>`; on failure print to stderr
   `Error: syntax error in config file: <file>` followed by the first 3 lines
   of `bash -n` output, exit 1.
2. Extraction: run bash with the current **default** knob values seeded into
   the environment (STATE_DIR="" etc. — exactly what the reference holds when
   it sources the file; the real environment's `THEME`/`QUOTES` pass through
   unchanged), then `source` the file, then dump the post-source values of
   `ALERT_SOUND, SINK_NAME, STATE_DIR, MAX_LOG_BYTES, FILE_BAR_WIDTH,
   NON_TTY_ENTER_TIMEOUT, THEME, POINTS, LAST_DATE, QUOTES, QUOTE_LIST[]`
   to a temp file using unit/record separators (`\037`, `\036`).
   The child's stdout/stderr are inherited so config `echo` output behaves
   like the reference. The child's exit status is deliberately ignored (a
   config whose last command fails is valid) — **except** when the dump was
   never written (the config called `exit N`): then the port exits with N.
3. Environment variables beat the config file: re-apply `ALERT_SOUND`,
   `SINK_NAME`, `STATE_DIR`, `MAX_LOG_BYTES` from the captured environment
   after loading.
4. Quotes: if `$QUOTES` env is non-empty → parse it (newline separated,
   strip `\r`, skip empty lines); elif config `QUOTES` is non-empty → parse
   it; else use `QUOTE_LIST` from the config (possibly the seeded defaults).
5. Knob sanity (applied after everything): `MAX_LOG_BYTES` numeric > 0
   else `1048576`; `FILE_BAR_WIDTH` numeric 1..200 else `20`;
   `NON_TTY_ENTER_TIMEOUT` numeric 1..3600 else `300`.
6. If a config was loaded, remember the path: the startup screen prints the
   dim line `Config: <path>`.

## 4. State files

`STATE_DIR` is created with `mkdir -p` (missing → stderr
`Error: cannot create state dir: <dir>`, exit 1). All files live there:

`date.txt day.txt session.txt timer.txt log.txt progress.txt points.txt
message.txt next.txt overlay.txt theme.txt`

### 4.1 Every tick (`publish_state`)

- `session.txt` ← session text
- `timer.txt` ← remaining `HH:MM:SS`
- `points.txt` ← points (integer)
- `next.txt` ← next text
- `message.txt` ← message text
- progress bar: `filled = pct * FILE_BAR_WIDTH / 100`, chars `#`/`-`:
  `progress.txt` ← `[<bar>] <pct with %3d>%` + `\n` (e.g. `[##########----------]  50%`)
- `overlay.txt` ← the following lines, in order:
  1. `<YYYY-MM-DD> <Weekday>`
  2. session text
  3. remaining time
  4. `[<bar>] <pct>%` (same as progress.txt)
  5. `Pts: <points>`
  6. `Next: <next text>`
  7. message text — **only when non-empty**

### 4.2 Date rollover

`update_date_day` runs on every tick but only writes when the local date
changes: `date.txt` ← `YYYY-MM-DD`, `day.txt` ← full weekday name (e.g.
`Tuesday`), both with trailing newline. Local timezone.

### 4.3 Log

`log.txt` gets one line per event: `[YYYY-MM-DD HH:MM:SS] <message>`.
Before each write, if `log.txt` exists and its size >= `MAX_LOG_BYTES`,
it is moved to `log.txt.1` (replacing any previous) and a fresh `log.txt`
is started. Rotation failures are ignored.

### 4.4 Lifecycle states written into the files

- Startup of each phase: session `STUDY 2/5` or `BREAK 2/5`
- While paused: `STUDY 2/5 (PAUSED)`
- Phase end, skipped: `STUDY 2/5 (SKIPPED)` (point NOT earned)
- Phase end, finished: points + 1, `timer.txt` `00:00:00`, progress 100%
- Quit / Ctrl+C / SIGTERM / SIGHUP / unexpected death:
  session `stopped`, timer `00:00:00`, progress `[<empty bar>]   0%`,
  next empty — the stream must never show a frozen timer.
- Normal completion: session `session complete`, progress 100%.

## 5. Session flow

1. Print the logo (see §7.1).
2. Set up the audio sink if enabled (§6).
3. Publish date/day; state is now "ready" (unexpected exit must reset it).
4. Log `Starting new study protocol: <R rounds>, <X minutes> study, <Y minutes> break`
   (`1 round`, `1 minute`, `1 second` singular forms; `--dry-run` says
   `seconds`).
5. Print the protocol summary line + optional `Config: <path>` (§7.2).
6. For round = 1..rounds:
   - run a **study** phase of `study_minutes`
   - if round < rounds: run a **break** phase of `break_minutes`
7. Finalize: session `session complete`, timer `00:00:00`, progress 100%,
   next empty. Log `Protocol complete - total points: <points>`.
8. Print the final banner (§7.5) and exit 0.

### 5.1 Phase state machine

A phase has: label (`STUDY`/`BREAK`), subtitle, next text, total seconds,
elapsed, paused flag, skipped flag, start wall-second, accumulated pause
seconds, pause start second.

- `prepare`: label + subtitle (study: random quote from the list, or
  `Stay focused.` for an empty list; break: `Relax and recharge.`),
  next text (`Break (<dur>)` / `None` when it is the last study phase /
  `Study (<dur>)`), total = `minutes * seconds_per_unit` (60, or 1 in
  `--dry-run`), initial remaining string, pct 0, session text, message text;
  log `Start: <LABEL> <round>/<total> (<dur>)`; print the phase header (§7.3);
  publish state.
- `count` loop, while elapsed < total:
  - remaining string from `total - elapsed` (never negative)
  - pct = `elapsed * 100 / total`, capped at 100
  - session text `LABEL r/n`, + ` (PAUSED)` while paused
  - publish state; redraw the status line (§7.4)
  - wait up to 1 second for a key (§6.4):
    - `p` / `P` / space: toggle pause. Pausing stores the current
      wall-second; resuming **adds** `now - pause_start` to the accumulated
      pause seconds (multiple pauses all count). Log `Paused:` / `Resumed:`
      with the phase and round.
    - `s` / `S`: mark skipped, log `Skipped: <LABEL> r/n`, end the phase.
    - `q` / `Q`: log `Quit requested by user`, then run the interrupt
      cleanup (reset files to `stopped`, log `Protocol stopped manually`,
      print `Interrupted.` banner) and **exit 0**.
    - `Alt+T` (ESC then `t`/`T` within 0.3 s): cycle theme.
    - other keys: ignored. ESC sequences other than Alt+T are swallowed.
  - when not paused: elapsed = wall-seconds since phase start minus
    accumulated pause seconds (wall-clock math, not loop counting).
- `finish`:
  - skipped → session text gets ` (SKIPPED)`; otherwise pct=100, points += 1.
  - remaining `00:00:00`; publish; final status redraw; newline.
  - log `End: <LABEL> <round>/<total>`.
  - play the alert (§6.2).
  - drain pending typed input (TTY only) so a stray Enter cannot skip the
    prompt.
  - print the completion card (§7.4 end) with `Press Enter to continue...`
  - wait for Enter (§6.5); stop the alert; newline.

`duration_label(n)`: `1 minute` / `1 second` (dry-run) singular, otherwise
`<n> minutes` / `<n> seconds`. `rounds_label(n)`: `1 round` / `<n> rounds`.

## 6. Platform integration

### 6.1 Audio sink (PulseAudio)

- `sink_is_ready`: `pactl` exists and `pactl list short sinks` contains a line
  whose second field equals `SINK_NAME`.
- On startup (if sink enabled): if `pactl` exists and the sink is missing,
  run `pactl load-module module-null-sink sink_name=<SINK_NAME>
  sink_properties=device.description=<SINK_NAME>` ignoring all errors.
- Missing `pactl` is not an error anywhere; everything degrades gracefully.

### 6.2 Alert player priority

`mpv --no-video --volume=70` > `paplay` > `ffplay -nodisp -autoexit` >
`cvlc --play-and-exit --no-video --volume=70`. If none exists, print the dim
line `(no audio player found - install mpv / paplay / ffplay)` and return.
If `ALERT_SOUND` is empty or missing, print the dim line
`(alert file not found: <path or none>)` and return. Before spawning, the
previous player is killed (never two overlapping alarms). If the sink is
enabled but missing, try to recreate it once. If the sink is (now) ready,
spawn the player with environment `PULSE_SINK=<SINK_NAME>` and print the dim
line `-> alert on OBS sink (<SINK_NAME>)`; otherwise print the secondary
line `-> alert on default device (OBS sink unavailable)`. The player runs
detached; its PID is remembered so it can be stopped when the user
acknowledges the phase.

### 6.3 Signals and unexpected death

- SIGINT → cleanup, exit code **130**. SIGTERM → **143**. SIGHUP → **129**.
- Cleanup: stop the alert, reset the files to `stopped`/`00:00:00`,
  log `Protocol stopped manually`, print (best effort)
  `\n` + secondary+bold `Interrupted.` + dim `State files reset to stopped.`
  + `\n`, exit with the code. Repeated signals are ignored during cleanup.
- Unexpected death (uncaught error/exception after state became ready, exit
  code preserved): stop the alert, reset the files, log
  `Protocol ended unexpectedly (exit <code>)`.
- Normal completion path does not reset (files already finalized).

### 6.4 Key input

- Detect TTY on **stdin** (`isatty(0)`).
- Non-TTY: waiting for a key is just a sleep of the given timeout; typed
  input is not consumed here.
- TTY: switch stdin to no-echo character mode for the whole session
  (save/restore the original terminal settings, including on exit). Read
  one key at a time with a timeout. ESC starts an escape sequence; only
  `ESC t` / `ESC T` becomes `Alt+T`, the rest is swallowed. The follow-up
  read after ESC has a 0.3 s timeout.
- Draining pending input (TTY only, before the Enter prompt): read and
  discard whatever is buffered with a very short timeout.

### 6.5 Waiting for Enter

- TTY: read with a 1 s timeout in a loop; Enter (or EOF) returns; every
  timeout re-checks the date so midnight rollover still updates date.txt.
- Non-TTY: read with a 5 s timeout in a loop; a complete line or EOF
  returns; after `NON_TTY_ENTER_TIMEOUT` seconds total, give up and return
  (a never-closing silent pipe must not hang the session). Partial lines
  are not lost between slices.

## 7. Terminal UI (exact strings)

### 7.1 Logo

```
<PRIMARY>
 /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/
<NC>
<PRIMARY><BOLD>     Study / Break Timer Protocol<NC>
<DIM>── live state written to date · day · session · timer · log<NC>
<blank>
```

### 7.2 Protocol summary line

```
<SECONDARY>Protocol:<NC> <BOLD><rounds label><NC>  <DIM>|<NC>  <BOLD><study dur><NC> study  <DIM>|<NC>  <BOLD><break dur><NC> break  <DIM>|<NC>  <BOLD>Theme: <name><NC>
<DIM>Config: <path><NC>            (only when a config was loaded)
<blank>
```

### 7.3 Phase header

Box width 62 inner. Top `<color>╔` + 62×`═` + `╗<NC>`, then three `║` rows
(padded to 62 visible columns; padding computed from the *visible* text,
not the escape codes):
1. `  <BOLD><LABEL><NC><color>  ·  Round <r> / <n>  ·  <dur>`
2. `  <DIM><subtitle><NC><color>` (subtitle truncated to 58 chars)
3. keys row, TTY only: `  <DIM>  p pause  ·  s skip  ·  q quit  ·  Alt+T theme<NC><color>`
Bottom `<color>╚` + 62×`═` + `╝<NC>`, then a blank line. `STUDY` uses the
primary color, `BREAK` the secondary.

### 7.4 Status line

Single line redrawn every tick: `\r\033[K` then

```
<BOLD><color><LABEL padded to 6><NC> [<r>/<n>] <color>[<term bar>]<NC> <pct %3d>%  <remaining>  <PRIMARY>Pts:<points><NC><flags>
```

Terminal bar: 24 chars wide, filled = `elapsed * 24 / total` (capped),
fill `=`, head `>` on the last filled cell, rest spaces. Flags: when paused
`<PRIMARY> PAUSED<NC>`; within 3 s of a theme change additionally
`  <DIM>Theme: <name><NC>`.

Completion card (after the phase):

```
<blank>
<color><60 '='><NC>
<color><centered title><NC>          width 60: (60 + len(title)) / 2
<color><60 '='><NC>
<blank>
  Round:   <BOLD><r><NC> / <n>
  Points:  <PRIMARY><points><NC>
<blank>
  Next:    <BOLD><next text><NC>            (or <DIM>Session complete<NC> when none)
<blank>
  <PRIMARY>Press Enter to continue...<NC>   (no newline)
```

Title: `STUDY SESSION COMPLETE` / `BREAK COMPLETE` / `PHASE SKIPPED`.

### 7.5 Final banner

```
<blank>
<PRIMARY><60 '#'><NC>
<PRIMARY>#<NC><pad><BOLD>ALL SESSIONS COMPLETE<NC><pad>#<PRIMARY>
<PRIMARY><60 '#'><NC>
<blank>
  <BOLD>Total Rounds:<NC>  <PRIMARY><rounds><NC>
  <BOLD>Total Points:<NC> <PRIMARY><points><NC>
<blank>
<PRIMARY><BOLD>Great work!<NC> <DIM>Exiting.<NC>
```

Inner width 58, left pad = `(58 - 21) / 2` (title is 21 visible chars
incl. two spaces), right pad = `58 - pad - 21`.

## 8. Timing rules

- `SECONDS` = integer wall-clock seconds since program start.
- Phase countdown uses wall-clock math: `elapsed = now - start - paused_total`.
- Theme notice window: 3 s. Alert and sink setup are fire-and-forget.
- `--dry-run` only changes `seconds_per_unit` (1 instead of 60) and the unit
  labels; everything else behaves identically.

## 9. Testing contract

`tests/test-port.sh` runs, for every port (see `tests/ports.tsv`):

1. `--help` exit 0 + `Usage:` on stdout.
2. 13 argument-validation failures → exit 1 (no args, wrong count, `abc`,
   `0`, `-1`, `50.5`, `05`, `99999`, caps, unknown option, `--config` w/o
   arg, `--theme` w/o arg is covered by unit tests where applicable).
3. Full dry-run session (2 rounds × 2 s study / 1 s break, piped Enters):
   exit 0; `session.txt` = `session complete`; `timer.txt` = `00:00:00`;
   `points.txt` = `3`; `progress.txt` = `[####################] 100%`;
   `date.txt`/`day.txt` = today; log has `Start: STUDY 1/2`,
   `Start: BREAK 1/2`, `End: STUDY 2/2`,
   `Protocol complete - total points: 3`; overlay contains session, `Pts: 3`,
   the date.
4. Single round → 1 point, no `Start: BREAK` in log.
5. Config file: STATE_DIR honored, quote honored, `Config: <path>` reported,
   env beats config, QUOTES env honored, empty quote list → `Stay focused.`,
   failing last command still loads, syntax error → exit 1 + message.
6. Themes: `--list-themes` exit 0 with >= 10 lines; `--theme Ocean`,
   `THEME=Forest` env, CLI beats env, config theme, saved `theme.txt`
   restored, unknown theme → warning + exit 0 + default.
7. Log rotation with `MAX_LOG_BYTES=1` → `log.txt.1` exists.
8. pty (interactive, util-linux `script`): pause/resume logged + still
   scores, multi-pause freeze sampling (no countdown jumps > 3 s), skip
   (no point, `Skipped:` logged), quit (exit 0, `stopped` files, `Quit
   requested by user`), Alt+T (logged, saved, shown), SIGINT via pty →
   exit 130 + reset + `Protocol stopped manually`.
9. SIGTERM directly → exit 143 + reset + logged.
10. Unexpected death: a sed-injected crash (exit 42) at the tick loop
    marker → exit code preserved, files reset, `Protocol ended unexpectedly`
    logged. (Per-language crash mechanism, see `docs/language-notes.md`.)
11. Non-interactive bounded wait: silent FIFO input with
    `NON_TTY_ENTER_TIMEOUT=5` → completes in <= 20 s, exit 0.

All ports must pass every applicable check; exclusions must be justified in
`docs/language-notes.md`.
