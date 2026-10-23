// OBS.kt - Study/break timer protocol (Kotlin port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: JDK 8+ (compiled with kotlinc, standard library only), bash
// (to load the bash-syntax config file). Build:
//   kotlinc OBS.kt -include-runtime -d obs.jar && java -jar obs.jar ...
//
// NOTE: uses sun.misc.Signal for exact INT/TERM/HUP exit codes (130/143/129),
// like the Java port; timed stdin reads use a reader thread + queue (the JVM
// cannot select() on stdin); terminal modes are switched with stty.
//
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

private val D = "\$"   // a literal dollar for bash snippets inside raw strings

// ---------------------------------------------------------------------------
// Color themes: (name, primary, secondary)
// ---------------------------------------------------------------------------
val THEME_NAMES = arrayOf("Purple", "Ocean", "Forest", "Sunset", "Rose", "Gold",
    "Mono", "Ice", "Ember", "Neon", "Cobalt", "Cherry")
val THEME_PRIMARY = arrayOf("\u001b[1;35m", "\u001b[1;36m", "\u001b[1;32m", "\u001b[1;33m",
    "\u001b[1;95m", "\u001b[1;93m", "\u001b[1;37m", "\u001b[1;96m",
    "\u001b[1;91m", "\u001b[1;92m", "\u001b[1;34m", "\u001b[1;91m")
val THEME_SECONDARY = arrayOf("\u001b[0;35m", "\u001b[0;34m", "\u001b[0;32m", "\u001b[0;31m",
    "\u001b[0;31m", "\u001b[0;33m", "\u001b[0;37m", "\u001b[0;36m",
    "\u001b[0;31m", "\u001b[0;96m", "\u001b[0;36m", "\u001b[0;35m")

var primary = THEME_PRIMARY[0]
var secondary = THEME_SECONDARY[0]
var themeName = THEME_NAMES[0]
var themeIndex = 0
var themeNoticeUntil = 0L

const val BOLD = "\u001b[1m"
const val DIM = "\u001b[2m"
const val NC = "\u001b[0m"

val LOGO = """ /${D}${D}${D}${D}${D}${D}${D}${D}      /${D}${D}    /${D}${D} /${D}${D}${D}${D}${D}${D}${D}${D} /${D}${D}   /${D}${D}
| ${D}${D}_____/     | ${D}${D}   | ${D}${D}| ${D}${D}_____/| ${D}${D}  / ${D}${D}
| ${D}${D}           | ${D}${D}   | ${D}${D}| ${D}${D}      |  ${D}${D}/ ${D}${D}/
| ${D}${D}${D}${D}${D} /${D}${D}${D}${D}${D}${D}|  ${D}${D} / ${D}${D}/| ${D}${D}${D}${D}${D}    \  ${D}${D}${D}${D}/
| ${D}${D}__/|______/ \  ${D}${D} ${D}${D}/ | ${D}${D}__/     >${D}${D}  ${D}${D}
| ${D}${D}             \  ${D}${D}${D}/  | ${D}${D}       /${D}${D}/\  ${D}${D}
| ${D}${D}${D}${D}${D}${D}${D}${D}        \  ${D}/   | ${D}${D}${D}${D}${D}${D}${D}${D}| ${D}${D}  \ ${D}${D}
|________/         \_/    |________/|__/  |__/"""

val DEFAULT_QUOTE_LIST = arrayOf(
    "Focused effort beats scattered hours",
    "Every round finished is progress made",
    "Consistency beats intensity",
    "Start now, figure out the rest along the way",
    "A short break now means sharper focus next round",
)

fun setTheme(i: Int): Boolean {
    if (i < 0 || i >= THEME_NAMES.size) return false
    themeIndex = i
    themeName = THEME_NAMES[i]
    primary = THEME_PRIMARY[i]
    secondary = THEME_SECONDARY[i]
    return true
}

fun themeIndexOf(name: String): Int {
    if (name.isEmpty()) return -1
    for (i in THEME_NAMES.indices)
        if (THEME_NAMES[i].equals(name, ignoreCase = true)) return i
    return -1
}

var themeFile: File? = null

fun saveTheme() {
    val f = themeFile ?: return
    try { f.writeText(themeName + "\n") } catch (_: Exception) { }
}

fun cycleTheme() {
    setTheme((themeIndex + 1) % THEME_NAMES.size)
    saveTheme()
    themeNoticeUntil = nowSeconds() + 3
    logEvent("Theme changed to: $themeName")
}

fun listThemes() {
    for (i in THEME_NAMES.indices) {
        out(String.format("  %-8s %s████%s%n",
            THEME_NAMES[i], THEME_PRIMARY[i], THEME_SECONDARY[i]))
    }
}

// ---------------------------------------------------------------------------
// Environment overrides (captured before the defaults are applied)
// ---------------------------------------------------------------------------
val envAlertSound = env("ALERT_SOUND")
val envSinkName = env("SINK_NAME")
val envStateDir = env("STATE_DIR")
val envMaxLogBytes = env("MAX_LOG_BYTES")
val envQuotes = env("QUOTES")
val envTheme = env("THEME")

fun env(name: String): String = System.getenv(name) ?: ""

val START_NANO = System.nanoTime()
val random = java.util.Random(System.nanoTime())

fun nowSeconds(): Long = (System.nanoTime() - START_NANO) / 1_000_000_000L

// ---------------------------------------------------------------------------
// Built-in defaults
// ---------------------------------------------------------------------------
var alertSound = if (env("HOME").isNotEmpty())
    env("HOME") + "/Videos/Alarm/n_alarm.mp3" else ""
var sinkName = "OBS_Alert_Sink"
var stateDir = ""                 // empty -> the directory of the jar
var maxLogBytes = 1048576L
var fileBarWidth = 20
var nonTtyEnterTimeout = 300
var alertPid = 0L
var alertProcess: Process? = null
var dir = "."
var quoteList = DEFAULT_QUOTE_LIST.toMutableList()
var points = 0
var lastDate = ""

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
fun out(s: String) = System.out.print(s)

fun err(s: String) = System.err.print(s)

// ---------------------------------------------------------------------------
// Argument parsing & validation
// ---------------------------------------------------------------------------
var prog = "OBS"   // the class name (the JVM has no argv[0])
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

// Records the exit code for the shutdown hook's log line (crash injection).
val exitCodeForLog = ConcurrentHashMap<String, Int>()

fun crashExit(code: Int) {
    exitCodeForLog["code"] = code
    System.exit(code)
}

fun helpText(): String = String.format("""Usage: %s [options] <rounds> <study_minutes> <break_minutes>

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
  --config FILE | ${D}OBS_PANEL_CONFIG | ${D}XDG_CONFIG_HOME/obs-study-panel/config
""", prog, prog, prog, prog)

fun printHelp(code: Int) {
    out(helpText())
    System.out.flush()
    System.exit(code)
}

fun usageError() {
    System.err.print(helpText())
    System.err.flush()
    System.exit(1)
}

fun badNumber(v: String): Boolean {
    // ^[1-9][0-9]{0,3}$
    if (v.length !in 1..4) return true
    if (v[0] !in '1'..'9') return true
    for (i in 1 until v.length) if (v[i] !in '0'..'9') return true
    return false
}

fun parseArgs(argv: Array<String>) {
    val positional = mutableListOf<String>()
    var i = 0
    while (i < argv.size) {
        val a = argv[i]
        when {
            a == "-h" || a == "--help" -> printHelp(0)
            a == "-c" || a == "--config" -> {
                if (i + 1 >= argv.size) {
                    err("Error: $a needs a file argument\n")
                    usageError()
                }
                configFile = argv[i + 1]; i += 2
            }
            a == "-d" || a == "--dry-run" -> { dryRun = true; i++ }
            a == "-n" || a == "--no-alert" -> { useAlert = false; i++ }
            a == "-s" || a == "--no-sink" -> { useSink = false; i++ }
            a == "-t" || a == "--theme" -> {
                if (i + 1 >= argv.size) {
                    err("Error: $a needs a theme name\n")
                    usageError()
                }
                cliTheme = argv[i + 1]; i += 2
            }
            a == "--list-themes" -> { listThemes(); System.out.flush(); System.exit(0) }
            a == "--" -> { for (j in i + 1 until argv.size) positional.add(argv[j]); break }
            a.startsWith("-") -> { err("Error: unknown option: $a\n"); usageError() }
            else -> { for (j in i until argv.size) positional.add(argv[j]); break }
        }
    }
    if (positional.size != 3) usageError()
    for (v in positional) if (badNumber(v)) usageError()
    rounds = positional[0].toInt()
    studyMin = positional[1].toInt()
    breakMin = positional[2].toInt()
    if (rounds > 50) { err("Error: rounds must be <= 50\n"); usageError() }
    if (studyMin > 600) { err("Error: study minutes must be <= 600\n"); usageError() }
    if (breakMin > 120) { err("Error: break minutes must be <= 120\n"); usageError() }
    if (dryRun) {
        durationUnit = "seconds"
        secondsPerUnit = 1
    }
}

// ---------------------------------------------------------------------------
// Configuration file (bash syntax, loaded by a child bash)
// ---------------------------------------------------------------------------
val CONFIG_DUMP_SH = """
set -u
IFS=${D}'\037' read -r -a QUOTE_LIST <<< "${D}{QUOTES_SEED-}"
unset QUOTES_SEED
source "${D}1" || true
{
  d() { printf '%s\037%s\036' "${D}1" "${D}{2-}"; }
  d ALERT_SOUND "${D}{ALERT_SOUND-}"
  d SINK_NAME "${D}{SINK_NAME-}"
  d STATE_DIR "${D}{STATE_DIR-}"
  d MAX_LOG_BYTES "${D}{MAX_LOG_BYTES-}"
  d FILE_BAR_WIDTH "${D}{FILE_BAR_WIDTH-}"
  d NON_TTY_ENTER_TIMEOUT "${D}{NON_TTY_ENTER_TIMEOUT-}"
  d THEME "${D}{THEME-}"
  d POINTS "${D}{POINTS-}"
  d LAST_DATE "${D}{LAST_DATE-}"
  d QUOTES "${D}{QUOTES-}"
  for q in ${D}{QUOTE_LIST[@]+"${D}{QUOTE_LIST[@]}"}; do d QUOTE "${D}q"; done
} > "${D}2"
""".trimIndent()

fun findConfigFile(): String? {
    if (configFile.isNotEmpty()) return configFile
    val envCfg = System.getenv("OBS_PANEL_CONFIG")
    if (!envCfg.isNullOrEmpty()) return envCfg
    val xdgHome = System.getenv("XDG_CONFIG_HOME")
        ?: (if (env("HOME").isNotEmpty()) env("HOME") + "/.config" else "/.config")
    val xdgCfg = File(xdgHome, "obs-study-panel/config")
    if (xdgCfg.isFile) return xdgCfg.path
    val localCfg = File(dir, "obs-panel.conf")
    if (localCfg.isFile) return localCfg.path
    return null
}

fun quotesToList(raw: String): MutableList<String> {
    val list = mutableListOf<String>()
    for (line0 in raw.split("\n")) {
        val line = line0.trimEnd('\r')
        if (line.isNotEmpty()) list.add(line)
    }
    return list
}

fun loadConfig(path: String) {
    val f = File(path)
    if (!f.canRead()) {
        err("Error: config file is not readable: $path\n")
        System.exit(1)
    }
    // Syntax gate: bash -n, first 3 lines of its stderr.
    val check = ProcessBuilder("bash", "-n", path)
        .redirectOutput(ProcessBuilder.Redirect.DISCARD)
        .redirectErrorStream(false)
        .start()
    val bashErr = check.errorStream.readBytes().toString(StandardCharsets.UTF_8)
    check.waitFor()
    if (check.exitValue() != 0) {
        err("Error: syntax error in config file: $path\n")
        var printed = 0
        for (line in bashErr.split("\n")) {
            if (line.isBlank() || printed >= 3) continue
            err(line + "\n")
            printed++
        }
        System.exit(1)
    }

    // Seed the pre-config defaults, exactly what the reference holds while
    // it sources the file (the real environment's THEME/QUOTES pass through).
    val dump = File.createTempFile("obs-panel-conf-", ".dump")
    try {
        val pb = ProcessBuilder("bash", "-c", CONFIG_DUMP_SH, "obs-panel",
            path, dump.absolutePath)
            .redirectOutput(ProcessBuilder.Redirect.INHERIT)
            .redirectError(ProcessBuilder.Redirect.INHERIT)
        pb.environment()["ALERT_SOUND"] = alertSound
        pb.environment()["SINK_NAME"] = sinkName
        pb.environment()["STATE_DIR"] = ""
        pb.environment()["MAX_LOG_BYTES"] = "1048576"
        pb.environment()["FILE_BAR_WIDTH"] = "20"
        pb.environment()["NON_TTY_ENTER_TIMEOUT"] = "300"
        pb.environment()["POINTS"] = points.toString()
        pb.environment()["LAST_DATE"] = lastDate
        pb.environment()["QUOTES_SEED"] = quoteList.joinToString("\u001f")
        val child = pb.start()
        child.waitFor()
        val childRc = child.exitValue()

        val raw = if (dump.exists()) dump.readBytes() else ByteArray(0)
        if (raw.isEmpty()) {
            // The config called exit N before the dump was written.
            System.exit(if (childRc != 0) childRc else 1)
        }

        val values = HashMap<String, String>()
        val quotes = mutableListOf<String>()
        var start = 0
        while (start <= raw.size) {
            var recEnd = -1
            for (k in start until raw.size) {
                if (raw[k] == 0x1e.toByte()) { recEnd = k; break }
            }
            val recLen = (if (recEnd < 0) raw.size else recEnd) - start
            if (recLen > 0) {
                var sep = -1
                for (k in start until start + recLen)
                    if (raw[k] == 0x1f.toByte()) { sep = k; break }
                if (sep >= 0) {
                    val key = String(raw, start, sep - start, StandardCharsets.ISO_8859_1)
                    val value = String(raw, sep + 1, start + recLen - sep - 1,
                        StandardCharsets.ISO_8859_1)
                    if (key == "QUOTE") quotes.add(value) else values[key] = value
                }
            }
            if (recEnd < 0) break
            start = recEnd + 1
        }

        alertSound = values["ALERT_SOUND"] ?: alertSound
        sinkName = values["SINK_NAME"] ?: sinkName
        stateDir = values["STATE_DIR"] ?: ""
        maxLogBytes = (values["MAX_LOG_BYTES"] ?: "1048576").toLongOrNull() ?: 1048576L
        fileBarWidth = (values["FILE_BAR_WIDTH"] ?: "20").toIntOrNull() ?: 20
        nonTtyEnterTimeout = (values["NON_TTY_ENTER_TIMEOUT"] ?: "300").toIntOrNull() ?: 300
        configTheme = values["THEME"] ?: ""
        points = values["POINTS"]?.toIntOrNull() ?: 0
        lastDate = values["LAST_DATE"] ?: ""
        configQuotes = values["QUOTES"] ?: ""
        quoteList = quotes
        configLoaded = path
    } finally {
        dump.delete()
    }
}

fun applyQuoteSources() {
    if (envQuotes.isNotEmpty()) quoteList = quotesToList(envQuotes)
    else if (configQuotes.isNotEmpty()) quoteList = quotesToList(configQuotes)
}

fun sanityKnobs() {
    if (maxLogBytes <= 0) maxLogBytes = 1048576L
    if (fileBarWidth <= 0 || fileBarWidth > 200) fileBarWidth = 20
    if (nonTtyEnterTimeout <= 0 || nonTtyEnterTimeout > 3600) nonTtyEnterTimeout = 300
}

// ---------------------------------------------------------------------------
// Paths and runtime state
// ---------------------------------------------------------------------------
var dateFile: File? = null
var dayFile: File? = null
var sessionFile: File? = null
var timerFile: File? = null
var logFile: File? = null
var progressFile: File? = null
var pointsFile: File? = null
var messageFile: File? = null
var nextFile: File? = null
var overlayFile: File? = null

var sessionText = ""
var remainingStr = "00:00:00"
var pct = 0
var nextText = ""
var messageText = ""
var lastDay = ""
var stateReady = false
var stateFinalized = false
var inCleanup = false

fun setupPaths() {
    if (stateDir.isEmpty()) stateDir = dir
    try {
        File(stateDir).mkdirs()
    } catch (e: Exception) {
        err("Error: cannot create state dir: $stateDir\n")
        System.exit(1)
    }
    fun p(name: String) = File(stateDir, name)
    dateFile = p("date.txt")
    dayFile = p("day.txt")
    sessionFile = p("session.txt")
    timerFile = p("timer.txt")
    logFile = p("log.txt")
    progressFile = p("progress.txt")
    pointsFile = p("points.txt")
    messageFile = p("message.txt")
    nextFile = p("next.txt")
    overlayFile = p("overlay.txt")
    themeFile = p("theme.txt")
}

fun selectTheme() {
    var request = cliTheme
    if (request.isEmpty() && envTheme.isNotEmpty()) request = envTheme
    if (request.isEmpty() && configTheme.isNotEmpty()) request = configTheme
    if (request.isEmpty()) {
        val tf = themeFile
        if (tf != null && tf.isFile) {
            try {
                request = tf.useLines { it.firstOrNull() ?: "" }
            } catch (_: Exception) { }
        }
    }
    if (request.isNotEmpty()) {
        val idx = themeIndexOf(request)
        if (idx < 0) {
            err("Warning: unknown theme '$request', using $themeName\n")
        } else {
            setTheme(idx)
        }
    }
}

// ---------------------------------------------------------------------------
// Startup logo
// ---------------------------------------------------------------------------
fun printLogo() {
    out(primary + "\n")
    out(LOGO + "\n")
    out(NC + "\n")
    out("$primary$BOLD     Study / Break Timer Protocol$NC\n")
    out("$DIM── live state written to date · day · session · timer · log$NC\n")
    out("\n")
}

// ---------------------------------------------------------------------------
// OBS state files
// ---------------------------------------------------------------------------
fun writeFile(f: File?, text: String) {
    if (f == null) return
    try { f.writeText(text + "\n") } catch (_: Exception) { }
}

fun updateDateDay() {
    val d = java.time.LocalDate.now().toString()
    if (d == lastDate) return
    lastDate = d
    lastDay = java.time.LocalDate.now().dayOfWeek
        .getDisplayName(java.time.format.TextStyle.FULL, java.util.Locale.ENGLISH)
    writeFile(dateFile, d)
    writeFile(dayFile, lastDay)
}

fun syncState() {
    updateDateDay()
    publishState()
}

fun makeBar(filled: Int, width: Int, fill: String, empty: String, head: String = ""): String {
    val sb = StringBuilder()
    for (i in 0 until width) {
        if (i < filled) {
            sb.append(if (head.isNotEmpty() && i == filled - 1) head else fill)
        } else {
            sb.append(empty)
        }
    }
    return sb.toString()
}

fun fileBar(): String = makeBar(pct * fileBarWidth / 100, fileBarWidth, "#", "-")

fun publishState() {
    val bar = fileBar()
    writeFile(sessionFile, sessionText)
    writeFile(timerFile, remainingStr)
    writeFile(pointsFile, points.toString())
    writeFile(nextFile, nextText)
    writeFile(messageFile, messageText)
    val pctLine = String.format("[%s] %3d%%", bar, pct)
    writeFile(progressFile, pctLine)
    val overlay = mutableListOf(
        "$lastDate  $lastDay",
        sessionText,
        remainingStr,
        pctLine,
        "Pts: $points",
        "Next: $nextText",
    )
    if (messageText.isNotEmpty()) overlay.add(messageText)
    try { overlayFile?.writeText(overlay.joinToString("\n") + "\n") } catch (_: Exception) { }
}

fun rotateLogIfNeeded() {
    val lf = logFile ?: return
    try {
        if (!lf.isFile) return
        if (lf.length() < maxLogBytes) return
        val backup = File(lf.path + ".1")
        backup.delete()
        if (!lf.renameTo(backup)) return
        lf.writeText("")
    } catch (_: Exception) { }
}

fun logEvent(msg: String) {
    rotateLogIfNeeded()
    val ts = java.time.LocalDateTime.now().format(
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"))
    try { logFile?.appendText("[$ts] $msg\n") } catch (_: Exception) { }
}

// ---------------------------------------------------------------------------
// Audio alerts
// ---------------------------------------------------------------------------
fun which(name: String): String? {
    val path = System.getenv("PATH") ?: return null
    for (d0 in path.split(":")) {
        if (d0.isEmpty()) continue
        val f = File(d0, name)
        if (f.isFile && f.canExecute()) return f.path
    }
    return null
}

fun sinkIsReady(): Boolean {
    if (which("pactl") == null) return false
    return try {
        val p = ProcessBuilder("pactl", "list", "short", "sinks")
            .redirectOutput(ProcessBuilder.Redirect.PIPE)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
            .start()
        val text = p.inputStream.readBytes().toString(StandardCharsets.UTF_8)
        p.waitFor()
        if (p.exitValue() != 0) return false
        for (line in text.split("\n")) {
            val fields = line.trim().split(Regex("\\s+"))
            if (fields.size > 1 && fields[1] == sinkName) return true
        }
        false
    } catch (e: Exception) { false }
}

fun setupAudioSink() {
    if (!useSink) return
    if (which("pactl") == null) return
    if (sinkIsReady()) return
    try {
        val p = ProcessBuilder("pactl", "load-module", "module-null-sink",
            "sink_name=$sinkName", "sink_properties=device.description=$sinkName")
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
            .start()
        p.waitFor()
    } catch (_: Exception) { }
}

fun stopAlert() {
    val p = alertProcess
    if (p != null) {
        try {
            p.destroy()   // SIGTERM, like the reference's kill
        } catch (_: Exception) { }
        try { p.waitFor(2, TimeUnit.SECONDS) } catch (_: Exception) { }
        alertProcess = null
        alertPid = 0
    }
}

fun playAlert() {
    if (!useAlert) return
    stopAlert()   // never let two alarms overlap
    if (alertSound.isEmpty() || !File(alertSound).isFile) {
        out("$DIM(alert file not found: ${if (alertSound.isNotEmpty()) alertSound else "none"})$NC\n")
        return
    }
    val player: List<String> = when {
        which("mpv") != null -> listOf("mpv", "--no-video", "--volume=70")
        which("paplay") != null -> listOf("paplay")
        which("ffplay") != null -> listOf("ffplay", "-nodisp", "-autoexit")
        which("cvlc") != null -> listOf("cvlc", "--play-and-exit", "--no-video", "--volume=70")
        else -> {
            out("$DIM(no audio player found - install mpv / paplay / ffplay)$NC\n")
            return
        }
    }
    if (useSink && !sinkIsReady()) setupAudioSink()

    fun spawn(onSink: Boolean) {
        val pb = ProcessBuilder(player + alertSound)
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
        if (onSink) pb.environment()["PULSE_SINK"] = sinkName
        alertProcess = pb.start()
        alertPid = alertProcess!!.pid()
    }

    try {
        if (useSink && sinkIsReady()) {
            spawn(true)
            out("$DIM-> alert on OBS sink ($sinkName)$NC\n")
        } else {
            spawn(false)
            out("$secondary-> alert on default device (OBS sink unavailable)$NC\n")
        }
    } catch (_: Exception) { }
}

// ---------------------------------------------------------------------------
// Keyboard input: a reader thread feeds a queue; EOF is a sentinel.
// ---------------------------------------------------------------------------
const val EOF = -1
const val EOF_MARKER = 256

val inputQueue = LinkedBlockingQueue<Int>()
@Volatile var sawEof = false
@Volatile var stdinIsTty = false
var key = ""
var keyRead = false
var savedTermSettings: String? = null

fun startInputReader() {
    thread(isDaemon = true) {
        val buf = ByteArray(256)
        try {
            while (true) {
                val n = System.`in`.read(buf)
                if (n < 0) { inputQueue.put(EOF_MARKER); return@thread }
                for (i in 0 until n) inputQueue.put(buf[i].toInt() and 0xff)
            }
        } catch (e: Exception) {
            try { inputQueue.put(EOF_MARKER) } catch (_: InterruptedException) { }
        }
    }
}

fun waitByte(timeoutSec: Double): Int {
    if (sawEof) return EOF
    val b = try {
        inputQueue.poll((timeoutSec * 1e9).toLong(), TimeUnit.NANOSECONDS)
    } catch (e: InterruptedException) { return -2 }
    if (b == null) return -2
    if (b == EOF_MARKER) { sawEof = true; return EOF }
    return b
}

// --- terminal handling (stty on the controlling terminal) ---
fun runSttyCapture(argv: List<String>): String {
    return try {
        val pb = ProcessBuilder(argv).redirectInput(ProcessBuilder.Redirect.INHERIT)
        val p = pb.start()
        val outp = p.inputStream.readBytes().toString(StandardCharsets.UTF_8)
        p.waitFor()
        outp.trim()
    } catch (e: Exception) { "" }
}

fun runStty(argv: List<String>) {
    try {
        val pb = ProcessBuilder(argv)
            .redirectInput(ProcessBuilder.Redirect.INHERIT)
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
        pb.start().waitFor()
    } catch (_: Exception) { }
}

fun setupTerminal() {
    stdinIsTty = isattyProbe()
    if (!stdinIsTty) return
    savedTermSettings = runSttyCapture(listOf("stty", "-g"))
    runStty(listOf("stty", "-icanon", "-echo"))
}

/* The reference checks stdin only (bash [[ -t 0 ]]) - not stdout - so probe
 * the same way via the shell (stdin inherited). */
fun isattyProbe(): Boolean {
    return try {
        val pb = ProcessBuilder("sh", "-c", "test -t 0 && echo tty || echo no")
            .redirectInput(ProcessBuilder.Redirect.INHERIT)
        val p = pb.start()
        val line = p.inputStream.readBytes().toString(StandardCharsets.UTF_8).trim()
        p.waitFor()
        line == "tty"
    } catch (e: Exception) { System.console() != null }
}

fun restoreTerminal() {
    if (!stdinIsTty) return
    val saved = savedTermSettings
    if (!saved.isNullOrEmpty()) runStty(listOf("stty", saved))
    else runStty(listOf("stty", "sane"))
    savedTermSettings = null
}

fun waitKey(timeoutSec: Double) {
    key = ""
    keyRead = false
    if (!stdinIsTty) {
        try { Thread.sleep((timeoutSec * 1000).toLong()) }
        catch (_: InterruptedException) { }
        return
    }
    val b = waitByte(timeoutSec)
    if (b < 0) return
    keyRead = true
    if (b == 27) {
        key = ""
        val nxt = waitByte(0.3)
        if (nxt == 't'.code || nxt == 'T'.code) key = "alt-t"
    } else {
        key = (b.toChar()).toString()
    }
}

fun discardPendingInput() {
    if (!stdinIsTty) return
    while (true) {
        val b = waitByte(0.01)
        if (b < 0) return
    }
}

fun waitForEnter() {
    if (stdinIsTty) {
        while (true) {
            val b = waitByte(1.0)
            if (b == -2) { updateDateDay(); continue }
            if (b == EOF || b == '\n'.code) return
        }
    }
    // Not a terminal: bounded wait, 5 s slices.
    var waited = 0
    while (waited < nonTtyEnterTimeout) {
        val sliceEnd = System.nanoTime() + 5_000_000_000L
        while (true) {
            val left = sliceEnd - System.nanoTime()
            if (left <= 0) { waited += 5; break }
            val b = waitByte(left / 1e9)
            if (b == EOF) return
            if (b == -2) { waited += 5; break }
            if (b == '\n'.code) return
        }
    }
}

// ---------------------------------------------------------------------------
// Status / progress UI
// ---------------------------------------------------------------------------
const val TERM_BAR_WIDTH = 24
const val BOX_INNER = 62

fun phaseColor(label: String) = if (label == "STUDY") primary else secondary

fun drawStatus(label: String, round: Int, totalRounds: Int, elapsed: Int,
               total: Int, paused: Boolean) {
    var filled = 0
    if (total > 0) filled = elapsed * TERM_BAR_WIDTH / total
    if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH
    val bar = makeBar(filled, TERM_BAR_WIDTH, "=", " ", ">")
    val color = phaseColor(label)
    var flag = ""
    if (paused) flag = "$primary PAUSED$NC"
    if (nowSeconds() < themeNoticeUntil) flag += "  ${DIM}Theme: $themeName$NC"
    out("\r\u001b[K")
    out(String.format("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
        BOLD, color, label, NC, round, totalRounds,
        color, bar, NC, pct, remainingStr, primary, points, NC, flag))
}

fun boxRow(color: String, plain: String, styled: String) {
    var pad = BOX_INNER - plain.length
    if (pad < 0) pad = 0
    out("$color║$styled${" ".repeat(pad)}$color║$NC\n")
}

fun durationLabel(n: Int): String {
    if (n == 1) return if (durationUnit == "seconds") "1 second" else "1 minute"
    return "$n $durationUnit"
}

fun roundsLabel(n: Int): String = if (n == 1) "1 round" else "$n rounds"

fun phaseHeader(label: String, round: Int, total: Int, minutes: Int,
                subtitle0: String) {
    val subtitle = subtitle0.take(BOX_INNER - 4)
    val color = phaseColor(label)
    val bar = "═".repeat(BOX_INNER)
    val info = "$label  ·  Round $round / $total  ·  ${durationLabel(minutes)}"
    out("\n")
    out("$color╔$bar╗$NC\n")
    boxRow(color, "  $info",
        "  $BOLD$label$NC$color  ·  Round $round / $total  ·  ${durationLabel(minutes)}")
    boxRow(color, "  $subtitle", "  $DIM$subtitle$NC$color")
    if (stdinIsTty) {
        val keys = "  p pause  ·  s skip  ·  q quit  ·  Alt+T theme"
        boxRow(color, keys, "$DIM$keys$NC$color")
    }
    out("$color╚$bar╝$NC\n")
    out("\n")
}

fun showCompletion(phase: String, round: Int, totalRounds: Int,
                   nextPhase: String, skipped: Int) {
    val width = 60
    val line = "=".repeat(width)
    val title = when {
        skipped == 1 -> "PHASE SKIPPED"
        phase == "STUDY" -> "STUDY SESSION COMPLETE"
        else -> "BREAK COMPLETE"
    }
    val color = phaseColor(phase)
    out("\n")
    out("$color$line$NC\n")
    out("$color${" ".repeat((width + title.length) / 2)}$title$NC\n")
    out("$color$line$NC\n")
    out("\n")
    out("  Round:   $BOLD$round$NC / $totalRounds\n")
    out("  Points:  $primary$points$NC\n")
    out("\n")
    if (nextPhase == "None") out("  Next:    $DIM${"Session complete"}$NC\n")
    else out("  Next:    $BOLD$nextPhase$NC\n")
    out("\n")
    out("  ${primary}Press Enter to continue...$NC")
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------
var phaseLabel = ""
var phaseSubtitle = ""
var phaseNext = ""
var phaseTotal = 0
var phaseElapsed = 0
var phasePaused = false
var phaseSkipped = false
var phaseStart = 0L
var phasePausedTotal = 0L
var phasePauseAt = 0L

fun fmtHms(total: Int): String =
    String.format("%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)

fun phasePrepare(ptype: String, minutes: Int, round: Int, totalRounds: Int) {
    if (ptype == "study") {
        phaseLabel = "STUDY"
        phaseSubtitle = if (quoteList.isNotEmpty())
            quoteList[random.nextInt(quoteList.size)]
        else "Stay focused."
    } else {
        phaseLabel = "BREAK"
        phaseSubtitle = "Relax and recharge."
    }
    phaseNext = if (ptype == "study") {
        if (round < totalRounds) "Break (${durationLabel(breakMin)})" else "None"
    } else {
        "Study (${durationLabel(studyMin)})"
    }
    phaseTotal = minutes * secondsPerUnit
    phaseElapsed = 0
    phasePaused = false
    phaseSkipped = false
    phaseStart = nowSeconds()
    phasePausedTotal = 0
    phasePauseAt = 0
    sessionText = "$phaseLabel $round/$totalRounds"
    remainingStr = fmtHms(phaseTotal)
    pct = 0
    nextText = if (phaseNext == "None") "Session complete" else phaseNext
    messageText = phaseSubtitle
    logEvent("Start: $phaseLabel $round/$totalRounds (${durationLabel(minutes)})")
    phaseHeader(phaseLabel, round, totalRounds, minutes, phaseSubtitle)
    syncState()
}

fun phaseHandleKey(round: Int, totalRounds: Int) {
    when (key) {
        "p", "P", " " -> {
            if (phasePaused) {
                phasePausedTotal += nowSeconds() - phasePauseAt
                phasePaused = false
                logEvent("Resumed: $phaseLabel $round/$totalRounds")
            } else {
                phasePaused = true
                phasePauseAt = nowSeconds()
                logEvent("Paused: $phaseLabel $round/$totalRounds")
            }
        }
        "s", "S" -> {
            phaseSkipped = true
            logEvent("Skipped: $phaseLabel $round/$totalRounds")
        }
        "q", "Q" -> {
            logEvent("Quit requested by user")
            cleanup(0)
        }
        "alt-t" -> cycleTheme()
    }
}

fun phaseCount(round: Int, totalRounds: Int) {
    while (phaseElapsed < phaseTotal) {
        var remaining = phaseTotal - phaseElapsed
        if (remaining < 0) remaining = 0
        remainingStr = fmtHms(remaining)
        pct = if (phaseTotal > 0) phaseElapsed * 100 / phaseTotal else 0
        if (pct > 100) pct = 100
        sessionText = "$phaseLabel $round/$totalRounds" +
            (if (phasePaused) " (PAUSED)" else "")

        syncState()
        drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal, phasePaused)

        waitKey(1.0)
        if (keyRead) {
            phaseHandleKey(round, totalRounds)
            if (phaseSkipped) return
        }
        // CRASH-INJECT-POINT
        if (!phasePaused) {
            phaseElapsed = (nowSeconds() - phaseStart - phasePausedTotal).toInt()
        }
    }
}

fun phaseFinish(round: Int, totalRounds: Int) {
    if (phaseSkipped) {
        sessionText = "$phaseLabel $round/$totalRounds (SKIPPED)"
    } else {
        pct = 100
        points += 1
    }
    remainingStr = "00:00:00"
    syncState()
    drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal, false)
    out("\n")
    logEvent("End: $phaseLabel $round/$totalRounds")
    playAlert()
    discardPendingInput()
    showCompletion(phaseLabel, round, totalRounds, phaseNext, if (phaseSkipped) 1 else 0)
    waitForEnter()
    stopAlert()
    out("\n")
}

fun runPhase(ptype: String, minutes: Int, round: Int, totalRounds: Int) {
    phasePrepare(ptype, minutes, round, totalRounds)
    phaseCount(round, totalRounds)
    phaseFinish(round, totalRounds)
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------
fun resetStateFiles() {
    sessionText = "stopped"
    remainingStr = "00:00:00"
    pct = 0
    nextText = ""
    syncState()
}

fun cleanup(code: Int) {
    if (inCleanup) return
    inCleanup = true
    stateFinalized = true
    try { stopAlert() } catch (_: Exception) { }
    try { resetStateFiles() } catch (_: Exception) { }
    try { logEvent("Protocol stopped manually") } catch (_: Exception) { }
    try {
        out("\n")
        out("$secondary$BOLD${"Interrupted."}$NC $DIM${"State files reset to stopped."}$NC\n")
    } catch (_: Exception) { }
    restoreTerminal()
    System.exit(code)
}

fun onUnexpectedDeath(rc: Int) {
    if (!stateReady) return
    if (stateFinalized) return
    stateFinalized = true
    try { stopAlert() } catch (_: Exception) { }
    try { resetStateFiles() } catch (_: Exception) { }
    try { logEvent("Protocol ended unexpectedly (exit $rc)") } catch (_: Exception) { }
}

// The EXIT-trap equivalent: runs on System.exit and on JVM shutdown
// (including uncaught exceptions); resets the state files when the session
// had not finalized. It must not change the exit code.
fun shutdownHook() {
    onUnexpectedDeath(exitCodeForLog["code"] ?: 1)
    restoreTerminal()
}

fun installSignal(name: String, code: Int) {
    try {
        sun.misc.Signal.handle(sun.misc.Signal(name)) {
            exitCodeForLog["code"] = code
            cleanup(code)
        }
    } catch (t: Throwable) {
        // Signal handling unavailable: fall back to the shutdown hook only.
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
fun finalizeSession() {
    sessionText = "session complete"
    remainingStr = "00:00:00"
    pct = 100
    nextText = ""
    syncState()
    stateFinalized = true
    logEvent("Protocol complete - total points: $points")
}

fun finalBanner() {
    val bannerWidth = 60
    val title = "ALL SESSIONS COMPLETE"
    val inner = bannerWidth - 2
    val pad = (inner - title.length) / 2
    val border = "#".repeat(bannerWidth)
    out("\n")
    out("$primary$border$NC\n")
    out("$primary#$NC${" ".repeat(pad)}$BOLD$title" +
        "${" ".repeat(inner - pad - title.length)}$NC#$primary\n")
    out("$primary$border$NC\n")
    out("\n")
    out("  $BOLD${"Total Rounds:"}$NC  $primary$rounds$NC\n")
    out("  $BOLD${"Total Points:"}$NC $primary$points$NC\n")
    out("\n")
    out("$primary$BOLD${"Great work!"}$NC $DIM${"Exiting."}$NC\n")
}

fun main(argv: Array<String>) {
    prog = "OBS"   // the class name (the JVM has no argv[0])
    dir = try {
        val loc = Class.forName("OBSKt").protectionDomain.codeSource.location
        File(loc.toURI()).parent ?: "."
    } catch (e: Exception) { "." }

    parseArgs(argv)
    val cfg = findConfigFile()
    if (cfg != null) loadConfig(cfg)

    // Environment variables beat the config file.
    if (envAlertSound.isNotEmpty()) alertSound = envAlertSound
    if (envSinkName.isNotEmpty()) sinkName = envSinkName
    if (envStateDir.isNotEmpty()) stateDir = envStateDir
    if (envMaxLogBytes.isNotEmpty()) {
        envMaxLogBytes.trim().toLongOrNull()?.let { if (it > 0) maxLogBytes = it }
    }
    applyQuoteSources()
    sanityKnobs()
    setupPaths()
    selectTheme()

    Runtime.getRuntime().addShutdownHook(Thread { shutdownHook() })

    installSignal("INT", 130)
    installSignal("TERM", 143)
    installSignal("HUP", 129)

    startInputReader()
    setupTerminal()

    printLogo()
    setupAudioSink()
    updateDateDay()
    stateReady = true
    logEvent("Starting new study protocol: ${roundsLabel(rounds)}, " +
        "${durationLabel(studyMin)} study, ${durationLabel(breakMin)} break")

    out("$secondary${"Protocol:"}$NC $BOLD${roundsLabel(rounds)}$NC  $DIM|$NC  " +
        "$BOLD${durationLabel(studyMin)}$NC study  $DIM|$NC  " +
        "$BOLD${durationLabel(breakMin)}$NC break  $DIM|$NC  " +
        "$BOLD${"Theme: "}$themeName$NC\n")
    if (configLoaded.isNotEmpty()) out("$DIM${"Config: "}$configLoaded$NC\n")
    out("\n")

    try {
        for (round in 1..rounds) {
            runPhase("study", studyMin, round, rounds)
            if (round < rounds) runPhase("break", breakMin, round, rounds)
        }
    } catch (e: RuntimeException) {
        // An unexpected runtime error resets the files and exits with 1.
        e.printStackTrace()
        onUnexpectedDeath(1)
        restoreTerminal()
        System.exit(1)
    }

    finalizeSession()
    finalBanner()
    restoreTerminal()
    System.exit(0)
}
