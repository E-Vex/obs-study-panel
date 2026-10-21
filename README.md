# obs-study-panel

Study/break timer protocol for study livestreams. A Bash script that runs a
Pomodoro-style study loop and writes its live state to text files, which you
can display in OBS Studio as Text sources.

## Requirements

- Linux with Bash 4.2+
- Optional, for audio alerts: `pactl` (PulseAudio / PipeWire-pulse) plus one
  player: `mpv`, `paplay`, `ffplay` or `cvlc` (first one found is used)

## Usage

```bash
./OBS.sh [options] <rounds> <study_minutes> <break_minutes>
```

Example: 5 rounds, 50 min study, 10 min break:

```bash
./OBS.sh 5 50 10
```

Limits: rounds 1-50, study 1-600 min, break 1-120 min (whole numbers only).

When a phase ends the script waits for you to press `Enter` before starting the
next one. Stop at any time with `Ctrl+C` (closing the terminal does the same):
the OBS files are reset to `stopped` / `00:00:00`. The same happens when the
script dies unexpectedly, so the stream never keeps showing a frozen timer.
Each finished phase earns a point, shown in the console when the session
completes.

### Options

| Option              | What it does                                          |
|---------------------|-------------------------------------------------------|
| `-h`, `--help`      | Show the help and exit                                |
| `-c`, `--config FILE` | Load settings from `FILE`                            |
| `-d`, `--dry-run`   | Read the durations as **seconds** instead of minutes   |
| `-n`, `--no-alert`  | Don't play the audio alert                             |
| `-s`, `--no-sink`   | Don't create or use the OBS virtual audio sink         |
| `-t`, `--theme NAME` | Use a color theme (see below)                        |
| `--list-themes`     | Show the available color themes and exit               |

`--dry-run` makes a whole session finish in seconds, which is handy for
checking a setup before a real stream:

```bash
./OBS.sh --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
```

### Keys

While a phase is running:

| Key       | What it does                                    |
|-----------|-------------------------------------------------|
| `p` / space | Pause and resume the current phase            |
| `s`       | Skip the rest of the current phase (no point)   |
| `q`       | Quit the session                                 |
| `Alt+T`   | Switch to the next color theme                   |

The countdown freezes while it is paused and resumes exactly where it stopped.
The status line and `session.txt` show that the timer is on hold.

## Color themes

The script has 12 color themes. Every theme is a pair of colors: a bright
accent for the study phase, headings and points, and a soft accent for the
break phase, boxes and borders.

```
Purple (default)   Ocean   Forest   Sunset   Rose   Gold
Mono               Ice     Ember    Neon     Cobalt Cherry
```

To see them with their real colors:

```bash
./OBS.sh --list-themes
```

Pick one for a single run:

```bash
./OBS.sh --theme Ocean 5 50 10
```

Or press `Alt+T` while a phase is running: the theme changes instantly, the
name shows up in the status line for a few seconds and the choice is written
to `theme.txt` in the state directory, so the next run starts with it.

The theme is chosen in this order (first one that is set wins):

```
--theme NAME  >  $THEME  >  config file  >  theme.txt  >  Purple
```

An unknown theme name is reported and the default theme is used.

## Configuration

Settings are read from four places, lowest priority first:

```
built-in default  <  config file  <  environment variable  <  command line
```

### Config file

The first file that exists is used:

1. the file given with `--config FILE` (always used, even when it is missing -
   that is reported as an error)
2. `$OBS_PANEL_CONFIG`
3. `$XDG_CONFIG_HOME/obs-study-panel/config` (`~/.config/obs-study-panel/config`
   by default)
4. `obs-panel.conf` next to `OBS.sh`

The file is sourced, so it is plain bash and can set any of these:

```bash
# ~/.config/obs-study-panel/config
ALERT_SOUND="$HOME/Videos/Alarm/n_alarm.mp3"
SINK_NAME="OBS_Alert_Sink"
STATE_DIR="$HOME/obs-state"       # where the state files are written
MAX_LOG_BYTES=1048576             # rotate log.txt past this size
FILE_BAR_WIDTH=20                 # width of the bar in progress.txt
NON_TTY_ENTER_TIMEOUT=300         # seconds to wait for Enter on a pipe
THEME="Ocean"                     # color theme (see --list-themes)
QUOTE_LIST=(
  "Your future self is watching"
  "One more round, then the break is yours"
)
```

A config file with a syntax error is reported and the script stops; a config
file whose last command returns non-zero is perfectly fine.

### Environment variables

`ALERT_SOUND`, `SINK_NAME`, `STATE_DIR`, `MAX_LOG_BYTES`, `THEME` and `QUOTES`
can all be set in the environment; they take priority over the config file.
`QUOTES` is a newline separated list and replaces the quote array:

```bash
QUOTES=$'First line\nSecond line' ./OBS.sh 5 50 10
THEME=Forest ./OBS.sh 5 50 10
```

## OBS state files

The script writes these into the state directory (next to `OBS.sh` by
default); add them in OBS as *Text (read from file)* sources:

| File           | Content                                        |
|----------------|------------------------------------------------|
| `timer.txt`    | Remaining time, `HH:MM:SS`                    |
| `session.txt`  | `STUDY 2/5`, `BREAK 2/5`, `stopped`, ...       |
| `date.txt`     | `YYYY-MM-DD` (rolls over at midnight)          |
| `day.txt`      | Day of the week                                |
| `progress.txt` | Progress bar of the current phase, `45%`       |
| `points.txt`   | Points earned so far                           |
| `message.txt`  | The quote of the running study phase           |
| `next.txt`     | What comes next, e.g. `Break (10 minutes)`     |
| `log.txt`      | Timestamped event log (rotated to `log.txt.1`) |
| `theme.txt`    | The color theme that was picked last            |

`overlay.txt` contains all of it in one file, if you prefer a single OBS
source:

```
2026-10-21  Tuesday
STUDY 2/5
00:22:30
[#########-----------]  45%
Pts: 3
Next: Break (10 minutes)
Every round finished is progress made
```

## Audio alerts

At the end of every phase an alarm (`~/Videos/Alarm/n_alarm.mp3`) is played
and keeps playing until it finishes or you press `Enter` to continue. The
script creates a PulseAudio virtual sink named `OBS_Alert_Sink` so you can
capture the alarm in OBS separately from your mic. If the sink or the alarm
file is missing, the script falls back to the default output / skips the sound.

## Tests

```bash
./tests/run-tests.sh
```

85 checks that run in about a minute, in `--dry-run` mode inside a throwaway
directory. The interactive keys and the signal handling are driven through a
pty, and those tests are skipped when util-linux `script` is not installed.
