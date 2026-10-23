# OBS.nim - Study/break timer protocol (Nim port of OBS.sh)
#
# Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
# progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
# use as Text sources in OBS Studio. OBS.sh is the reference implementation;
# see docs/port-spec.md for the behavior contract and README.md for usage.
#
# Requirements: Nim 2.x, bash (to load the bash-syntax config file).
# Build: nim c -d:release --opt:speed -o:obs OBS.nim
#
# POSIX details (termios, poll, sigaction, fork/exec) come from the standard
# `posix` module. Signal handlers only store the exit code; the interrupted
# poll loop performs the cleanup, like the Perl port defers it.
#
import std/[os, strutils, strformat, times, sequtils, tables, random, strtabs, osproc, streams]
import posix/termios
from std/posix import nil

# ---------------------------------------------------------------------------
# POSIX surface (qualified to avoid name clashes with std/os)
# ---------------------------------------------------------------------------
type
  CrashExit* = ref object of CatchableError
    code*: int

# Nim's quit() saturates exit codes at 127 on POSIX (the 128+ range is
# reserved for signal deaths), so exit() is declared directly to preserve
# the exact signal exit codes 130/143/129 and crash codes.
proc cexit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

var sigFlag: cint = 0

proc onSignal(sig: cint) {.noconv.} =
  case sig
  of 2: sigFlag = 130   # SIGINT
  of 15: sigFlag = 143  # SIGTERM
  of 1: sigFlag = 129   # SIGHUP
  else: sigFlag = cint(128 + sig)

proc installSignalHandlers() =
  var sa: posix.Sigaction
  discard posix.sigemptyset(sa.sa_mask)
  sa.sa_flags = 0                   # no SA_RESTART: poll() must wake up
  sa.sa_handler = onSignal
  discard posix.sigaction(posix.SIGINT, sa, nil)
  sa.sa_handler = onSignal
  discard posix.sigaction(posix.SIGTERM, sa, nil)
  sa.sa_handler = onSignal
  discard posix.sigaction(posix.SIGHUP, sa, nil)

proc cleanup(code: int)
proc logEvent(msg: string)
proc publishState()

proc checkSignal() =
  if sigFlag != 0:
    cleanup(int(sigFlag))

var startEpoch: float = 0.0   # epochTime() at program start

proc nowSeconds(): int64 =
  int64(epochTime() - startEpoch)

proc nowMs(): int64 =
  int64((epochTime() - startEpoch) * 1000.0)

proc sleepMs(ms: int) =
  var waited = 0
  while waited < ms:
    checkSignal()
    let slice = min(ms - waited, 50)
    var req = posix.Timespec(tv_sec: posix.Time(slice div 1000),
                             tv_nsec: clong(slice mod 1000))
    var rem = posix.Timespec(tv_sec: posix.Time(0), tv_nsec: clong(0))
    discard posix.nanosleep(req, rem)
    waited += slice

# Wait until fd 0 is readable. true = readable.
proc pollReadable(ms: int): bool =
  let deadline = nowMs() + ms
  while true:
    checkSignal()
    var left = deadline - nowMs()
    if left < 0: left = 0
    var fds = [posix.TPollfd(fd: 0, events: posix.POLLIN, revents: 0'i16)]
    let rc = posix.poll(addr fds[0], 1, cint(left))
    if rc > 0:
      return fds[0].revents != 0
    if rc == 0:
      if nowMs() >= deadline: return false
      continue

# One byte with a timeout: 0..255, -1 timeout, -2 EOF.
proc readByteTimeout(ms: int): int =
  if not pollReadable(ms): return -1
  var b: uint8 = 0
  let n = posix.read(0, addr b, 1)
  if n <= 0: return -2
  return int(b)

# ---------------------------------------------------------------------------
# Color themes: (name, primary, secondary)
# ---------------------------------------------------------------------------
const ThemeNames = ["Purple", "Ocean", "Forest", "Sunset", "Rose", "Gold",
                    "Mono", "Ice", "Ember", "Neon", "Cobalt", "Cherry"]
const ThemePrimary = ["\e[1;35m", "\e[1;36m", "\e[1;32m", "\e[1;33m",
                      "\e[1;95m", "\e[1;93m", "\e[1;37m", "\e[1;96m",
                      "\e[1;91m", "\e[1;92m", "\e[1;34m", "\e[1;91m"]
const ThemeSecondary = ["\e[0;35m", "\e[0;34m", "\e[0;32m", "\e[0;31m",
                        "\e[0;31m", "\e[0;33m", "\e[0;37m", "\e[0;36m",
                        "\e[0;31m", "\e[0;96m", "\e[0;36m", "\e[0;35m"]

const Bold = "\e[1m"
const Dim = "\e[2m"
const Nc = "\e[0m"

const Logo = """
 /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/"""

const DefaultQuoteList = [
  "Focused effort beats scattered hours",
  "Every round finished is progress made",
  "Consistency beats intensity",
  "Start now, figure out the rest along the way",
  "A short break now means sharper focus next round"]

var primary = ThemePrimary[0]
var secondary = ThemeSecondary[0]
var themeName = ThemeNames[0]
var themeIndex = 0
var themeNoticeUntil = 0'i64

proc setTheme(i: int): bool =
  if i < 0 or i >= ThemeNames.len: return false
  themeIndex = i
  themeName = ThemeNames[i]
  primary = ThemePrimary[i]
  secondary = ThemeSecondary[i]
  return true

proc themeIndexByName(name: string): int =
  if name.len == 0: return -1
  for i, t in ThemeNames:
    if t.toLowerAscii() == name.toLowerAscii(): return i
  return -1

var themeFile = ""

proc saveTheme() =
  if themeFile != "":
    try: writeFile(themeFile, themeName & "\n")
    except IOError: discard

proc cycleTheme() =
  discard setTheme((themeIndex + 1) mod ThemeNames.len)
  saveTheme()
  themeNoticeUntil = nowSeconds() + 3
  logEvent(&"Theme changed to: {themeName}")

proc listThemes() =
  for i in ThemeNames.low..ThemeNames.high:
    echo &"  {ThemeNames[i]:<8} {ThemePrimary[i]}████{ThemeSecondary[i]}"

# ---------------------------------------------------------------------------
# Environment overrides (captured before the defaults are applied)
# ---------------------------------------------------------------------------
let envAlertSound = getEnv("ALERT_SOUND")
let envSinkName = getEnv("SINK_NAME")
let envStateDir = getEnv("STATE_DIR")
let envMaxLogBytes = getEnv("MAX_LOG_BYTES")
let envQuotes = getEnv("QUOTES")
let envTheme = getEnv("THEME")

# ---------------------------------------------------------------------------
# Built-in defaults
# ---------------------------------------------------------------------------
let homeDir = getEnv("HOME")
var alertSound = if homeDir != "": homeDir & "/Videos/Alarm/n_alarm.mp3" else: ""
var sinkName = "OBS_Alert_Sink"
var stateDir = ""
var maxLogBytes = 1048576'i64
var fileBarWidth = 20
var nonTtyEnterTimeout = 300
var dir = "."
var quoteList: seq[string] = @DefaultQuoteList
var points = 0
var lastDate = ""

proc env(name: string): string = getEnv(name)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
proc outp(s: string) = stdout.write(s)
proc flushOut() = stdout.flushFile()

# ---------------------------------------------------------------------------
# Argument parsing & validation
# ---------------------------------------------------------------------------
var prog = "OBS.nim"
var configFile = ""
var dryRun = false
var useAlert = true
var useSink = true
var rounds = 0
var studyMin = 0
var breakMin = 0
var cliTheme = ""
var durationUnit = "minutes"
var secondsPerUnit = 60
var configTheme = ""
var configQuotes = ""
var configLoaded = ""

proc crashExit(code: int) =
  raise CrashExit(code: code)

proc helpText(): string =
  &"""Usage: {prog} [options] <rounds> <study_minutes> <break_minutes>

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
  {prog} 5 50 10           # 5 rounds, 50 min study, 10 min break
  {prog} --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  {prog} --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
"""

proc printHelp(code: int) =
  stdout.write(helpText())
  flushOut()
  quit(code)

proc usageError() =
  stderr.write(helpText())
  quit(1)

proc badNumber(v: string): bool =
  # ^[1-9][0-9]{0,3}$
  if v.len < 1 or v.len > 4: return true
  if v[0] notin {'1'..'9'}: return true
  for c in v[1..^1]:
    if c notin {'0'..'9'}: return true
  return false

proc parseIntOr(v: string, fallback: int64): int64 =
  let s = v.strip()
  if s.len == 0 or not s.allCharsInSet(Digits): return fallback
  try: result = s.parseBiggestInt()
  except ValueError: result = fallback

proc parseArgs(argv: seq[string]) =
  var positional: seq[string] = @[]
  var i = 0
  block outer:
    while i < argv.len:
      let a = argv[i]
      if a == "-h" or a == "--help":
        printHelp(0)
      elif a == "-c" or a == "--config":
        if i + 1 >= argv.len:
          stderr.write(&"Error: {a} needs a file argument\n")
          usageError()
        configFile = argv[i + 1]
        i += 2
      elif a == "-d" or a == "--dry-run":
        dryRun = true; inc i
      elif a == "-n" or a == "--no-alert":
        useAlert = false; inc i
      elif a == "-s" or a == "--no-sink":
        useSink = false; inc i
      elif a == "-t" or a == "--theme":
        if i + 1 >= argv.len:
          stderr.write(&"Error: {a} needs a theme name\n")
          usageError()
        cliTheme = argv[i + 1]
        i += 2
      elif a == "--list-themes":
        listThemes()
        flushOut()
        quit(0)
      elif a == "--":
        for j in i + 1..<argv.len: positional.add(argv[j])
        break outer
      elif a.startsWith("-"):
        stderr.write(&"Error: unknown option: {a}\n")
        usageError()
      else:
        for j in i..<argv.len: positional.add(argv[j])
        break outer

  if positional.len != 3: usageError()
  for v in positional:
    if badNumber(v): usageError()
  rounds = parseInt(positional[0])
  studyMin = parseInt(positional[1])
  breakMin = parseInt(positional[2])
  if rounds > 50:
    stderr.write("Error: rounds must be <= 50\n"); usageError()
  if studyMin > 600:
    stderr.write("Error: study minutes must be <= 600\n"); usageError()
  if breakMin > 120:
    stderr.write("Error: break minutes must be <= 120\n"); usageError()
  if dryRun:
    durationUnit = "seconds"
    secondsPerUnit = 1

# ---------------------------------------------------------------------------
# Configuration file (bash syntax, loaded by a child bash)
# ---------------------------------------------------------------------------
const ConfigDumpSh = """
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
"""

proc findConfigFile(): string =
  if configFile != "": return configFile
  let envCfg = getEnv("OBS_PANEL_CONFIG")
  if envCfg != "": return envCfg
  var xdg = getEnv("XDG_CONFIG_HOME")
  if xdg == "":
    xdg = if getEnv("HOME") != "": getEnv("HOME") & "/.config" else: "/.config"
  let xdgCfg = xdg & "/obs-study-panel/config"
  if fileExists(xdgCfg): return xdgCfg
  let localCfg = dir & "/obs-panel.conf"
  if fileExists(localCfg): return localCfg
  return ""

proc quotesToList(raw: string): seq[string] =
  var list: seq[string] = @[]
  for line0 in raw.split('\n'):
    var line = line0
    if line.len > 0 and line[line.len - 1] == '\r':
      line = line[0 .. line.len - 2]
    if line != "": list.add(line)
  return list

proc which(name: string): string =
  # command -v: first executable in PATH
  for d0 in split(getEnv("PATH"), ':'):
    if d0 == "": continue
    let full = d0 / name
    var st: posix.Stat
    try:
      if posix.stat(full, st) == 0'i32 and
          (st.st_mode and 0o111) != 0 and
          posix.SISREG(st.st_mode):
        return full
    except OSError:
      continue
  return ""

proc loadConfig(path: string) =
  # bash's [[ -r ]]: readability probe via access(2).
  if posix.access(path, 4) != 0:
    stderr.write(&"Error: config file is not readable: {path}\n")
    quit(1)
  if which("bash") == "":
    stderr.write(&"Error: bash is required to read the config file: {path}\n")
    quit(1)
  # Syntax gate: bash -n, first 3 lines of its stderr.
  var bashErr = ""
  var bashRc = 0
  block:
    var p = startProcess("bash", "", ["-n", path], nil, {poStdErrToStdOut, poUsePath})
    bashErr = p.outputStream.readAll()
    bashRc = p.waitForExit()
    p.close()
  # (poStdErrToStdOut merges stderr into the captured stdout pipe)
  if bashRc != 0:
    stderr.write(&"Error: syntax error in config file: {path}\n")
    var printed = 0
    for line in bashErr.split('\n'):
      if line.strip() == "" or printed >= 3: continue
      stderr.write(line & "\n")
      inc printed
    quit(1)

  # Seed the pre-config defaults, exactly what the reference holds while it
  # sources the file (the real environment's THEME/QUOTES pass through).
  let dumpPath = getTempDir() & "obs-panel-conf-" & $posix.getpid()
  block:
    var envTable = newStringTable()
    for k, v in envPairs(): envTable[k] = v
    envTable["ALERT_SOUND"] = alertSound
    envTable["SINK_NAME"] = sinkName
    envTable["STATE_DIR"] = ""
    envTable["MAX_LOG_BYTES"] = "1048576"
    envTable["FILE_BAR_WIDTH"] = "20"
    envTable["NON_TTY_ENTER_TIMEOUT"] = "300"
    envTable["POINTS"] = $points
    envTable["LAST_DATE"] = lastDate
    envTable["QUOTES_SEED"] = quoteList.join("\x1f")
    var p = startProcess("bash", "",
                         ["-c", ConfigDumpSh, "obs-panel", path, dumpPath],
                         envTable, {poParentStreams, poUsePath})
    let childRc = p.waitForExit()
    p.close()
    var raw = ""
    if fileExists(dumpPath):
      raw = readFile(dumpPath)
    try: removeFile(dumpPath)
    except OSError: discard
    if raw.len == 0:
      # The config called exit N before the dump was written.
      quit(if childRc != 0: childRc else: 1)

    var values = newTable[string, string]()
    var quotes: seq[string] = @[]
    let data = raw
    var idx = 0
    while idx <= data.len:
      var recEnd = -1
      for k in idx..<data.len:
        if data[k].byte == 0x1E: recEnd = k; break
      let endPos = if recEnd < 0: data.len else: recEnd
      if endPos > idx:
        var sep = -1
        for k in idx..<endPos:
          if data[k].byte == 0x1F: sep = k; break
        if sep >= 0:
          let recKey = data[idx..<sep]
          let value = data[sep + 1..<endPos]
          if recKey == "QUOTE":
            quotes.add(value)
          else:
            values[recKey] = value
      if recEnd < 0: break
      idx = endPos + 1

    alertSound = values.getOrDefault("ALERT_SOUND", alertSound)
    sinkName = values.getOrDefault("SINK_NAME", sinkName)
    stateDir = values.getOrDefault("STATE_DIR", "")
    maxLogBytes = parseIntOr(values.getOrDefault("MAX_LOG_BYTES", "1048576"), 1048576)
    fileBarWidth = int(parseIntOr(values.getOrDefault("FILE_BAR_WIDTH", "20"), 20))
    nonTtyEnterTimeout = int(parseIntOr(values.getOrDefault(
        "NON_TTY_ENTER_TIMEOUT", "300"), 300))
    configTheme = values.getOrDefault("THEME", "")
    points = int(parseIntOr(values.getOrDefault("POINTS", "0"), 0))
    lastDate = values.getOrDefault("LAST_DATE", "")
    configQuotes = values.getOrDefault("QUOTES", "")
    quoteList = quotes
    configLoaded = path

proc applyQuoteSources() =
  if envQuotes != "":
    quoteList = quotesToList(envQuotes)
  elif configQuotes != "":
    quoteList = quotesToList(configQuotes)

proc sanityKnobs() =
  if maxLogBytes <= 0: maxLogBytes = 1048576
  if fileBarWidth <= 0 or fileBarWidth > 200: fileBarWidth = 20
  if nonTtyEnterTimeout <= 0 or nonTtyEnterTimeout > 3600:
    nonTtyEnterTimeout = 300

# ---------------------------------------------------------------------------
# Paths and runtime state
# ---------------------------------------------------------------------------
var dateFile = ""
var dayFile = ""
var sessionFile = ""
var timerFile = ""
var logFile = ""
var progressFile = ""
var pointsFile = ""
var messageFile = ""
var nextFile = ""
var overlayFile = ""

var sessionText = ""
var remainingStr = "00:00:00"
var pct = 0
var nextText = ""
var messageText = ""
var lastDay = ""
var stateReady = false
var stateFinalized = false
var inCleanup = false

proc setupPaths() =
  if stateDir == "": stateDir = dir
  try:
    createDir(stateDir)
  except OSError:
    stderr.write(&"Error: cannot create state dir: {stateDir}\n")
    quit(1)
  dateFile = stateDir / "date.txt"
  dayFile = stateDir / "day.txt"
  sessionFile = stateDir / "session.txt"
  timerFile = stateDir / "timer.txt"
  logFile = stateDir / "log.txt"
  progressFile = stateDir / "progress.txt"
  pointsFile = stateDir / "points.txt"
  messageFile = stateDir / "message.txt"
  nextFile = stateDir / "next.txt"
  overlayFile = stateDir / "overlay.txt"
  themeFile = stateDir / "theme.txt"

proc selectTheme() =
  var request = cliTheme
  if request == "" and envTheme != "": request = envTheme
  if request == "" and configTheme != "": request = configTheme
  if request == "" and themeFile != "" and fileExists(themeFile):
    try:
      for line in lines(themeFile):
        request = line
        break
    except IOError: discard
  if request != "":
    let idx = themeIndexByName(request)
    if idx < 0:
      stderr.write(&"Warning: unknown theme '{request}', using {themeName}\n")
    else:
      discard setTheme(idx)

# ---------------------------------------------------------------------------
# Startup logo
# ---------------------------------------------------------------------------
proc printLogo() =
  echo primary
  echo Logo
  echo Nc
  echo primary & Bold & "     Study / Break Timer Protocol" & Nc
  echo Dim & "── live state written to date · day · session · timer · log" & Nc
  echo ""

# ---------------------------------------------------------------------------
# OBS state files
# ---------------------------------------------------------------------------
proc updateDateDay() =
  let d = now().format("yyyy-MM-dd")
  if d == lastDate: return
  lastDate = d
  lastDay = now().format("dddd")
  try:
    writeFile(dateFile, d & "\n")
    writeFile(dayFile, lastDay & "\n")
  except IOError: discard

proc syncState() =
  updateDateDay()
  publishState()

proc makeBar(filled, width: int, fill, empty: char, head: char = '\0'): string =
  result = ""
  for i in 0..<width:
    if i < filled:
      if head != '\0' and i == filled - 1:
        result.add(head)
      else:
        result.add(fill)
    else:
      result.add(empty)

proc fileBar(): string =
  makeBar(pct * fileBarWidth div 100, fileBarWidth, '#', '-')

proc publishState() =
  let bar = fileBar()
  try:
    writeFile(sessionFile, sessionText & "\n")
    writeFile(timerFile, remainingStr & "\n")
    writeFile(pointsFile, $points & "\n")
    writeFile(nextFile, nextText & "\n")
    writeFile(messageFile, messageText & "\n")
    let pctLine = &"[{bar}] {pct:3}%"
    writeFile(progressFile, pctLine & "\n")
    var overlay = &"{lastDate}  {lastDay}\n{sessionText}\n{remainingStr}\n" &
                  pctLine & "\n" & &"Pts: {points}\nNext: {nextText}"
    if messageText != "":
      overlay &= "\n" & messageText
    overlay &= "\n"
    writeFile(overlayFile, overlay)
  except IOError: discard

proc rotateLogIfNeeded() =
  try:
    if not fileExists(logFile): return
    if getFileSize(logFile) < maxLogBytes: return
    if fileExists(logFile & ".1"):
      removeFile(logFile & ".1")
    moveFile(logFile, logFile & ".1")
    writeFile(logFile, "")
  except OSError, IOError: discard

proc logEvent(msg: string) =
  rotateLogIfNeeded()
  try:
    let fh = open(logFile, fmAppend)
    defer: fh.close()
    fh.write(&"[{now().format(\"yyyy-MM-dd HH:mm:ss\")}] {msg}\n")
  except IOError: discard

# ---------------------------------------------------------------------------
# Audio alerts
# ---------------------------------------------------------------------------
proc sinkIsReady(): bool =
  if which("pactl") == "": return false
  var p = startProcess("pactl", "", ["list", "short", "sinks"], nil,
                       {poStdErrToStdOut, poUsePath})
  let text = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0: return false
  for line in text.split('\n'):
    let fields = line.split(Whitespace)
    if fields.len > 1 and fields[1] == sinkName: return true
  return false

proc setupAudioSink() =
  if not useSink: return
  if which("pactl") == "": return
  if sinkIsReady(): return
  var p = startProcess("pactl", "",
      ["load-module", "module-null-sink", "sink_name=" & sinkName,
       "sink_properties=device.description=" & sinkName], nil,
      {poStdErrToStdOut, poUsePath})
  discard p.waitForExit()
  p.close()

var alertProcess: osproc.Process = nil

proc stopAlert() =
  if alertProcess != nil:
    try: alertProcess.terminate()
    except OSError: discard
    alertProcess.close()
    alertProcess = nil

proc playAlert() =
  if not useAlert: return
  stopAlert()   # never let two alarms overlap
  if alertSound == "" or not fileExists(alertSound):
    echo Dim & "(alert file not found: " &
      (if alertSound != "": alertSound else: "none") & ")" & Nc
    return

  var player: seq[string]
  if which("mpv") != "": player = @["mpv", "--no-video", "--volume=70"]
  elif which("paplay") != "": player = @["paplay"]
  elif which("ffplay") != "": player = @["ffplay", "-nodisp", "-autoexit"]
  elif which("cvlc") != "":
    player = @["cvlc", "--play-and-exit", "--no-video", "--volume=70"]
  else:
    echo Dim & "(no audio player found - install mpv / paplay / ffplay)" & Nc
    return

  if useSink and not sinkIsReady():
    setupAudioSink()

  let onSink = useSink and sinkIsReady()
  if onSink:
    var envTable = newStringTable()
    for k, v in envPairs(): envTable[k] = v
    envTable["PULSE_SINK"] = sinkName
    alertProcess = startProcess(player[0], "", player[1..^1] & alertSound,
                                envTable, {poStdErrToStdOut, poUsePath})
    echo Dim & "-> alert on OBS sink (" & sinkName & ")" & Nc
  else:
    alertProcess = startProcess(player[0], "", player[1..^1] & alertSound,
                                nil, {poStdErrToStdOut, poUsePath})
    echo secondary & "-> alert on default device (OBS sink unavailable)" & Nc

# ---------------------------------------------------------------------------
# Keyboard input
# ---------------------------------------------------------------------------
var stdinIsTty = false
var termSaved: Termios
var termSavedValid = false
var key = ""
var keyRead = false

proc setupTerminal() =
  stdinIsTty = posix.isatty(0) == 1
  if not stdinIsTty: return
  var t: Termios
  if tcgetattr(0.cint, t.addr) == 0.cint:
    termSaved = t
    termSavedValid = true
    # cbreak like the reference's `read -s`: echo and canonical mode off,
    # ISIG stays on so Ctrl+C still generates SIGINT.
    t.c_lflag = t.c_lflag and not (ICANON or ECHO)
    t.c_cc[VMIN.int] = 1.cuchar
    t.c_cc[VTIME.int] = 0.cuchar
    discard tcsetattr(0.cint, TCSAFLUSH, t.addr)

proc restoreTerminal() =
  if termSavedValid:
    discard tcsetattr(0.cint, TCSADRAIN, termSaved.addr)
    termSavedValid = false

proc waitKey(timeoutSec: float) =
  key = ""
  keyRead = false
  if not stdinIsTty:
    sleepMs(int(timeoutSec * 1000))
    return
  let b = readByteTimeout(int(timeoutSec * 1000))
  if b < 0: return
  keyRead = true
  if b == 27:
    key = ""
    let nxt = readByteTimeout(300)
    if nxt == ord('t') or nxt == ord('T'): key = "alt-t"
  else:
    key = $chr(b)

proc discardPendingInput() =
  if not stdinIsTty: return
  while true:
    let b = readByteTimeout(10)
    if b < 0: return

proc waitForEnter() =
  if stdinIsTty:
    while true:
      let b = readByteTimeout(1000)
      if b == -1:
        updateDateDay()
      elif b == -2 or b == ord('\n'):
        return
  # Not a terminal: bounded wait, 5 s slices.
  var waited = 0
  while waited < nonTtyEnterTimeout:
    let sliceEnd = nowMs() + 5000
    block slice:
      while true:
        checkSignal()
        let left = sliceEnd - nowMs()
        if left <= 0: break slice
        if not pollReadable(int(left)): break slice
        var buf: array[4096, uint8]
        let n = posix.read(0, addr buf, 4096)
        if n <= 0: return   # EOF
        for i in 0..<n:
          if buf[i] == ord('\n'): return
    waited += 5

# ---------------------------------------------------------------------------
# Status / progress UI
# ---------------------------------------------------------------------------
const TermBarWidth = 24
const BoxInner = 62

proc phaseColor(label: string): string =
  if label == "STUDY": primary else: secondary

proc drawStatus(label: string, round, totalRounds, elapsed, total: int,
                paused: bool) =
  var filled = 0
  if total > 0: filled = elapsed * TermBarWidth div total
  if filled > TermBarWidth: filled = TermBarWidth
  let bar = makeBar(filled, TermBarWidth, '=', ' ', '>')
  let color = phaseColor(label)
  var flag = ""
  if paused:
    flag = primary & " PAUSED" & Nc
  if nowSeconds() < themeNoticeUntil:
    flag &= "  " & Dim & "Theme: " & themeName & Nc
  outp("\r\e[K")
  outp(&"{Bold}{color}{label:<6}{Nc} [{round}/{totalRounds}] " &
       &"{color}[{bar}]{Nc} {pct:3}%  {remainingStr}  " &
       &"{primary}Pts:{points}{Nc}{flag}")
  flushOut()

proc boxRow(color, plain, styled: string) =
  var pad = BoxInner - plain.len
  if pad < 0: pad = 0
  echo color & "║" & styled & spaces(pad) & color & "║" & Nc

proc durationLabel(n: int): string =
  if n == 1:
    return if durationUnit == "seconds": "1 second" else: "1 minute"
  return $n & " " & durationUnit

proc roundsLabel(n: int): string =
  if n == 1: "1 round" else: $n & " rounds"

proc phaseHeader(label: string, round, total, minutes: int, subtitle: string) =
  let sub = if subtitle.len > BoxInner - 4: subtitle[0..(BoxInner - 5)] else: subtitle
  let color = phaseColor(label)
  let bar = repeat("═", BoxInner)
  let info = &"{label}  ·  Round {round} / {total}  ·  {durationLabel(minutes)}"
  echo ""
  echo color & "╔" & bar & "╗" & Nc
  boxRow(color, "  " & info,
    "  " & Bold & label & Nc & color & "  ·  Round " & $round & " / " & $total &
    "  ·  " & durationLabel(minutes))
  boxRow(color, "  " & sub, "  " & Dim & sub & Nc & color)
  if stdinIsTty:
    let keys = "  p pause  ·  s skip  ·  q quit  ·  Alt+T theme"
    boxRow(color, keys, Dim & keys & Nc & color)
  echo color & "╚" & bar & "╝" & Nc
  echo ""

proc showCompletion(phase: string, round, totalRounds: int,
                    nextPhase: string, skipped: bool) =
  const width = 60
  let line = repeat("=", width)
  let title = if skipped: "PHASE SKIPPED"
              elif phase == "STUDY": "STUDY SESSION COMPLETE"
              else: "BREAK COMPLETE"
  let color = phaseColor(phase)
  echo ""
  echo color & line & Nc
  echo color & spaces((width + title.len) div 2) & title & Nc
  echo color & line & Nc
  echo ""
  echo &"  Round:   {Bold}{round}{Nc} / {totalRounds}"
  echo &"  Points:  {primary}{points}{Nc}"
  echo ""
  if nextPhase == "None":
    echo &"  Next:    {Dim}Session complete{Nc}"
  else:
    echo &"  Next:    {Bold}{nextPhase}{Nc}"
  echo ""
  outp("  " & primary & "Press Enter to continue..." & Nc)
  flushOut()

# ---------------------------------------------------------------------------
# Phase runner
# ---------------------------------------------------------------------------
var phaseLabel = ""
var phaseSubtitle = ""
var phaseNext = ""
var phaseTotal = 0
var phaseElapsed = 0
var phasePaused = false
var phaseSkipped = false
var phaseStart = 0'i64
var phasePausedTotal = 0'i64
var phasePauseAt = 0'i64

proc fmtHms(total: int): string =
  &"{total div 3600:02}:{(total mod 3600) div 60:02}:{total mod 60:02}"

proc phasePrepare(ptype: string, minutes, round, totalRounds: int) =
  if ptype == "study":
    phaseLabel = "STUDY"
    if quoteList.len > 0:
      phaseSubtitle = quoteList[rand(quoteList.len - 1)]
    else:
      phaseSubtitle = "Stay focused."
  else:
    phaseLabel = "BREAK"
    phaseSubtitle = "Relax and recharge."
  if ptype == "study":
    if round < totalRounds:
      phaseNext = "Break (" & durationLabel(breakMin) & ")"
    else:
      phaseNext = "None"
  else:
    phaseNext = "Study (" & durationLabel(studyMin) & ")"
  phaseTotal = minutes * secondsPerUnit
  phaseElapsed = 0
  phasePaused = false
  phaseSkipped = false
  phaseStart = nowSeconds()
  phasePausedTotal = 0
  phasePauseAt = 0
  sessionText = &"{phaseLabel} {round}/{totalRounds}"
  remainingStr = fmtHms(phaseTotal)
  pct = 0
  nextText = if phaseNext == "None": "Session complete" else: phaseNext
  messageText = phaseSubtitle
  logEvent(&"Start: {phaseLabel} {round}/{totalRounds} ({durationLabel(minutes)})")
  phaseHeader(phaseLabel, round, totalRounds, minutes, phaseSubtitle)
  syncState()

proc phaseHandleKey(round, totalRounds: int) =
  if key == "p" or key == "P" or key == " ":
    if phasePaused:
      phasePausedTotal += nowSeconds() - phasePauseAt
      phasePaused = false
      logEvent(&"Resumed: {phaseLabel} {round}/{totalRounds}")
    else:
      phasePaused = true
      phasePauseAt = nowSeconds()
      logEvent(&"Paused: {phaseLabel} {round}/{totalRounds}")
  elif key == "s" or key == "S":
    phaseSkipped = true
    logEvent(&"Skipped: {phaseLabel} {round}/{totalRounds}")
  elif key == "q" or key == "Q":
    logEvent("Quit requested by user")
    cleanup(0)
  elif key == "alt-t":
    cycleTheme()

proc phaseCount(round, totalRounds: int) =
  while phaseElapsed < phaseTotal:
    var remaining = phaseTotal - phaseElapsed
    if remaining < 0: remaining = 0
    remainingStr = fmtHms(remaining)
    pct = if phaseTotal > 0: phaseElapsed * 100 div phaseTotal else: 0
    if pct > 100: pct = 100
    sessionText = &"{phaseLabel} {round}/{totalRounds}"
    if phasePaused: sessionText &= " (PAUSED)"
    syncState()
    drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal,
               phasePaused)
    waitKey(1.0)
    if keyRead:
      phaseHandleKey(round, totalRounds)
      if phaseSkipped: break
    # CRASH-INJECT-POINT
    if not phasePaused:
      phaseElapsed = int(nowSeconds() - phaseStart - phasePausedTotal)

proc phaseFinish(round, totalRounds: int) =
  if phaseSkipped:
    sessionText = &"{phaseLabel} {round}/{totalRounds} (SKIPPED)"
  else:
    pct = 100
    inc points
  remainingStr = "00:00:00"
  syncState()
  drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal, false)
  outp("\n")
  logEvent(&"End: {phaseLabel} {round}/{totalRounds}")
  playAlert()
  discardPendingInput()
  showCompletion(phaseLabel, round, totalRounds, phaseNext, phaseSkipped)
  waitForEnter()
  stopAlert()
  outp("\n")

proc runPhase(ptype: string, minutes, round, totalRounds: int) =
  phasePrepare(ptype, minutes, round, totalRounds)
  phaseCount(round, totalRounds)
  phaseFinish(round, totalRounds)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
proc resetStateFiles() =
  sessionText = "stopped"
  remainingStr = "00:00:00"
  pct = 0
  nextText = ""
  syncState()

proc cleanup(code: int) =
  if inCleanup: return
  inCleanup = true
  stateFinalized = true
  try: stopAlert()
  except: discard
  try: resetStateFiles()
  except: discard
  try: logEvent("Protocol stopped manually")
  except: discard
  try:
    outp("\n")
    echo secondary & Bold & "Interrupted." & Nc & " " & Dim &
      "State files reset to stopped." & Nc
  except: discard
  restoreTerminal()
  cexit(code.cint)

proc onUnexpectedDeath(rc: int) =
  if not stateReady: return
  if stateFinalized: return
  stateFinalized = true
  try: stopAlert()
  except: discard
  try: resetStateFiles()
  except: discard
  try: logEvent(&"Protocol ended unexpectedly (exit {rc})")
  except: discard

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
proc finalizeSession() =
  sessionText = "session complete"
  remainingStr = "00:00:00"
  pct = 100
  nextText = ""
  syncState()
  stateFinalized = true
  logEvent(&"Protocol complete - total points: {points}")

proc finalBanner() =
  const bannerWidth = 60
  const title = "ALL SESSIONS COMPLETE"
  const inner = bannerWidth - 2
  let pad = (inner - title.len) div 2
  let border = repeat("#", bannerWidth)
  echo ""
  echo primary & border & Nc
  echo primary & "#" & Nc & spaces(pad) & Bold & title &
    spaces(inner - pad - title.len) & Nc & "#" & primary
  echo primary & border & Nc
  echo ""
  echo &"  {Bold}Total Rounds:{Nc}  {primary}{rounds}{Nc}"
  echo &"  {Bold}Total Points:{Nc} {primary}{points}{Nc}"
  echo ""
  echo primary & Bold & "Great work!" & Nc & " " & Dim & "Exiting." & Nc

proc runAll() =
  let argv = commandLineParams()
  startEpoch = epochTime()
  randomize()
  parseArgs(argv)

  let cfg = findConfigFile()
  if cfg != "": loadConfig(cfg)

  # Environment variables beat the config file.
  if envAlertSound != "": alertSound = envAlertSound
  if envSinkName != "": sinkName = envSinkName
  if envStateDir != "": stateDir = envStateDir
  if envMaxLogBytes != "":
    let v = parseIntOr(envMaxLogBytes, -1)
    if v > 0: maxLogBytes = v

  applyQuoteSources()
  sanityKnobs()
  setupPaths()
  selectTheme()
  installSignalHandlers()
  setupTerminal()

  printLogo()
  setupAudioSink()
  updateDateDay()
  stateReady = true
  logEvent(&"Starting new study protocol: {roundsLabel(rounds)}, " &
    &"{durationLabel(studyMin)} study, {durationLabel(breakMin)} break")

  echo &"{secondary}Protocol:{Nc} {Bold}{roundsLabel(rounds)}{Nc}  {Dim}|{Nc}  " &
    &"{Bold}{durationLabel(studyMin)}{Nc} study  {Dim}|{Nc}  " &
    &"{Bold}{durationLabel(breakMin)}{Nc} break  {Dim}|{Nc}  " &
    &"{Bold}Theme: {themeName}{Nc}"
  if configLoaded != "":
    echo Dim & "Config: " & configLoaded & Nc
  echo ""

  for round in 1..rounds:
    runPhase("study", studyMin, round, rounds)
    if round < rounds:
      runPhase("break", breakMin, round, rounds)

  finalizeSession()
  finalBanner()
  restoreTerminal()
  quit(0)

when isMainModule:
  try:
    runAll()
  except CrashExit as e:
    onUnexpectedDeath(e.code)
    restoreTerminal()
    cexit(e.code.cint)
  except CatchableError as e:
    stderr.write("OBS.nim: internal error: " & e.msg & "\n")
    onUnexpectedDeath(1)
    restoreTerminal()
    quit(1)
