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
./OBS.sh <rounds> <study_minutes> <break_minutes>
```

Example: 5 rounds, 50 min study, 10 min break:

```bash
./OBS.sh 5 50 10
```

Limits: rounds 1-50, study 1-600 min, break 1-120 min (whole numbers only).

When a phase ends the script waits for you to press `Enter` before starting the
next one. Stop at any time with `Ctrl+C` (closing the terminal does the same):
the OBS files are reset to `stopped` / `00:00:00`. Each finished phase earns a
point, shown in the console when the session completes.

## OBS state files

The script writes these next to `OBS.sh`; add them in OBS as *Text (read from
file)* sources:

| File          | Content                                   |
|---------------|-------------------------------------------|
| `timer.txt`   | Remaining time, `HH:MM:SS`                |
| `session.txt` | `STUDY 2/5`, `BREAK 2/5`, `stopped`, ...  |
| `date.txt`    | `YYYY-MM-DD` (rolls over at midnight)     |
| `day.txt`     | Day of the week                           |
| `log.txt`     | Timestamped event log                     |

## Audio alerts

At the end of every phase an alarm (`~/Videos/Alarm/n_alarm.mp3`) is played
and keeps playing until it finishes or you press `Enter` to continue. The
script creates a PulseAudio virtual sink named `OBS_Alert_Sink` so you can
capture the alarm in OBS separately from your mic. If the sink or the alarm
file is missing, the script falls back to the default output / skips the sound.

## Customization

- `ALERT_SOUND` -> path to your alarm file
- `SINK_NAME` -> name of the virtual audio sink
- `QUOTES` -> motivation lines shown at the start of each study phase

