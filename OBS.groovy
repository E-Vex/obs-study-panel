// OBS.groovy - Study/break timer protocol (Groovy port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: Groovy 4.x on Java 17+, bash (to load the bash-syntax config
// file).
//
// Usage: groovy OBS.groovy [options] <rounds> <study_minutes> <break_minutes>
// Stop:  Ctrl+C, or press 'q' while a phase is running
// Theme: press Alt+T while a phase is running (see --list-themes)
//
// NOTE: uses sun.misc.Signal for exact INT/TERM/HUP exit codes (130/143/129).
// The JDK prints an "internal proprietary API" warning; still functional on
// JDK 21.

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

// ---------------------------------------------------------------------------
// Color themes
// ---------------------------------------------------------------------------
THEMES = [
    ['Purple', '\u001b[1;35m', '\u001b[0;35m'],
    ['Ocean', '\u001b[1;36m', '\u001b[0;34m'],
    ['Forest', '\u001b[1;32m', '\u001b[0;32m'],
    ['Sunset', '\u001b[1;33m', '\u001b[0;31m'],
    ['Rose', '\u001b[1;95m', '\u001b[0;31m'],
    ['Gold', '\u001b[1;93m', '\u001b[0;33m'],
    ['Mono', '\u001b[1;37m', '\u001b[0;37m'],
    ['Ice', '\u001b[1;96m', '\u001b[0;36m'],
    ['Ember', '\u001b[1;91m', '\u001b[0;31m'],
    ['Neon', '\u001b[1;92m', '\u001b[0;96m'],
    ['Cobalt', '\u001b[1;34m', '\u001b[0;36m'],
    ['Cherry', '\u001b[1;91m', '\u001b[0;35m'],
]
BOLD = '\u001b[1m'
DIM = '\u001b[2m'
NC = '\u001b[0m'

LOGO = ''' /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \\  $$$$/
| $$__/|______/ \\  $$ $$/ | $$__/     >$$  $$
| $$             \\  $$$/  | $$       /$$/\\  $$
| $$$$$$$$        \\  $/   | $$$$$$$$| $$  \\ $$
|________/         \\_/    |________/|__/  |__/'''

DEFAULT_QUOTE_LIST = [
    'Focused effort beats scattered hours',
    'Every round finished is progress made',
    'Consistency beats intensity',
    'Start now, figure out the rest along the way',
    'A short break now means sharper focus next round',
]

// ---------------------------------------------------------------------------
// Mutable program state (mirrors the reference's global variables)
// ---------------------------------------------------------------------------
prog = 'OBS'          // class/script basename of the invocation
START_NANO = System.nanoTime()

primary = THEMES[0][1]
secondary = THEMES[0][2]
themeName = THEMES[0][0]
themeIndex = 0
themeNoticeUntil = 0L

envAlertSound = System.getenv('ALERT_SOUND') ?: ''
envSinkName = System.getenv('SINK_NAME') ?: ''
envStateDir = System.getenv('STATE_DIR') ?: ''
envMaxLogBytes = System.getenv('MAX_LOG_BYTES') ?: ''
envQuotes = System.getenv('QUOTES') ?: ''
envTheme = System.getenv('THEME') ?: ''

dir = Paths.get('.').toAbsolutePath()
alertSound = (System.getenv('HOME') ?: '') ?
        System.getenv('HOME') + '/Videos/Alarm/n_alarm.mp3' : ''
sinkName = 'OBS_Alert_Sink'
stateDir = ''
maxLogBytes = 1048576L
fileBarWidth = 20L
nonTtyEnterTimeout = 300L
alertPid = 0L
quoteList = new ArrayList<>(DEFAULT_QUOTE_LIST)
points = 0L
lastDate = ''

configFile = ''
dryRun = false
useAlert = true
useSink = true
rounds = 0
studyMin = 0
breakMin = 0
cliTheme = ''
durationUnit = 'minutes'
secondsPerUnit = 60
configTheme = ''
configQuotes = ''
configLoaded = ''

dateFile = dayFile = sessionFile = timerFile = logFile = null
progressFile = pointsFile = messageFile = nextFile = null
overlayFile = themeFile = null

sessionText = ''
remainingStr = '00:00:00'
pct = 0
nextText = ''
messageText = ''
lastDay = ''
stateReady = false
stateFinalized = false
inCleanup = false

phaseLabel = ''
phaseSubtitle = ''
phaseNext = ''
phaseTotal = 0L
phaseElapsed = 0L
phasePaused = false
phaseSkipped = false
phaseStart = 0L
phasePausedTotal = 0L
phasePauseAt = 0L

stdinIsTty = false
savedTermSettings = null
key = ''
keyRead = false

TERM_BAR_WIDTH = 24
BOX_INNER = 62

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
def nowSeconds() { (long) ((System.nanoTime() - START_NANO) / 1_000_000_000L) }

def out(String s) { print s }

def setTheme(int i) {
    if (i < 0 || i >= THEMES.size()) return
    themeIndex = i
    themeName = THEMES[i][0]
    primary = THEMES[i][1]
    secondary = THEMES[i][2]
}

def themeIndexOf(String want) {
    if (!want) return -1
    def found = THEMES.findIndexOf { it[0].equalsIgnoreCase(want) }
    return found
}

def saveTheme() {
    if (themeFile != null) {
        try { Files.write(themeFile, (themeName + '\n').getBytes('UTF-8')) }
        catch (IOException ignored) { }
    }
}

def cycleTheme() {
    setTheme((themeIndex + 1) % THEMES.size())
    saveTheme()
    themeNoticeUntil = nowSeconds() + 3
    logEvent('Theme changed to: ' + themeName)
}

def printThemeList() {
    THEMES.each { t ->
        out(String.format('  %-8s %s%s%s%n', t[0], t[1],
                '\u2588\u2588\u2588\u2588', t[2]))
    }
}

String fmtHms(long total) {
    String.format('%02d:%02d:%02d', (long) (total / 3600),
            (long) ((total % 3600) / 60), (long) (total % 60))
}

String makeBar(long filled, long width, String fill, String empty, String head) {
    def bar = new StringBuilder()
    for (long i = 0; i < width; i++) {
        if (i < filled) {
            bar.append(head && i == filled - 1 ? head : fill)
        } else {
            bar.append(empty)
        }
    }
    bar.toString()
}

String which(String cmd) {
    def pathEnv = System.getenv('PATH')
    if (!pathEnv) return null
    for (p in pathEnv.split(File.pathSeparator)) {
        if (!p) continue
        def f = new File(p, cmd)
        if (f.canExecute()) return f.path
    }
    null
}

// ---------------------------------------------------------------------------
// Help and argument parsing
// ---------------------------------------------------------------------------
String helpText() {
    String.format(
        'Usage: %s [options] <rounds> <study_minutes> <break_minutes>%n%n' +
        'Runs a Pomodoro-style study/break loop and writes the live state to text%n' +
        'files that OBS Studio can display as "Text (read from file)" sources.%n%n' +
        'Options:%n' +
        '  -h, --help          Show this help and exit%n' +
        '  -c, --config FILE   Load settings from FILE (bash syntax)%n' +
        '  -d, --dry-run       Treat the durations as seconds (fast testing)%n' +
        '  -n, --no-alert      Disable the audio alert%n' +
        '  -s, --no-sink       Don\u0027t create or use the OBS virtual audio sink%n' +
        '  -t, --theme NAME    Use a color theme (see --list-themes)%n' +
        '      --list-themes   Show the available color themes and exit%n%n' +
        'Arguments:%n' +
        '  rounds             1-50   number of study rounds%n' +
        '  study_minutes      1-600  length of a study phase%n' +
        '  break_minutes      1-120  length of a break phase%n%n' +
        'Examples:%n' +
        '  %s 5 50 10           # 5 rounds, 50 min study, 10 min break%n' +
        '  %s --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break%n' +
        '  %s --theme Ocean 5 50 10%n%n' +
        'Keys (while a phase is running):%n' +
        '  p / space   pause and resume the current phase%n' +
        '  s           skip the rest of the current phase%n' +
        '  q           quit the session%n' +
        '  Alt+T       switch to the next color theme%n%n' +
        'Environment overrides:%n' +
        '  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME%n%n' +
        'Config file (first one that exists):%n' +
        '  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config%n',
        prog, prog, prog, prog)
}

def printHelp(int code, boolean toStderr) {
    if (toStderr) System.err.print(helpText())
    else System.out.print(helpText())
    System.exit(code)
}

def usageError() { printHelp(1, true) }

boolean validNumber(String s) {
    if (!s || s.length() > 4 || s[0] < (char) '1' || s[0] > (char) '9') return false
    s.every { it >= (char) '0' && it <= (char) '9' }
}

def parseArgs(List<String> argv) {
    def rest = new ArrayDeque<>(argv)
    def pos = []
    while (!rest.isEmpty()) {
        String a = rest.peek()
        if (a == '-h' || a == '--help') {
            printHelp(0, false)
        } else if (a == '-c' || a == '--config') {
            if (rest.size() < 2) {
                System.err.println('Error: ' + a + ' needs a file argument')
                usageError()
            }
            rest.remove()
            configFile = rest.remove()
        } else if (a == '-d' || a == '--dry-run') {
            dryRun = true
            rest.remove()
        } else if (a == '-n' || a == '--no-alert') {
            useAlert = false
            rest.remove()
        } else if (a == '-s' || a == '--no-sink') {
            useSink = false
            rest.remove()
        } else if (a == '-t' || a == '--theme') {
            if (rest.size() < 2) {
                System.err.println('Error: ' + a + ' needs a theme name')
                usageError()
            }
            rest.remove()
            cliTheme = rest.remove()
        } else if (a == '--list-themes') {
            printThemeList()
            System.exit(0)
        } else if (a == '--') {
            rest.remove()
            pos.addAll(rest)
            rest.clear()
        } else if (a.startsWith('-')) {
            System.err.println('Error: unknown option: ' + a)
            usageError()
        } else {
            pos.addAll(rest)
            rest.clear()
        }
    }
    if (pos.size() != 3) usageError()
    pos.each { if (!validNumber(it)) usageError() }
    rounds = Integer.parseInt(pos[0])
    studyMin = Integer.parseInt(pos[1])
    breakMin = Integer.parseInt(pos[2])
    if (rounds > 50) { System.err.println('Error: rounds must be <= 50'); usageError() }
    if (studyMin > 600) { System.err.println('Error: study minutes must be <= 600'); usageError() }
    if (breakMin > 120) { System.err.println('Error: break minutes must be <= 120'); usageError() }
    if (dryRun) {
        durationUnit = 'seconds'
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
CONFIG_DUMP_SH = '''set -u
IFS=$'\\037' read -r -a QUOTE_LIST <<< "${QUOTES_SEED-}"
unset QUOTES_SEED
source "$1" || true
{
  d() { printf '%s\\037%s\\036' "$1" "${2-}"; }
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
'''

String findConfigFile() {
    if (configFile) return configFile
    String p = System.getenv('OBS_PANEL_CONFIG')
    if (p) return p
    def xdgBase = System.getenv('XDG_CONFIG_HOME') ?:
            ((System.getenv('HOME') ?: '') + '/.config')
    def xdg = Paths.get(xdgBase, 'obs-study-panel', 'config')
    if (Files.isRegularFile(xdg)) return xdg.toString()
    def local = dir.resolve('obs-panel.conf')
    if (Files.isRegularFile(local)) return local.toString()
    null
}

def quotesToList(String raw) {
    quoteList.clear()
    raw.split('\n', -1).each { String line ->
        while (line.endsWith('\r')) line = line.substring(0, line.length() - 1)
        if (line) quoteList.add(line)
    }
}

long parseLongOr(String v, long dflt) {
    try { return Long.parseLong(v.trim()) } catch (Exception ignored) { return dflt }
}

def loadConfig(String path) {
    if (!Files.isReadable(Paths.get(path))) {
        System.err.println('Error: config file is not readable: ' + path)
        System.exit(1)
    }
    // Syntax check up front, exactly like the reference.
    if (which('bash') == null) {
        System.err.println('Error: bash is required to read the config file: ' + path)
        System.exit(1)
    }
    def chk = new ProcessBuilder(['bash', '-n', path]).redirectErrorStream(true).start()
    String chkOut = new String(chk.getInputStream().readAllBytes(), 'UTF-8')
    int chkRc = chk.waitFor()
    if (chkRc != 0) {
        System.err.println('Error: syntax error in config file: ' + path)
        def shown = 0
        chkOut.split('\n').each { String l ->
            if (!l.trim()) return
            System.err.println(l)
            shown++
            if (shown >= 3) return
        }
        System.exit(1)
    }

    Path dumpPath = Files.createTempFile('obs-panel-conf-', '')
    def pb = new ProcessBuilder(['bash', '-c', CONFIG_DUMP_SH, 'obs-panel',
                                 path, dumpPath.toString()])
    def envMap = new HashMap<>(System.getenv())
    envMap.put('ALERT_SOUND', alertSound)
    envMap.put('SINK_NAME', sinkName)
    envMap.put('STATE_DIR', '')
    envMap.put('MAX_LOG_BYTES', '1048576')
    envMap.put('FILE_BAR_WIDTH', '20')
    envMap.put('NON_TTY_ENTER_TIMEOUT', '300')
    envMap.put('POINTS', Long.toString(points))
    envMap.put('LAST_DATE', lastDate)
    envMap.put('QUOTES_SEED', quoteList.join('\u001f'))
    pb.environment().clear()
    pb.environment().putAll(envMap)
    pb.inheritIO()
    int cRc = 1
    try { cRc = pb.start().waitFor() } catch (Exception ignored) { }

    String raw = ''
    try {
        raw = new String(Files.readAllBytes(dumpPath), 'UTF-8')
        Files.deleteIfExists(dumpPath)
    } catch (IOException ignored) { }

    if (!raw) {
        // The config called exit N before the dump was written.
        System.exit(cRc != 0 ? cRc : 1)
    }

    def values = [:]
    def quotes = []
    raw.split('\u001e', -1).each { String record ->
        if (!record) return
        int i = record.indexOf('\u001f' as String)
        if (i < 0) return
        String k = record.substring(0, i)
        String v = record.substring(i + 1)
        if (k == 'QUOTE') quotes.add(v)
        else values[k] = v
    }

    if (values.containsKey('ALERT_SOUND')) alertSound = values['ALERT_SOUND']
    if (values.containsKey('SINK_NAME')) sinkName = values['SINK_NAME']
    stateDir = values.containsKey('STATE_DIR') ? values['STATE_DIR'] : ''
    maxLogBytes = parseLongOr(values.containsKey('MAX_LOG_BYTES') ?
            values['MAX_LOG_BYTES'] : null, 1048576L)
    if (maxLogBytes <= 0) maxLogBytes = 1048576L
    fileBarWidth = parseLongOr(values.containsKey('FILE_BAR_WIDTH') ?
            values['FILE_BAR_WIDTH'] : null, 20L)
    if (fileBarWidth <= 0 || fileBarWidth > 200) fileBarWidth = 20L
    nonTtyEnterTimeout = parseLongOr(values.containsKey('NON_TTY_ENTER_TIMEOUT') ?
            values['NON_TTY_ENTER_TIMEOUT'] : null, 300L)
    if (nonTtyEnterTimeout <= 0 || nonTtyEnterTimeout > 3600) nonTtyEnterTimeout = 300L
    configTheme = values.containsKey('THEME') ? values['THEME'] : ''
    points = parseLongOr(values.containsKey('POINTS') ? values['POINTS'] : null, 0L)
    lastDate = values.containsKey('LAST_DATE') ? values['LAST_DATE'] : ''
    configQuotes = values.containsKey('QUOTES') ? values['QUOTES'] : ''
    quoteList.clear()
    quoteList.addAll(quotes)
    configLoaded = path
}

def applyQuoteSources() {
    if (envQuotes) quotesToList(envQuotes)
    else if (configQuotes) quotesToList(configQuotes)
}

// ---------------------------------------------------------------------------
// Paths and theme selection
// ---------------------------------------------------------------------------

def setupPaths() {
    if (!stateDir) stateDir = dir.toString()
    try {
        Files.createDirectories(Paths.get(stateDir))
    } catch (IOException e) {
        System.err.println('Error: cannot create state dir: ' + stateDir)
        System.exit(1)
    }
    def base = Paths.get(stateDir)
    dateFile = base.resolve('date.txt')
    dayFile = base.resolve('day.txt')
    sessionFile = base.resolve('session.txt')
    timerFile = base.resolve('timer.txt')
    logFile = base.resolve('log.txt')
    progressFile = base.resolve('progress.txt')
    pointsFile = base.resolve('points.txt')
    messageFile = base.resolve('message.txt')
    nextFile = base.resolve('next.txt')
    overlayFile = base.resolve('overlay.txt')
    themeFile = base.resolve('theme.txt')
}

def selectTheme() {
    String request = cliTheme ?: (envTheme ?: (configTheme ?: ''))
    if (!request && themeFile != null && Files.isRegularFile(themeFile)) {
        try {
            def lines = Files.readAllLines(themeFile, java.nio.charset.StandardCharsets.UTF_8)
            if (!lines.isEmpty()) request = lines.get(0)
        } catch (IOException ignored) { }
    }
    if (request) {
        int idx = themeIndexOf(request)
        if (idx < 0) {
            System.err.println("Warning: unknown theme '${request}', using ${themeName}")
        } else {
            setTheme(idx)
        }
    }
}

// ---------------------------------------------------------------------------
// OBS state files
// ---------------------------------------------------------------------------

def writeStateFile(Path path, String text) {
    try { Files.write(path, (text + '\n').getBytes('UTF-8')) }
    catch (IOException ignored) { }
}

def updateDateDay() {
    def now = LocalDateTime.now()
    String d = now.format(DateTimeFormatter.ofPattern('yyyy-MM-dd'))
    if (d == lastDate) return
    lastDate = d
    lastDay = now.getDayOfWeek().getDisplayName(TextStyle.FULL, Locale.ENGLISH)
    writeStateFile(dateFile, d)
    writeStateFile(dayFile, lastDay)
}

def syncState() {
    updateDateDay()
    publishState()
}

def publishState() {
    long filled = (long) (pct * fileBarWidth / 100)
    String bar = makeBar(filled, fileBarWidth, '#', '-', null)
    String pctS = String.format('%3d%%', pct)

    writeStateFile(sessionFile, sessionText)
    writeStateFile(timerFile, remainingStr)
    writeStateFile(pointsFile, Long.toString(points))
    writeStateFile(nextFile, nextText)
    writeStateFile(messageFile, messageText)
    writeStateFile(progressFile, '[' + bar + '] ' + pctS)

    def sb = new StringBuilder()
    sb.append(lastDate).append(' ').append(lastDay).append('\n')
    sb.append(sessionText).append('\n')
    sb.append(remainingStr).append('\n')
    sb.append('[').append(bar).append('] ').append(pctS).append('\n')
    sb.append('Pts: ').append(points).append('\n')
    sb.append('Next: ').append(nextText).append('\n')
    if (messageText) sb.append(messageText).append('\n')
    try { Files.write(overlayFile, sb.toString().getBytes('UTF-8')) }
    catch (IOException ignored) { }
}

def rotateLogIfNeeded() {
    try {
        if (Files.isRegularFile(logFile) && Files.size(logFile) >= maxLogBytes) {
            Files.move(logFile, logFile.resolveSibling('log.txt.1'),
                    StandardCopyOption.REPLACE_EXISTING)
            Files.write(logFile, new byte[0])
        }
    } catch (IOException ignored) { }
}

def logEvent(String msg) {
    rotateLogIfNeeded()
    try {
        Files.write(logFile, ('[' +
                LocalDateTime.now().format(
                        DateTimeFormatter.ofPattern('yyyy-MM-dd HH:mm:ss')) +
                '] ' + msg + '\n').getBytes('UTF-8'),
                StandardOpenOption.APPEND, StandardOpenOption.CREATE)
    } catch (IOException ignored) { }
}

// ---------------------------------------------------------------------------
// Audio alerts
// ---------------------------------------------------------------------------

boolean sinkIsReady() {
    if (which('pactl') == null) return false
    try {
        def p = new ProcessBuilder(['pactl', 'list', 'short', 'sinks']).start()
        boolean found = false
        def r = new BufferedReader(new InputStreamReader(p.getInputStream(), 'UTF-8'))
        String line
        while ((line = r.readLine()) != null) {
            def fields = line.trim().split('\\s+')
            if (fields.length > 1 && fields[1] == sinkName) {
                found = true
                break
            }
        }
        p.waitFor()
        return found
    } catch (Exception ignored) {
        return false
    }
}

def setupAudioSink() {
    if (!useSink) return
    if (which('pactl') == null) return
    if (sinkIsReady()) return
    try {
        new ProcessBuilder(['pactl', 'load-module', 'module-null-sink',
                            'sink_name=' + sinkName,
                            'sink_properties=device.description=' + sinkName])
                .redirectOutput(new File('/dev/null'))
                .redirectError(new File('/dev/null'))
                .start().waitFor()
    } catch (Exception ignored) { }
}

def stopAlert() {
    if (alertPid > 0) {
        try {
            new ProcessBuilder(['kill', Long.toString(alertPid)]).start().waitFor()
        } catch (Exception ignored) { }
        alertPid = 0
    }
}

def playAlert() {
    if (!useAlert) return
    stopAlert()
    boolean fileOk = alertSound && Files.isRegularFile(Paths.get(alertSound))
    if (!fileOk) {
        out(String.format('%s(alert file not found: %s)%s%n', DIM,
                alertSound ? alertSound : 'none', NC))
        return
    }

    List<String> player = null
    if (which('mpv') != null) player = ['mpv', '--no-video', '--volume=70']
    else if (which('paplay') != null) player = ['paplay']
    else if (which('ffplay') != null) player = ['ffplay', '-nodisp', '-autoexit']
    else if (which('cvlc') != null) {
        player = ['cvlc', '--play-and-exit', '--no-video', '--volume=70']
    } else {
        out(String.format('%s(no audio player found - install mpv / paplay / ffplay)%s%n',
                DIM, NC))
        return
    }

    if (useSink && !sinkIsReady()) setupAudioSink()

    try {
        def argv = new ArrayList<>(player)
        argv.add(alertSound)
        def pb = new ProcessBuilder(argv)
                .redirectOutput(new File('/dev/null'))
                .redirectError(new File('/dev/null'))
        if (useSink && sinkIsReady()) {
            pb.environment().put('PULSE_SINK', sinkName)
        }
        alertPid = pb.start().pid()
    } catch (IOException ignored) { }

    if (useSink && sinkIsReady()) {
        out(String.format('%s-> alert on OBS sink (%s)%s%n', DIM, sinkName, NC))
    } else {
        out(String.format('%s-> alert on default device (OBS sink unavailable)%s%n',
                secondary, NC))
    }
}

// ---------------------------------------------------------------------------
// Terminal handling + keyboard input (stty + reader thread + queue)
// ---------------------------------------------------------------------------
EOF_BYTE = -1
EOF_MARKER = 256
inputQueue = new LinkedBlockingQueue<Integer>()
sawEof = false

def startInputReader() {
    def t = new Thread({
        byte[] buf = new byte[256]
        try {
            while (true) {
                int n = System.in.read(buf)
                if (n < 0) {
                    inputQueue.put(EOF_MARKER)
                    return
                }
                for (int i = 0; i < n; i++) inputQueue.put((int) buf[i] & 0xff)
            }
        } catch (Exception e) {
            try { inputQueue.put(EOF_MARKER) } catch (InterruptedException ignored) { }
        }
    })
    t.daemon = true
    t.start()
}

/** One byte with a timeout (seconds): byte (0..255), EOF (-1), or -2 timeout. */
int waitByte(double timeout) {
    if (sawEof) return EOF_BYTE
    Integer b = inputQueue.poll((long) (timeout * 1e9), TimeUnit.NANOSECONDS)
    if (b == null) return -2
    if (b == EOF_MARKER) { sawEof = true; return EOF_BYTE }
    return b
}

String runSttyCapture(List<String> argv) {
    try {
        def pb = new ProcessBuilder(argv).redirectInput(ProcessBuilder.Redirect.INHERIT)
        def p = pb.start()
        String o = new String(p.getInputStream().readAllBytes(), 'UTF-8')
        p.waitFor()
        return o.trim()
    } catch (Exception ignored) {
        return ''
    }
}

def runStty(List<String> argv) {
    try {
        new ProcessBuilder(argv)
                .redirectInput(ProcessBuilder.Redirect.INHERIT)
                .redirectOutput(new File('/dev/null'))
                .redirectError(new File('/dev/null'))
                .start().waitFor()
    } catch (Exception ignored) { }
}

boolean isattyProbe() {
    try {
        def pb = new ProcessBuilder(['sh', '-c', 'test -t 0 && echo tty || echo no'])
                .redirectInput(ProcessBuilder.Redirect.INHERIT)
        def p = pb.start()
        String line = new String(p.getInputStream().readAllBytes(), 'UTF-8').trim()
        p.waitFor()
        return line == 'tty'
    } catch (Exception ignored) {
        return System.console() != null
    }
}

def setupTerminal() {
    stdinIsTty = isattyProbe()
    if (!stdinIsTty) return
    savedTermSettings = runSttyCapture(['stty', '-g'])
    runStty(['stty', '-icanon', '-echo'])
}

def restoreTerminal() {
    if (!stdinIsTty) return
    if (savedTermSettings) runStty(['stty', savedTermSettings])
    else runStty(['stty', 'sane'])
    savedTermSettings = null
}

def waitKey(double timeout) {
    key = ''
    keyRead = false
    if (!stdinIsTty) {
        try { Thread.sleep((long) (timeout * 1000)) } catch (InterruptedException ignored) { }
        return
    }
    int b = waitByte(timeout)
    if (b < 0) return
    keyRead = true
    if (b == 0x1b) {
        int nxt = waitByte(0.3)
        if (nxt == (char) 't' || nxt == (char) 'T') key = 'alt-t'
    } else {
        key = new String([b] as byte[], 'ISO-8859-1')
    }
}

def discardPendingInput() {
    if (!stdinIsTty) return
    while (true) {
        int b = waitByte(0.01)
        if (b <= 0) return
    }
}

def waitForEnter() {
    if (stdinIsTty) {
        while (true) {
            int b = waitByte(1)
            if (b == EOF_BYTE) return
            if (b == -2) {
                updateDateDay()
                continue
            }
            if (b == (char) '\n') return
        }
    }
    long waited = 0
    while (waited < nonTtyEnterTimeout) {
        long sliceStart = System.nanoTime()
        while (true) {
            double elapsed = (System.nanoTime() - sliceStart) / 1e9
            if (elapsed >= 5.0) { waited += 5; break }
            int b = waitByte(5.0 - elapsed)
            if (b == EOF_BYTE) return
            if (b == -2) { waited += 5; break }
            if (b == (char) '\n') return
        }
    }
}

// ---------------------------------------------------------------------------
// Status / progress UI
// ---------------------------------------------------------------------------
String phaseColor(String label) { label == 'STUDY' ? primary : secondary }

String durationLabel(int n) {
    if (n == 1) return durationUnit == 'seconds' ? '1 second' : '1 minute'
    n + ' ' + durationUnit
}

String roundsLabel(int n) { n == 1 ? '1 round' : n + ' rounds' }

def drawStatus(String label, int round, int totalRounds, long elapsed, long total,
               boolean paused) {
    long filled = total > 0 ? elapsed * TERM_BAR_WIDTH / total : 0
    if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH
    String bar = makeBar(filled, TERM_BAR_WIDTH, '=', ' ', '>')
    String color = phaseColor(label)
    String flag = ''
    if (paused) flag = primary + ' PAUSED' + NC
    if (nowSeconds() < themeNoticeUntil) flag += '  ' + DIM + 'Theme: ' + themeName + NC
    out('\r\u001b[K')
    out(String.format('%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s',
            BOLD, color, label, NC, round, totalRounds,
            color, bar, NC, pct, remainingStr, primary, points, NC, flag))
}

def boxRow(String color, String plain, String styled) {
    int pad = BOX_INNER - plain.length()
    if (pad < 0) pad = 0
    out(String.format('%s\u2551%s%s%s\u2551%s%n', color, styled,
            ' ' * pad, color, NC))
}

def phaseHeader(String label, int round, int total, int minutes, String subtitle) {
    if (subtitle.length() > BOX_INNER - 4) subtitle = subtitle.substring(0, BOX_INNER - 4)
    String color = phaseColor(label)
    String bar = '\u2550' * BOX_INNER
    String dur = durationLabel(minutes)
    String info = String.format('%s  \u00b7  Round %d / %d  \u00b7  %s',
            label, round, total, dur)
    String styled1 = String.format('  %s%s%s%s  \u00b7  Round %d / %d  \u00b7  %s',
            BOLD, label, NC, color, round, total, dur)
    String styled2 = '  ' + DIM + subtitle + NC + color
    out(String.format('%n'))
    out(String.format('%s\u2554%s\u2557%s%n', color, bar, NC))
    boxRow(color, '  ' + info, styled1)
    boxRow(color, '  ' + subtitle, styled2)
    if (stdinIsTty) {
        String keys = '  p pause  \u00b7  s skip  \u00b7  q quit  \u00b7  Alt+T theme'
        boxRow(color, keys, DIM + keys + NC + color)
    }
    out(String.format('%s\u255a%s\u255d%s%n', color, bar, NC))
    out(String.format('%n'))
}

def showCompletion(String phase, int round, int totalRounds, String nextPhase,
                   boolean skipped) {
    int width = 60
    String line = '=' * width
    String title = skipped ? 'PHASE SKIPPED' :
            (phase == 'STUDY' ? 'STUDY SESSION COMPLETE' : 'BREAK COMPLETE')
    String color = phaseColor(phase)
    int pad = (int) ((width + title.length()) / 2)
    out(String.format('%n'))
    out(String.format('%s%s%s%n', color, line, NC))
    out(String.format('%s%s%s%s%n', color, ' ' * pad, title, NC))
    out(String.format('%s%s%s%n', color, line, NC))
    out(String.format('%n'))
    out(String.format('  Round:   %s%d%s / %d%n', BOLD, round, NC, totalRounds))
    out(String.format('  Points:  %s%d%s%n', primary, points, NC))
    out(String.format('%n'))
    if (nextPhase == 'None') {
        out(String.format('  Next:    %sSession complete%s%n', DIM, NC))
    } else {
        out(String.format('  Next:    %s%s%s%n', BOLD, nextPhase, NC))
    }
    out(String.format('%n'))
    out(String.format('  %sPress Enter to continue...%s', primary, NC))
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------

def phasePrepare(String ptype, int minutes, int round, int totalRounds) {
    if (ptype == 'study') {
        phaseLabel = 'STUDY'
        if (!quoteList.isEmpty()) {
            phaseSubtitle = quoteList.get(new Random().nextInt(quoteList.size()))
        } else {
            phaseSubtitle = 'Stay focused.'
        }
    } else {
        phaseLabel = 'BREAK'
        phaseSubtitle = 'Relax and recharge.'
    }

    if (ptype == 'study') {
        phaseNext = round < totalRounds ? 'Break (' + durationLabel(breakMin) + ')' : 'None'
    } else {
        phaseNext = 'Study (' + durationLabel(studyMin) + ')'
    }

    phaseTotal = (long) minutes * secondsPerUnit
    phaseElapsed = 0
    phasePaused = false
    phaseSkipped = false
    phaseStart = nowSeconds()
    phasePausedTotal = 0
    phasePauseAt = 0

    sessionText = String.format('%s %d/%d', phaseLabel, round, totalRounds)
    remainingStr = fmtHms(phaseTotal)
    pct = 0
    nextText = phaseNext == 'None' ? 'Session complete' : phaseNext
    messageText = phaseSubtitle

    logEvent(String.format('Start: %s %d/%d (%s)', phaseLabel, round,
            totalRounds, durationLabel(minutes)))
    phaseHeader(phaseLabel, round, totalRounds, minutes, phaseSubtitle)
    syncState()
}

def phaseHandleKey(int round, int totalRounds) {
    if (key == 'p' || key == 'P' || key == ' ') {
        if (phasePaused) {
            phasePausedTotal += nowSeconds() - phasePauseAt
            phasePaused = false
            logEvent(String.format('Resumed: %s %d/%d', phaseLabel, round, totalRounds))
        } else {
            phasePaused = true
            phasePauseAt = nowSeconds()
            logEvent(String.format('Paused: %s %d/%d', phaseLabel, round, totalRounds))
        }
    } else if (key == 's' || key == 'S') {
        phaseSkipped = true
        logEvent(String.format('Skipped: %s %d/%d', phaseLabel, round, totalRounds))
    } else if (key == 'q' || key == 'Q') {
        logEvent('Quit requested by user')
        cleanup(0)
    } else if (key == 'alt-t') {
        cycleTheme()
    }
}

def phaseCount(int round, int totalRounds) {
    while (phaseElapsed < phaseTotal) {
        long remaining = phaseTotal - phaseElapsed
        if (remaining < 0) remaining = 0
        remainingStr = fmtHms(remaining)
        pct = phaseTotal > 0 ? (int) (phaseElapsed * 100 / phaseTotal) : 0
        if (pct > 100) pct = 100
        sessionText = String.format('%s %d/%d', phaseLabel, round, totalRounds)
        if (phasePaused) sessionText += ' (PAUSED)'

        syncState()
        drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal, phasePaused)

        waitKey(1)
        if (keyRead) {
            phaseHandleKey(round, totalRounds)
            if (phaseSkipped) break
        }
        // CRASH-INJECT-POINT
        if (!phasePaused) {
            phaseElapsed = nowSeconds() - phaseStart - phasePausedTotal
        }
    }
}

def phaseFinish(int round, int totalRounds) {
    if (phaseSkipped) {
        sessionText = String.format('%s %d/%d (SKIPPED)', phaseLabel, round, totalRounds)
    } else {
        pct = 100
        points += 1
    }
    remainingStr = '00:00:00'
    syncState()
    drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal, false)
    out(String.format('%n'))
    logEvent(String.format('End: %s %d/%d', phaseLabel, round, totalRounds))

    playAlert()

    discardPendingInput()
    showCompletion(phaseLabel, round, totalRounds, phaseNext, phaseSkipped)
    waitForEnter()
    stopAlert()
    out(String.format('%n'))
}

def runPhase(String ptype, int minutes, int round, int totalRounds) {
    phasePrepare(ptype, minutes, round, totalRounds)
    phaseCount(round, totalRounds)
    phaseFinish(round, totalRounds)
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------
def resetStateFiles() {
    sessionText = 'stopped'
    remainingStr = '00:00:00'
    pct = 0
    nextText = ''
    syncState()
}

def cleanup(int code) {
    if (inCleanup) return
    inCleanup = true
    stateFinalized = true
    stopAlert()
    resetStateFiles()
    logEvent('Protocol stopped manually')
    out(String.format('%n'))
    out(String.format('%s%sInterrupted.%s %sState files reset to stopped.%s%n',
            secondary, BOLD, NC, DIM, NC))
    restoreTerminal()
    System.exit(code)
}

def onUnexpectedDeath(long rc) {
    if (!stateReady || stateFinalized) return
    stateFinalized = true
    stopAlert()
    resetStateFiles()
    logEvent('Protocol ended unexpectedly (exit ' + rc + ')')
}

def finalizeSession() {
    sessionText = 'session complete'
    remainingStr = '00:00:00'
    pct = 100
    nextText = ''
    syncState()
    stateFinalized = true
    logEvent('Protocol complete - total points: ' + points)
}

def finalBanner() {
    int bannerWidth = 60
    String title = 'ALL SESSIONS COMPLETE'
    int inner = bannerWidth - 2
    int pad = (int) ((inner - title.length()) / 2)
    String border = '#' * bannerWidth
    out(String.format('%n'))
    out(String.format('%s%s%s%n', primary, border, NC))
    out(String.format('%s#%s%s%s%s%s%s#%s%n', primary, NC, ' ' * pad, BOLD, title,
            ' ' * (inner - pad - title.length()), NC, primary))
    out(String.format('%s%s%s%n', primary, border, NC))
    out(String.format('%n'))
    out(String.format('  %sTotal Rounds:%s  %s%d%s%n', BOLD, NC, primary, rounds, NC))
    out(String.format('  %sTotal Points:%s %s%d%s%n', BOLD, NC, primary, points, NC))
    out(String.format('%n'))
    out(String.format('%s%sGreat work!%s %sExiting.%s%n', primary, BOLD, NC, DIM, NC))
}

def printLogo() {
    out(primary + String.format('%n'))
    out(LOGO + String.format('%n'))
    out(NC + String.format('%n'))
    out(String.format('%s%s     Study / Break Timer Protocol%s%n', primary, BOLD, NC))
    out(String.format('%s\u2500\u2500 live state written to date \u00b7 day \u00b7 ' +
            'session \u00b7 timer \u00b7 log%s%n', DIM, NC))
    out(String.format('%n'))
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
exitCodeForLog = 1

// Used by the crash-injection test (tests/ports.tsv): records the code for
// the shutdown hook's log message, then exits with it.
void crashExit(int code) {
    binding.exitCodeForLog = code
    System.exit(code)
}

Runtime.getRuntime().addShutdownHook(new Thread({
    onUnexpectedDeath(exitCodeForLog)
    restoreTerminal()
}))

// Signals: conventional exit codes 128 + signal number.
def installSignal = { String name, int code ->
    try {
        sun.misc.Signal.handle(new sun.misc.Signal(name), { sig ->
            exitCodeForLog = code
            cleanup(code)
        })
    } catch (Throwable ignored) {
        // Signal handling unavailable: the shutdown hook still resets files.
    }
}

parseArgs(args as List)

cfg = findConfigFile()
if (cfg) loadConfig(cfg)

// Environment variables beat the config file.
if (envAlertSound) alertSound = envAlertSound
if (envSinkName) sinkName = envSinkName
if (envStateDir) stateDir = envStateDir
if (envMaxLogBytes) {
    try {
        long v = Long.parseLong(envMaxLogBytes.trim())
        if (v > 0) maxLogBytes = v
    } catch (NumberFormatException ignored) { }
}

applyQuoteSources()
setupPaths()
selectTheme()

installSignal('INT', 130)
installSignal('TERM', 143)
installSignal('HUP', 129)

startInputReader()
setupTerminal()

printLogo()
setupAudioSink()
updateDateDay()
// From here on the state files may be written (and have to be reset if the
// program dies unexpectedly).
stateReady = true
logEvent(String.format('Starting new study protocol: %s, %s study, %s break',
        roundsLabel(rounds), durationLabel(studyMin), durationLabel(breakMin)))

out(String.format('%sProtocol:%s %s%s%s  %s|%s  %s%s%s study  %s|%s  %s%s%s' +
        ' break  %s|%s  %sTheme: %s%s%n',
        secondary, NC, BOLD, roundsLabel(rounds), NC, DIM, NC,
        BOLD, durationLabel(studyMin), NC, DIM, NC, BOLD,
        durationLabel(breakMin), NC, DIM, NC, BOLD, themeName, NC))
if (configLoaded) out(String.format('%sConfig: %s%s%n', DIM, configLoaded, NC))
out(String.format('%n'))

try {
    for (int round = 1; round <= rounds; round++) {
        runPhase('study', studyMin, round, rounds)
        if (round < rounds) runPhase('break', breakMin, round, rounds)
    }
} catch (Throwable e) {
    e.printStackTrace()
    onUnexpectedDeath(1)
    restoreTerminal()
    System.exit(1)
}

finalizeSession()
finalBanner()
restoreTerminal()
System.exit(0)
