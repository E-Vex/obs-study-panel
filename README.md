# obs-study-panel

Study/break timer protocol for study livestreams. A Bash script that runs a
Pomodoro-style study loop and writes its live state to text files, which you
can display in OBS Studio as Text sources.

## Requirements

- Linux (uses `date`, `pactl`, `mpv` if available)
- `figlet` — optional, just for the startup banner

## Usage

```bash
./OBS.sh <rounds> <study_minutes> <break_minutes>
```

Example: 5 rounds, 50 min study, 10 min break:

```bash
./OBS.sh 5 50 10
```

Stop at any time with `Ctrl+C`. Each finished phase earns a point, shown in
the console when the session completes.

## Audio alerts

At the end of every phase an alarm (`~/Videos/Alarm/n_alarm.mp3`) is played
via `mpv`. The script creates a PulseAudio virtual sink named
`OBS_Alert_Sink` so you can capture the alarm in OBS separately from your mic.

## Customization

- `ALERT_SOUND` -> path to your alarm file
- `SINK_NAME` -> name of the virtual audio sink
- `QUOTES` -> motivation lines shown at the start of each study phase

