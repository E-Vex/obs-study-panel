// OBS.go - Study/break timer protocol (Go port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: Go 1.21+ (standard library only), bash (to load the
// bash-syntax config file).
//
// Build: go build -o OBS OBS.go
// Usage: ./OBS [options] <rounds> <study_minutes> <break_minutes>
// Stop:  Ctrl+C, or press 'q' while a phase is running
// Theme: press Alt+T while a phase is running (see --list-themes)
package main

import (
	"fmt"
	"io"
	"math/rand"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
	"unsafe"
)

var (
	prog       string
	startTime  = time.Now()
	envCaptured envCapture
)

type envCapture struct {
	alertSound, sinkName, stateDir, maxLogBytes, quotes, theme string
}

// ---------------------------------------------------------------------------
// Color themes
// ---------------------------------------------------------------------------

type theme struct {
	name, primary, secondary string
}

var themes = []theme{
	{"Purple", "\x1b[1;35m", "\x1b[0;35m"},
	{"Ocean", "\x1b[1;36m", "\x1b[0;34m"},
	{"Forest", "\x1b[1;32m", "\x1b[0;32m"},
	{"Sunset", "\x1b[1;33m", "\x1b[0;31m"},
	{"Rose", "\x1b[1;95m", "\x1b[0;31m"},
	{"Gold", "\x1b[1;93m", "\x1b[0;33m"},
	{"Mono", "\x1b[1;37m", "\x1b[0;37m"},
	{"Ice", "\x1b[1;96m", "\x1b[0;36m"},
	{"Ember", "\x1b[1;91m", "\x1b[0;31m"},
	{"Neon", "\x1b[1;92m", "\x1b[0;96m"},
	{"Cobalt", "\x1b[1;34m", "\x1b[0;36m"},
	{"Cherry", "\x1b[1;91m", "\x1b[0;35m"},
}

const (
	bold = "\x1b[1m"
	dim  = "\x1b[2m"
	nc   = "\x1b[0m"
)

const logo = ` /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/`

var defaultQuoteList = []string{
	"Focused effort beats scattered hours",
	"Every round finished is progress made",
	"Consistency beats intensity",
	"Start now, figure out the rest along the way",
	"A short break now means sharper focus next round",
}

var weekdays = []string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
	"Friday", "Saturday"}

// ---------------------------------------------------------------------------
// Mutable program state (mirrors the reference's global variables)
// ---------------------------------------------------------------------------

var (
	primary, secondary, themeName       string
	themeIndex                          int
	themeNoticeUntil                    int64

	dir, alertSound, sinkName, stateDir string
	maxLogBytes                         int64
	fileBarWidth                        int
	nonTtyEnterTimeout                  int
	alertPid                            int
	quoteList                           []string
	points                              int64
	lastDate                            string

	configFile                          string
	dryRun                              bool
	useAlert, useSink                   bool
	rounds, studyMin, breakMin          int
	cliTheme                            string
	durationUnit                        string
	secondsPerUnit                      int
	configTheme, configQuotes           string
	configLoaded                        string

	dateFile, dayFile, sessionFile     string
	timerFile, logFile, progressFile   string
	pointsFile, messageFile, nextFile   string
	overlayFile, themeFile             string

	sessionText                        string
	remainingStr                       = "00:00:00"
	pct                                int
	nextText, messageText, lastDay     string
	stateReady, stateFinalized          bool
	inCleanup                          bool

	phaseLabel, phaseSubtitle, phaseNext string
	phaseTotal, phaseElapsed             int64
	phasePaused, phaseSkipped            bool
	phaseStart, phasePausedTotal         int64
	phasePauseAt                        int64

	stdinIsTty        bool
	termSaved         *syscall.Termios
	key               string
	keyRead           bool
)

const termBarWidth = 24
const boxInner = 62

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

func nowSeconds() int64 {
	return int64(time.Since(startTime) / time.Second)
}

func out(format string, a ...interface{}) {
	fmt.Fprintf(os.Stdout, format, a...)
}

func errf(format string, a ...interface{}) {
	fmt.Fprintf(os.Stderr, format, a...)
}

func setTheme(i int) bool {
	if i < 0 || i >= len(themes) {
		return false
	}
	themeIndex = i
	themeName = themes[i].name
	primary = themes[i].primary
	secondary = themes[i].secondary
	return true
}

func themeIndexOf(want string) int {
	if want == "" {
		return -1
	}
	for i, t := range themes {
		if strings.EqualFold(t.name, want) {
			return i
		}
	}
	return -1
}

func saveTheme() {
	if themeFile != "" {
		os.WriteFile(themeFile, []byte(themeName+"\n"), 0644)
	}
}

func cycleTheme() {
	setTheme((themeIndex + 1) % len(themes))
	saveTheme()
	themeNoticeUntil = nowSeconds() + 3
	logEvent(fmt.Sprintf("Theme changed to: %s", themeName))
}

func printThemeList() {
	for _, t := range themes {
		fmt.Fprintf(os.Stdout, "  %-8s %s████%s\n", t.name, t.primary, t.secondary)
	}
}

func fmtHms(total int64) string {
	return fmt.Sprintf("%02d:%02d:%02d", total/3600, total%3600/60, total%60)
}

func makeBar(filled, width int, fill, empty, head string) string {
	var sb strings.Builder
	for i := 0; i < width; i++ {
		if i < filled {
			if head != "" && i == filled-1 {
				sb.WriteString(head)
			} else {
				sb.WriteString(fill)
			}
		} else {
			sb.WriteString(empty)
		}
	}
	return sb.String()
}

// ---------------------------------------------------------------------------
// Help and argument parsing
// ---------------------------------------------------------------------------

func helpText() string {
	return fmt.Sprintf(`Usage: %s [options] <rounds> <study_minutes> <break_minutes>

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
  %s 5 50 10           # 5 rounds, 50 min study, 10 min break
  %s --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  %s --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
`, prog, prog, prog, prog)
}

func printHelp(code int, w io.Writer) {
	fmt.Fprint(w, helpText())
	os.Exit(code)
}

func usageError() {
	printHelp(1, os.Stderr)
}

func validNumber(s string) bool {
	if s == "" || len(s) > 4 || s[0] < '1' || s[0] > '9' {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func parseArgs(argv []string) {
	args := argv
	var pos []string
	stop := false
	for !stop && len(args) > 0 {
		a := args[0]
		switch {
		case a == "-h" || a == "--help":
			printHelp(0, os.Stdout)
		case a == "-c" || a == "--config":
			if len(args) < 2 {
				errf("Error: %s needs a file argument\n", a)
				usageError()
			}
			configFile = args[1]
			args = args[2:]
		case a == "-d" || a == "--dry-run":
			dryRun = true
			args = args[1:]
		case a == "-n" || a == "--no-alert":
			useAlert = false
			args = args[1:]
		case a == "-s" || a == "--no-sink":
			useSink = false
			args = args[1:]
		case a == "-t" || a == "--theme":
			if len(args) < 2 {
				errf("Error: %s needs a theme name\n", a)
				usageError()
			}
			cliTheme = args[1]
			args = args[2:]
		case a == "--list-themes":
			printThemeList()
			os.Exit(0)
		case a == "--":
			pos = append(pos, args[1:]...)
			stop = true
		case strings.HasPrefix(a, "-"):
			errf("Error: unknown option: %s\n", a)
			usageError()
		default:
			pos = append(pos, args...)
			stop = true
		}
	}
	if len(pos) != 3 {
		usageError()
	}
	for _, v := range pos {
		if !validNumber(v) {
			usageError()
		}
	}
	rounds, _ = strconv.Atoi(pos[0])
	studyMin, _ = strconv.Atoi(pos[1])
	breakMin, _ = strconv.Atoi(pos[2])
	if rounds > 50 {
		errf("Error: rounds must be <= 50\n")
		usageError()
	}
	if studyMin > 600 {
		errf("Error: study minutes must be <= 600\n")
		usageError()
	}
	if breakMin > 120 {
		errf("Error: break minutes must be <= 120\n")
		usageError()
	}
	if dryRun {
		durationUnit = "seconds"
		secondsPerUnit = 1
	}
}

// ---------------------------------------------------------------------------
// Configuration file
// ---------------------------------------------------------------------------

// The config file is bash source code (exactly like the reference). It is
// interpreted by a child bash that first seeds the pre-config default knobs,
// sources the file, and then dumps the resulting values: unit separator
// 0x1F between key and value, record separator 0x1E between records. A
// sourced file that calls `exit N` terminates the child before the dump is
// written, which this program detects and mirrors.
const configDumpSh = `
set -u
IFS=$'\037' read -r -a QUOTE_LIST <<< "${QUOTES_SEED-}"
unset QUOTES_SEED
source "$1" || true
{
  d() { printf '%s\037%s\036' "$1" "${2-}"; }
  d ALERT_SOUND "${ALERT_SOUND-}"
  d SINK_NAME "${SINK_NAME-}"
  d STATE_DIR "${STATE_DIR-}"
  d MAX_LOG_BYTES "${MAX_LOG_BYTES-}"
  d FILE_BAR_WIDTH "${FILE_BAR_WIDTH-}"
  d NON_TTY_ENTER_TIMEOUT "${NON_TTY_ENTER_TIMEOUT-}"
  d THEME "${THEME-}"
  d POINTS "${POINTS-}"
  d LAST_DATE "${LAST_DATE-}"
  d QUOTES "${QUOTES-}"
  for q in ${QUOTE_LIST[@]+"${QUOTE_LIST[@]}"}; do d QUOTE "$q"; done
} > "$2"
`

func findConfigFile() string {
	if configFile != "" {
		return configFile
	}
	if p := os.Getenv("OBS_PANEL_CONFIG"); p != "" {
		return p
	}
	xdgBase := os.Getenv("XDG_CONFIG_HOME")
	if xdgBase == "" {
		xdgBase = filepath.Join(os.Getenv("HOME"), ".config")
	}
	xdg := filepath.Join(xdgBase, "obs-study-panel", "config")
	if st, err := os.Stat(xdg); err == nil && !st.IsDir() {
		return xdg
	}
	local := filepath.Join(dir, "obs-panel.conf")
	if st, err := os.Stat(local); err == nil && !st.IsDir() {
		return local
	}
	return ""
}

func quotesToList(raw string) {
	quoteList = quoteList[:0]
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimRight(line, "\r")
		if line != "" {
			quoteList = append(quoteList, line)
		}
	}
}

func parseIntSafe(v string, dflt int64) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	if err != nil {
		return dflt
	}
	return n
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if !unicode.IsDigit(c) {
			return false
		}
	}
	return true
}

func loadConfig(path string) {
	if st, err := os.Stat(path); err != nil || st.IsDir() {
		errf("Error: config file is not readable: %s\n", path)
		os.Exit(1)
	}
	// Syntax check up front, exactly like the reference.
	if _, err := exec.LookPath("bash"); err != nil {
		errf("Error: bash is required to read the config file: %s\n", path)
		os.Exit(1)
	}
	chk := exec.Command("bash", "-n", path)
	var errBuf strings.Builder
	chk.Stderr = &errBuf
	if err := chk.Run(); err != nil {
		errf("Error: syntax error in config file: %s\n", path)
		lines := strings.Split(errBuf.String(), "\n")
		shown := 0
		for _, l := range lines {
			if strings.TrimSpace(l) == "" {
				continue
			}
			errf("%s\n", l)
			shown++
			if shown >= 3 {
				break
			}
		}
		os.Exit(1)
	}

	dumpFile := filepath.Join(os.TempDir(),
		fmt.Sprintf("obs-panel-conf-%d-%d", os.Getpid(), time.Now().UnixNano()))
	os.WriteFile(dumpFile, nil, 0600)

	// Seed the pre-config defaults, exactly what the reference holds while
	// it sources the file (the real environment's THEME/QUOTES pass through).
	env := append(os.Environ(),
		"ALERT_SOUND="+alertSound,
		"SINK_NAME="+sinkName,
		"STATE_DIR=",
		"MAX_LOG_BYTES=1048576",
		"FILE_BAR_WIDTH=20",
		"NON_TTY_ENTER_TIMEOUT=300",
		fmt.Sprintf("POINTS=%d", points),
		"LAST_DATE="+lastDate,
		"QUOTES_SEED="+strings.Join(quoteList, "\x1f"),
	)
	cmd := exec.Command("bash", "-c", configDumpSh, "obs-panel", path, dumpFile)
	cmd.Env = dedupeEnv(env)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	runErr := cmd.Run()
	rc := 0
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		} else {
			rc = 1
		}
	}
	raw, readErr := os.ReadFile(dumpFile)
	os.Remove(dumpFile)

	if readErr != nil || len(raw) == 0 {
		// The config called exit N before the dump was written.
		if rc == 0 {
			rc = 1
		}
		os.Exit(rc)
	}

	values := map[string]string{}
	var quotes []string
	for _, record := range strings.Split(string(raw), "\x1e") {
		if record == "" {
			continue
		}
		i := strings.IndexByte(record, '\x1f')
		if i < 0 {
			continue
		}
		k := record[:i]
		v := record[i+1:]
		if k == "QUOTE" {
			quotes = append(quotes, v)
		} else {
			values[k] = v
		}
	}

	if v, ok := values["ALERT_SOUND"]; ok {
		alertSound = v
	}
	if v, ok := values["SINK_NAME"]; ok {
		sinkName = v
	}
	if v, ok := values["STATE_DIR"]; ok {
		stateDir = v
	}
	maxLogBytes = 1048576
	if v, ok := values["MAX_LOG_BYTES"]; ok {
		maxLogBytes = parseIntSafe(v, 1048576)
	}
	fileBarWidth = 20
	if v, ok := values["FILE_BAR_WIDTH"]; ok {
		fileBarWidth = int(parseIntSafe(v, 20))
	}
	nonTtyEnterTimeout = 300
	if v, ok := values["NON_TTY_ENTER_TIMEOUT"]; ok {
		nonTtyEnterTimeout = int(parseIntSafe(v, 300))
	}
	if v, ok := values["THEME"]; ok {
		configTheme = v
	}
	if v, ok := values["POINTS"]; ok {
		points = parseIntSafe(v, 0)
	}
	if v, ok := values["LAST_DATE"]; ok {
		lastDate = v
	}
	if v, ok := values["QUOTES"]; ok {
		configQuotes = v
	}
	quoteList = quotes
	configLoaded = path
}

func dedupeEnv(env []string) []string {
	seen := map[string]bool{}
	var out []string
	for i := len(env) - 1; i >= 0; i-- {
		k := env[i]
		if j := strings.IndexByte(k, '='); j >= 0 {
			k = k[:j]
		}
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, env[i])
	}
	// reverse back to keep a stable order
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

func applyQuoteSources() {
	if envCaptured.quotes != "" {
		quotesToList(envCaptured.quotes)
	} else if configQuotes != "" {
		quotesToList(configQuotes)
	}
}

func sanityKnobs() {
	if maxLogBytes <= 0 {
		maxLogBytes = 1048576
	}
	if fileBarWidth <= 0 || fileBarWidth > 200 {
		fileBarWidth = 20
	}
	if nonTtyEnterTimeout <= 0 || nonTtyEnterTimeout > 3600 {
		nonTtyEnterTimeout = 300
	}
}

// ---------------------------------------------------------------------------
// Paths and theme selection
// ---------------------------------------------------------------------------

func setupPaths() {
	if stateDir == "" {
		stateDir = dir
	}
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		errf("Error: cannot create state dir: %s\n", stateDir)
		os.Exit(1)
	}
	join := func(n string) string { return filepath.Join(stateDir, n) }
	dateFile = join("date.txt")
	dayFile = join("day.txt")
	sessionFile = join("session.txt")
	timerFile = join("timer.txt")
	logFile = join("log.txt")
	progressFile = join("progress.txt")
	pointsFile = join("points.txt")
	messageFile = join("message.txt")
	nextFile = join("next.txt")
	overlayFile = join("overlay.txt")
	themeFile = join("theme.txt")
}

func selectTheme() {
	request := cliTheme
	if request == "" {
		request = envCaptured.theme
	}
	if request == "" {
		request = configTheme
	}
	if request == "" {
		if data, err := os.ReadFile(themeFile); err == nil {
			if i := strings.IndexByte(string(data), '\n'); i >= 0 {
				request = string(data[:i])
			} else {
				request = string(data)
			}
		}
	}
	if request != "" {
		idx := themeIndexOf(request)
		if idx < 0 {
			errf("Warning: unknown theme '%s', using %s\n", request, themeName)
		} else {
			setTheme(idx)
		}
	}
}

// ---------------------------------------------------------------------------
// OBS state files
// ---------------------------------------------------------------------------

func writeStateFile(path, text string) {
	os.WriteFile(path, []byte(text+"\n"), 0644)
}

func updateDateDay() {
	now := time.Now()
	d := now.Format("2006-01-02")
	if d == lastDate {
		return
	}
	lastDate = d
	lastDay = weekdays[now.Weekday()]
	writeStateFile(dateFile, d)
	writeStateFile(dayFile, lastDay)
}

func syncState() {
	updateDateDay()
	publishState()
}

func publishState() {
	filled := pct * fileBarWidth / 100
	bar := makeBar(filled, fileBarWidth, "#", "-", "")
	pctS := fmt.Sprintf("%3d%%", pct)

	writeStateFile(sessionFile, sessionText)
	writeStateFile(timerFile, remainingStr)
	writeStateFile(pointsFile, fmt.Sprintf("%d", points))
	writeStateFile(nextFile, nextText)
	writeStateFile(messageFile, messageText)
	writeStateFile(progressFile, fmt.Sprintf("[%s] %s", bar, pctS))

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("%s %s\n", lastDate, lastDay))
	sb.WriteString(sessionText + "\n")
	sb.WriteString(remainingStr + "\n")
	sb.WriteString(fmt.Sprintf("[%s] %s\n", bar, pctS))
	sb.WriteString(fmt.Sprintf("Pts: %d\n", points))
	sb.WriteString("Next: " + nextText + "\n")
	if messageText != "" {
		sb.WriteString(messageText + "\n")
	}
	os.WriteFile(overlayFile, []byte(sb.String()), 0644)
}

func rotateLogIfNeeded() {
	if st, err := os.Stat(logFile); err == nil && st.Size() >= maxLogBytes {
		if err := os.Rename(logFile, logFile+".1"); err == nil {
			os.WriteFile(logFile, nil, 0644)
		}
	}
}

func logEvent(msg string) {
	rotateLogIfNeeded()
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "[%s] %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
}

// ---------------------------------------------------------------------------
// Audio alerts
// ---------------------------------------------------------------------------

func sinkIsReady() bool {
	if _, err := exec.LookPath("pactl"); err != nil {
		return false
	}
	outb, err := exec.Command("pactl", "list", "short", "sinks").Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(outb), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 1 && fields[1] == sinkName {
			return true
		}
	}
	return false
}

func setupAudioSink() {
	if !useSink {
		return
	}
	if _, err := exec.LookPath("pactl"); err != nil {
		return
	}
	if sinkIsReady() {
		return
	}
	cmd := exec.Command("pactl", "load-module", "module-null-sink",
		"sink_name="+sinkName,
		"sink_properties=device.description="+sinkName)
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	cmd.Run()
}

func stopAlert() {
	if alertPid > 0 {
		syscall.Kill(alertPid, syscall.SIGTERM)
		alertPid = 0
	}
}

func playAlert() {
	if !useAlert {
		return
	}
	stopAlert()
	if alertSound == "" {
		fmt.Printf("%s(alert file not found: none)%s\n", dim, nc)
		return
	}
	if st, err := os.Stat(alertSound); err != nil || st.IsDir() {
		fmt.Printf("%s(alert file not found: %s)%s\n", dim, alertSound, nc)
		return
	}

	var player []string
	if _, err := exec.LookPath("mpv"); err == nil {
		player = []string{"mpv", "--no-video", "--volume=70"}
	} else if _, err := exec.LookPath("paplay"); err == nil {
		player = []string{"paplay"}
	} else if _, err := exec.LookPath("ffplay"); err == nil {
		player = []string{"ffplay", "-nodisp", "-autoexit"}
	} else if _, err := exec.LookPath("cvlc"); err == nil {
		player = []string{"cvlc", "--play-and-exit", "--no-video", "--volume=70"}
	} else {
		fmt.Printf("%s(no audio player found - install mpv / paplay / ffplay)%s\n", dim, nc)
		return
	}

	if useSink && !sinkIsReady() {
		setupAudioSink()
	}

	argv := append(append([]string{}, player...), alertSound)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if useSink && sinkIsReady() {
		cmd.Env = append(os.Environ(), "PULSE_SINK="+sinkName)
	}
	if err := cmd.Start(); err != nil {
		return
	}
	alertPid = cmd.Process.Pid
	// Reap the player later; it must survive this program (bash's `&`).
	go func() {
		_ = cmd.Wait() //nolint:errcheck - fire and forget
	}()

	if useSink && sinkIsReady() {
		fmt.Printf("%s-> alert on OBS sink (%s)%s\n", dim, sinkName, nc)
	} else {
		fmt.Printf("%s-> alert on default device (OBS sink unavailable)%s\n",
			secondary, nc)
	}
}

// ---------------------------------------------------------------------------
// Keyboard input
// ---------------------------------------------------------------------------

// The input runs a reader goroutine feeding a byte channel; every wait uses
// a select with a timeout. bytes, eof and done are program-global so the
// strictly sequential waits share one queue.
var (
	inputCh  = make(chan byte, 256)
	eofCh    = make(chan struct{})
	bufQueue []byte
)

func startInputReader() {
	go func() {
		buf := make([]byte, 256)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				for i := 0; i < n; i++ {
					inputCh <- buf[i]
				}
			}
			if err != nil {
				close(eofCh)
				return
			}
		}
	}()
}

// waitByte: byte, or -1 on timeout/eof.
func waitByte(timeout time.Duration) int {
	if len(bufQueue) > 0 {
		b := bufQueue[0]
		bufQueue = bufQueue[1:]
		return int(b)
	}
	select {
	case b := <-inputCh:
		return int(b)
	case <-eofCh:
		return -1
	case <-time.After(timeout):
		return -1
	}
}

func setupTerminal() {
	stdinIsTty = isattyStdin()
	if !stdinIsTty {
		return
	}
	saved, err := tcget(0)
	if err != nil {
		return
	}
	termSaved = saved
	raw := *saved
	raw.Lflag &^= syscall.ECHO | syscall.ICANON
	raw.Cc[syscall.VMIN] = 1
	raw.Cc[syscall.VTIME] = 0
	tcset(0, &raw)
}

func restoreTerminal() {
	if termSaved != nil {
		tcset(0, termSaved)
		termSaved = nil
	}
}

func isattyStdin() bool {
	_, err := tcget(0)
	return err == nil
}

func tcget(fd int) (*syscall.Termios, error) {
	var t syscall.Termios
	_, _, errno := syscall.Syscall6(syscall.SYS_IOCTL, uintptr(fd),
		syscall.TCGETS, uintptr(unsafe.Pointer(&t)), 0, 0, 0)
	if errno != 0 {
		return nil, errno
	}
	return &t, nil
}

func tcset(fd int, t *syscall.Termios) {
	syscall.Syscall6(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS,
		uintptr(unsafe.Pointer(t)), 0, 0, 0)
}

func waitKey(timeout time.Duration) {
	key = ""
	keyRead = false
	if !stdinIsTty {
		time.Sleep(timeout)
		return
	}
	b := waitByte(timeout)
	if b < 0 {
		return
	}
	keyRead = true
	if b == 0x1b {
		nxt := waitByte(300 * time.Millisecond)
		if nxt == 't' || nxt == 'T' {
			key = "alt-t"
		}
	} else {
		key = string(byte(b))
	}
}

func discardPendingInput() {
	if !stdinIsTty {
		return
	}
	for {
		b := waitByte(10 * time.Millisecond)
		if b < 0 {
			return
		}
	}
}

func waitForEnter() {
	if stdinIsTty {
		for {
			b := waitByte(time.Second)
			if b < 0 {
				updateDateDay()
				continue
			}
			if b == '\n' {
				return
			}
			// EOF bytes arrive as -1 above; other bytes keep waiting.
			select {
			case <-eofCh:
				return
			default:
			}
		}
	}
	waited := 0
	for waited < nonTtyEnterTimeout {
		sliceStart := time.Now()
		for {
			elapsed := time.Since(sliceStart)
			if elapsed >= 5*time.Second {
				waited += 5
				break
			}
			b := waitByte(5*time.Second - elapsed)
			if b < 0 {
				// EOF or slice timeout: distinguish by the eof channel.
				select {
				case <-eofCh:
					return
				default:
					waited += 5
					break
				}
			}
			if b == '\n' {
				return
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Status / progress UI
// ---------------------------------------------------------------------------

func phaseColor(label string) string {
	if label == "STUDY" {
		return primary
	}
	return secondary
}

func durationLabel(n int) string {
	if n == 1 {
		if durationUnit == "seconds" {
			return "1 second"
		}
		return "1 minute"
	}
	return fmt.Sprintf("%d %s", n, durationUnit)
}

func roundsLabel(n int) string {
	if n == 1 {
		return "1 round"
	}
	return fmt.Sprintf("%d rounds", n)
}

func drawStatus(label string, round, totalRounds int, elapsed, total int64,
	paused bool) {
	filled := int64(0)
	if total > 0 {
		filled = elapsed * int64(termBarWidth) / total
	}
	if filled > int64(termBarWidth) {
		filled = int64(termBarWidth)
	}
	bar := makeBar(int(filled), termBarWidth, "=", " ", ">")
	color := phaseColor(label)
	flag := ""
	if paused {
		flag = primary + " PAUSED" + nc
	}
	if nowSeconds() < themeNoticeUntil {
		flag += "  " + dim + "Theme: " + themeName + nc
	}
	fmt.Printf("\r\033[K")
	fmt.Printf("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
		bold, color, label, nc, round, totalRounds,
		color, bar, nc, pct, remainingStr,
		primary, points, nc, flag)
}

func boxRow(color, plain, styled string) {
	pad := boxInner - len([]rune(plain))
	if pad < 0 {
		pad = 0
	}
	fmt.Printf("%s║%s%s%s║%s\n", color, styled, strings.Repeat(" ", pad), color, nc)
}

func phaseHeader(label string, round, total, minutes int, subtitle string) {
	if len(subtitle) > boxInner-4 {
		subtitle = subtitle[:boxInner-4]
	}
	color := phaseColor(label)
	bar := strings.Repeat("═", boxInner)
	dur := durationLabel(minutes)
	info := fmt.Sprintf("%s  ·  Round %d / %d  ·  %s", label, round, total, dur)
	styled1 := fmt.Sprintf("  %s%s%s%s  ·  Round %d / %d  ·  %s",
		bold, label, nc, color, round, total, dur)
	styled2 := "  " + dim + subtitle + nc + color

	fmt.Println()
	fmt.Printf("%s╔%s╗%s\n", color, bar, nc)
	boxRow(color, "  "+info, styled1)
	boxRow(color, "  "+subtitle, styled2)
	if stdinIsTty {
		keys := "  p pause  ·  s skip  ·  q quit  ·  Alt+T theme"
		boxRow(color, keys, dim+keys+nc+color)
	}
	fmt.Printf("%s╚%s╝%s\n", color, bar, nc)
	fmt.Println()
}

func showCompletion(phase string, round, totalRounds int, nextPhase string,
	skipped bool) {
	const width = 60
	line := strings.Repeat("=", width)
	var title string
	switch {
	case skipped:
		title = "PHASE SKIPPED"
	case phase == "STUDY":
		title = "STUDY SESSION COMPLETE"
	default:
		title = "BREAK COMPLETE"
	}
	color := phaseColor(phase)
	pad := (width + len(title)) / 2
	fmt.Println()
	fmt.Printf("%s%s%s\n", color, line, nc)
	fmt.Printf("%s%s%s%s\n", color, strings.Repeat(" ", pad), title, nc)
	fmt.Printf("%s%s%s\n", color, line, nc)
	fmt.Println()
	fmt.Printf("  Round:   %s%d%s / %d\n", bold, round, nc, totalRounds)
	fmt.Printf("  Points:  %s%d%s\n", primary, points, nc)
	fmt.Println()
	if nextPhase == "None" {
		fmt.Printf("  Next:    %sSession complete%s\n", dim, nc)
	} else {
		fmt.Printf("  Next:    %s%s%s\n", bold, nextPhase, nc)
	}
	fmt.Println()
	fmt.Printf("  %sPress Enter to continue...%s", primary, nc)
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------

func phasePrepare(ptype string, minutes, round, totalRounds int) {
	if ptype == "study" {
		phaseLabel = "STUDY"
		if len(quoteList) > 0 {
			phaseSubtitle = quoteList[rand.Intn(len(quoteList))]
		} else {
			phaseSubtitle = "Stay focused."
		}
	} else {
		phaseLabel = "BREAK"
		phaseSubtitle = "Relax and recharge."
	}

	if ptype == "study" {
		if round < totalRounds {
			phaseNext = "Break (" + durationLabel(breakMin) + ")"
		} else {
			phaseNext = "None"
		}
	} else {
		phaseNext = "Study (" + durationLabel(studyMin) + ")"
	}

	phaseTotal = int64(minutes * secondsPerUnit)
	phaseElapsed = 0
	phasePaused = false
	phaseSkipped = false
	phaseStart = nowSeconds()
	phasePausedTotal = 0
	phasePauseAt = 0

	sessionText = fmt.Sprintf("%s %d/%d", phaseLabel, round, totalRounds)
	remainingStr = fmtHms(phaseTotal)
	pct = 0
	if phaseNext == "None" {
		nextText = "Session complete"
	} else {
		nextText = phaseNext
	}
	messageText = phaseSubtitle

	logEvent(fmt.Sprintf("Start: %s %d/%d (%s)", phaseLabel, round,
		totalRounds, durationLabel(minutes)))
	phaseHeader(phaseLabel, round, totalRounds, minutes, phaseSubtitle)
	syncState()
}

func phaseHandleKey(round, totalRounds int) {
	switch key {
	case "p", "P", " ":
		if phasePaused {
			phasePausedTotal += nowSeconds() - phasePauseAt
			phasePaused = false
			logEvent(fmt.Sprintf("Resumed: %s %d/%d", phaseLabel, round, totalRounds))
		} else {
			phasePaused = true
			phasePauseAt = nowSeconds()
			logEvent(fmt.Sprintf("Paused: %s %d/%d", phaseLabel, round, totalRounds))
		}
	case "s", "S":
		phaseSkipped = true
		logEvent(fmt.Sprintf("Skipped: %s %d/%d", phaseLabel, round, totalRounds))
	case "q", "Q":
		logEvent("Quit requested by user")
		cleanup(0)
	case "alt-t":
		cycleTheme()
	}
}

func phaseCount(round, totalRounds int) {
	for phaseElapsed < phaseTotal {
		remaining := phaseTotal - phaseElapsed
		if remaining < 0 {
			remaining = 0
		}
		remainingStr = fmtHms(remaining)
		pct = 0
		if phaseTotal > 0 {
			pct = int(phaseElapsed * 100 / phaseTotal)
		}
		if pct > 100 {
			pct = 100
		}
		sessionText = fmt.Sprintf("%s %d/%d", phaseLabel, round, totalRounds)
		if phasePaused {
			sessionText += " (PAUSED)"
		}

		syncState()
		drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal,
			phasePaused)

		waitKey(time.Second)
		if keyRead {
			phaseHandleKey(round, totalRounds)
			if phaseSkipped {
				break
			}
		}
		// CRASH-INJECT-POINT
		if !phasePaused {
			phaseElapsed = nowSeconds() - phaseStart - phasePausedTotal
		}
	}
}

func phaseFinish(round, totalRounds int) {
	if phaseSkipped {
		sessionText = fmt.Sprintf("%s %d/%d (SKIPPED)", phaseLabel, round,
			totalRounds)
	} else {
		pct = 100
		points++
	}
	remainingStr = "00:00:00"
	syncState()
	drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal, false)
	fmt.Println()
	logEvent(fmt.Sprintf("End: %s %d/%d", phaseLabel, round, totalRounds))

	playAlert()

	discardPendingInput()
	showCompletion(phaseLabel, round, totalRounds, phaseNext, phaseSkipped)
	waitForEnter()
	stopAlert()
	fmt.Println()
}

func runPhase(ptype string, minutes, round, totalRounds int) {
	phasePrepare(ptype, minutes, round, totalRounds)
	phaseCount(round, totalRounds)
	phaseFinish(round, totalRounds)
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

func resetStateFiles() {
	sessionText = "stopped"
	remainingStr = "00:00:00"
	pct = 0
	nextText = ""
	syncState()
}

func cleanup(code int) {
	if inCleanup {
		return
	}
	inCleanup = true
	stateFinalized = true
	stopAlert()
	resetStateFiles()
	logEvent("Protocol stopped manually")
	fmt.Println()
	fmt.Printf("%s%sInterrupted.%s %sState files reset to stopped.%s\n",
		secondary, bold, nc, dim, nc)
	restoreTerminal()
	os.Exit(code)
}

func onUnexpectedDeath(rc int) {
	if !stateReady || stateFinalized {
		return
	}
	stateFinalized = true
	stopAlert()
	resetStateFiles()
	logEvent(fmt.Sprintf("Protocol ended unexpectedly (exit %d)", rc))
}

func finalizeSession() {
	sessionText = "session complete"
	remainingStr = "00:00:00"
	pct = 100
	nextText = ""
	syncState()
	stateFinalized = true
	logEvent(fmt.Sprintf("Protocol complete - total points: %d", points))
}

func finalBanner() {
	const bannerWidth = 60
	title := "ALL SESSIONS COMPLETE"
	inner := bannerWidth - 2
	pad := (inner - len(title)) / 2
	border := strings.Repeat("#", bannerWidth)
	fmt.Println()
	fmt.Printf("%s%s%s\n", primary, border, nc)
	fmt.Printf("%s#%s%s%s%s%s%s#%s\n", primary, nc,
		strings.Repeat(" ", pad), bold, title,
		strings.Repeat(" ", inner-pad-len(title)), nc, primary)
	fmt.Printf("%s%s%s\n", primary, border, nc)
	fmt.Println()
	fmt.Printf("  %sTotal Rounds:%s  %s%d%s\n", bold, nc, primary, rounds, nc)
	fmt.Printf("  %sTotal Points:%s %s%d%s\n", bold, nc, primary, points, nc)
	fmt.Println()
	fmt.Printf("%s%sGreat work!%s %sExiting.%s\n", primary, bold, nc, dim, nc)
}

func printLogo() {
	fmt.Println(primary)
	fmt.Println(logo)
	fmt.Println(nc)
	fmt.Printf("%s%s     Study / Break Timer Protocol%s\n", primary, bold, nc)
	fmt.Printf("%s── live state written to date · day · session · timer · log%s\n",
		dim, nc)
	fmt.Println()
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	prog = filepath.Base(os.Args[0])
	primary = themes[0].primary
	secondary = themes[0].secondary
	themeName = themes[0].name
	durationUnit = "minutes"
	secondsPerUnit = 60
	sinkName = "OBS_Alert_Sink"
	quoteList = append([]string{}, defaultQuoteList...)
	maxLogBytes = 1048576
	fileBarWidth = 20
	nonTtyEnterTimeout = 300

	// Environment overrides (captured before the defaults are applied).
	envCaptured.alertSound = os.Getenv("ALERT_SOUND")
	envCaptured.sinkName = os.Getenv("SINK_NAME")
	envCaptured.stateDir = os.Getenv("STATE_DIR")
	envCaptured.maxLogBytes = os.Getenv("MAX_LOG_BYTES")
	envCaptured.quotes = os.Getenv("QUOTES")
	envCaptured.theme = os.Getenv("THEME")

	// DIR = directory of this program.
	if exe, err := os.Executable(); err == nil {
		dir = filepath.Dir(exe)
		if resolved, err := filepath.EvalSymlinks(dir); err == nil {
			dir = resolved
		}
	} else {
		dir, _ = os.Getwd()
	}

	// Built-in defaults.
	if home := os.Getenv("HOME"); home != "" {
		alertSound = filepath.Join(home, "Videos/Alarm/n_alarm.mp3")
	}

	parseArgs(os.Args[1:])

	if cfg := findConfigFile(); cfg != "" {
		loadConfig(cfg)
	}

	// Environment variables beat the config file.
	if envCaptured.alertSound != "" {
		alertSound = envCaptured.alertSound
	}
	if envCaptured.sinkName != "" {
		sinkName = envCaptured.sinkName
	}
	if envCaptured.stateDir != "" {
		stateDir = envCaptured.stateDir
	}
	if envCaptured.maxLogBytes != "" && isDigits(envCaptured.maxLogBytes) {
		if v := parseIntSafe(envCaptured.maxLogBytes, maxLogBytes); v > 0 {
			maxLogBytes = v
		}
	}

	applyQuoteSources()
	sanityKnobs()

	setupPaths()
	selectTheme()

	// Signal handling: conventional exit codes 128 + signal number, run in a
	// normal goroutine (no async-signal-safety limits like C).
	sigCh := make(chan os.Signal, 4)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		sig := <-sigCh
		switch sig {
		case syscall.SIGINT:
			cleanup(130)
		case syscall.SIGTERM:
			cleanup(143)
		default:
			cleanup(129)
		}
	}()

	startInputReader()
	setupTerminal()

	// The EXIT-trap equivalent: an injected panic or a runtime error
	// unwinds through this recover, resets the state files and exits 42
	// (see tests/ports.tsv crash entry).
	defer func() {
		if r := recover(); r != nil {
			onUnexpectedDeath(42)
			restoreTerminal()
			os.Exit(42)
		}
	}()

	printLogo()
	setupAudioSink()
	updateDateDay()
	// From here on the state files may be written (and have to be reset if
	// the program dies unexpectedly).
	stateReady = true
	logEvent(fmt.Sprintf("Starting new study protocol: %s, %s study, %s break",
		roundsLabel(rounds), durationLabel(studyMin), durationLabel(breakMin)))

	fmt.Printf("%sProtocol:%s %s%s%s  %s|%s  %s%s%s study  %s|%s  %s%s%s"+
		" break  %s|%s  %sTheme: %s%s\n",
		secondary, nc, bold, roundsLabel(rounds), nc, dim, nc,
		bold, durationLabel(studyMin), nc, dim, nc,
		bold, durationLabel(breakMin), nc, dim, nc, bold, themeName, nc)
	if configLoaded != "" {
		fmt.Printf("%sConfig: %s%s\n", dim, configLoaded, nc)
	}
	fmt.Println()

	for round := 1; round <= rounds; round++ {
		runPhase("study", studyMin, round, rounds)
		if round < rounds {
			runPhase("break", breakMin, round, rounds)
		}
	}

	finalizeSession()
	finalBanner()
	restoreTerminal()
	os.Exit(0)
}
