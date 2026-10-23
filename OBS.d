// OBS.d - Study/break timer protocol (D port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: LDC2 or DMD (betterC not used), bash (to load the
// bash-syntax config file). Build: ldc2 -O2 -release OBS.d -o obs
//
// POSIX details (termios, poll, sigaction, fork/exec) come from
// core.sys.posix; signal handlers only store the exit code (a plain store,
// safe in signal context); the interrupted poll loop performs the cleanup.
//
import std.stdio;
import std.string;
import std.array;
import std.file;
import std.path;
import std.format;
import std.datetime;
import std.random;
import std.conv;
import std.algorithm;
import std.process;
import std.typecons : Tuple, tuple;
import core.stdc.stdlib : exit, malloc, free;
import core.stdc.time : time_t, time;
import core.stdc.string : strdup, strlen, memcpy;
import core.sys.posix.unistd;
alias pread = core.sys.posix.unistd.read;
import core.sys.posix.fcntl : open, O_RDWR;
import core.sys.posix.sys.wait : waitpid, WNOHANG;
import core.sys.posix.signal : signal, sigaction, sigemptyset, SIGINT,
    SIGTERM, SIGHUP, SIG_DFL, SA_RESTART;
import core.sys.posix.unistd : getpid;
import core.sys.posix.poll : poll, pollfd, POLLIN;
import core.sys.posix.sys.stat : stat_t, stat, S_ISREG;
import core.sys.posix.time : nanosleep, timespec;
public import core.sys.linux.termios;

// ---------------------------------------------------------------------------
// libc externs
// ---------------------------------------------------------------------------
extern (C)
{
    struct Tm
    {
        int sec, min, hour, mday, mon, year;
        int wday, yday, isdst;
        long gmtoff;
        const(char)* zone;
    }
    Tm* localtime_r(const time_t* timep, Tm* result);
    size_t strftime(char* s, size_t max, const(char)* format,
        const Tm* tm);
    int setenv(const(char)* name, const(char)* value, int overwrite);
    int kill(int pid, int sig);
    int clock_gettime(int clk_id, timespec* tp);
}

private __gshared int sigFlag = 0;

extern (C) void onSignal(int sig) nothrow @nogc
{
    final switch (sig)
    {
    case 2: sigFlag = 130; break;   // SIGINT
    case 15: sigFlag = 143; break;  // SIGTERM
    case 1: sigFlag = 129; break;   // SIGHUP
    }
}

void installSignalHandlers()
{
    // signal(2) is fine here: the handler only stores the exit code and
    // poll(2) is never restarted, even with SA_RESTART set.
    signal(SIGINT, &onSignal);
    signal(SIGTERM, &onSignal);
    signal(SIGHUP, &onSignal);
}

void checkSignal()
{
    if (sigFlag != 0)
    {
        cleanup(sigFlag);
    }
}

// ---------------------------------------------------------------------------
// Clocks
// ---------------------------------------------------------------------------
private long startWall = 0;

long nowSeconds() { return cast(long) time(null) - startWall; }

long nowMs()
{
    timespec ts;
    clock_gettime(1, &ts);   // CLOCK_MONOTONIC
    return ts.tv_sec * 1000 + ts.tv_nsec / 1_000_000;
}

void sleepMs(long ms)
{
    long waited = 0;
    while (waited < ms)
    {
        checkSignal();
        immutable slice = min(ms - waited, 50L);
        timespec req;
        req.tv_sec = cast(typeof(req.tv_sec))(slice / 1000);
        req.tv_nsec = (slice % 1000) * 1_000_000;
        timespec rem;
        nanosleep(&req, &rem);
        waited += slice;
    }
}

// Wait until fd 0 is readable. true = readable.
bool pollReadable(long ms)
{
    long deadline = nowMs() + ms;
    while (true)
    {
        checkSignal();
        long left = deadline - nowMs();
        if (left < 0) left = 0;
        pollfd fds;
        fds.fd = 0;
        fds.events = POLLIN;
        fds.revents = 0;
        int rc = poll(&fds, 1, cast(int) left);
        if (rc > 0) return fds.revents != 0;
        if (rc == 0)
        {
            if (nowMs() >= deadline) return false;
            continue;
        }
        // rc < 0 (EINTR): loop; the flag check runs first.
    }
}

// One byte with a timeout: 0..255, -1 timeout, -2 EOF.
int readByteTimeout(long ms)
{
    if (!pollReadable(ms)) return -1;
    ubyte b;
    ptrdiff_t n = read(0, &b, 1);
    if (n <= 0) return -2;
    return b;
}

// ---------------------------------------------------------------------------
// Process helpers (fork + exec)
// ---------------------------------------------------------------------------
private char** argvZ(string[] argv)
{
    auto arr = cast(char**) malloc((argv.length + 1) * (char*).sizeof);
    foreach (i, a; argv)
        arr[i] = strdup(a.toStringz);
    arr[argv.length] = null;
    return arr;
}

private void freeArgv(char** arr, size_t n)
{
    foreach (i; 0 .. n) free(arr[i]);
    free(arr);
}

/// Fork + exec inheriting all streams; envAdd is added to the environment.
int spawnInherit(string[] argv, string[string] envAdd = null)
{
    auto pid = fork();
    if (pid == 0)
    {
        foreach (k, v; envAdd) setenv(k.toStringz, v.toStringz, 1);
        auto z = argvZ(argv);
        core.sys.posix.unistd.execvp(argv[0].toStringz, z);
        _exit(127);
    }
    return pid;
}

/// Fork + exec with both output streams on a pipe; returns text and rc.
Tuple!(string, int) captureOutput(string[] argv)
{
    int[2] fds;
    if (pipe(fds) != 0) return tuple("", -1);
    auto pid = fork();
    if (pid == 0)
    {
        dup2(fds[1], 1);
        close(fds[0]);
        close(fds[1]);
        auto z = argvZ(argv);
        core.sys.posix.unistd.execvp(argv[0].toStringz, z);
        _exit(127);
    }
    close(fds[1]);
    auto app = appender!(ubyte[])();
    ubyte[4096] buf;
    while (true)
    {
        ptrdiff_t n = pread(fds[0], &buf, buf.length);
        if (n <= 0) break;
        app.put(buf[0 .. n]);
    }
    close(fds[0]);
    int status;
    waitpid(pid, &status, 0);
    int rc = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f);
    return tuple(cast(string) app.data, rc);
}

/// Fork + exec with all streams on /dev/null; envAdd is added.
int spawnDevNull(string[] argv, string[string] envAdd = null)
{
    auto pid = fork();
    if (pid == 0)
    {
        int fd = open("/dev/null".toStringz, O_RDWR);
        if (fd >= 0)
        {
            dup2(fd, 0);
            dup2(fd, 1);
            dup2(fd, 2);
        }
        foreach (k, v; envAdd) setenv(k.toStringz, v.toStringz, 1);
        auto z = argvZ(argv);
        core.sys.posix.unistd.execvp(argv[0].toStringz, z);
        _exit(127);
    }
    return pid;
}

int waitPid(int pid)
{
    int status;
    waitpid(pid, &status, 0);
    return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f);
}

// command -v: first executable regular file in PATH.
string which(string name)
{
    string path = environment.get("PATH", "");
    if (path.empty) return null;
    foreach (dir0; path.splitter(':'))
    {
        if (dir0.empty) continue;
        string full = dir0.endsWith("/") ? dir0 ~ name : dir0 ~ "/" ~ name;
        stat_t st;
        if (stat(full.toStringz, &st) == 0 && S_ISREG(st.st_mode) &&
                ((st.st_mode & 73) != 0))
            return full;
    }
    return null;
}

// localTimeStr: strftime on the current local time.
string localTimeStr(string fmt)
{
    auto t = time(null);
    Tm tm;
    if (localtime_r(&t, &tm) is null) return "";
    char[256] buf;
    size_t n = strftime(buf.ptr, buf.length, fmt.toStringz, &tm);
    if (n == 0) return "";
    return cast(string) buf[0 .. n].idup;
}

// ---------------------------------------------------------------------------
// Color themes: (name, primary, secondary)
// ---------------------------------------------------------------------------
struct Theme { string name; string primary; string secondary; }

immutable Theme[12] THEMES = [
    Theme("Purple",  "\x1b[1;35m", "\x1b[0;35m"),
    Theme("Ocean",   "\x1b[1;36m", "\x1b[0;34m"),
    Theme("Forest",  "\x1b[1;32m", "\x1b[0;32m"),
    Theme("Sunset",  "\x1b[1;33m", "\x1b[0;31m"),
    Theme("Rose",    "\x1b[1;95m", "\x1b[0;31m"),
    Theme("Gold",    "\x1b[1;93m", "\x1b[0;33m"),
    Theme("Mono",    "\x1b[1;37m", "\x1b[0;37m"),
    Theme("Ice",     "\x1b[1;96m", "\x1b[0;36m"),
    Theme("Ember",   "\x1b[1;91m", "\x1b[0;31m"),
    Theme("Neon",    "\x1b[1;92m", "\x1b[0;96m"),
    Theme("Cobalt",  "\x1b[1;34m", "\x1b[0;36m"),
    Theme("Cherry",  "\x1b[1;91m", "\x1b[0;35m"),
];

enum BOLD = "\x1b[1m";
enum DIM = "\x1b[2m";
enum NC = "\x1b[0m";

immutable LOGO = `
 /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/`;

immutable string[5] DEFAULT_QUOTES = [
    "Focused effort beats scattered hours",
    "Every round finished is progress made",
    "Consistency beats intensity",
    "Start now, figure out the rest along the way",
    "A short break now means sharper focus next round",
];

string primary = THEMES[0].primary;
string secondary = THEMES[0].secondary;
string themeName = THEMES[0].name;
int themeIndex = 0;
long themeNoticeUntil = 0;

bool setTheme(int i)
{
    if (i < 0 || i >= cast(int) THEMES.length) return false;
    themeIndex = i;
    themeName = THEMES[i].name;
    primary = THEMES[i].primary;
    secondary = THEMES[i].secondary;
    return true;
}

int themeIndexByName(string name)
{
    if (name.empty) return -1;
    foreach (i, t; THEMES)
        if (t.name.toLower() == name.toLower()) return cast(int) i;
    return -1;
}

string themeFile = "";

void saveTheme()
{
    if (themeFile.empty) return;
    try std.file.write(themeFile, themeName ~ "\n");
    catch (Exception) {}
}

void cycleTheme()
{
    setTheme((themeIndex + 1) % THEMES.length);
    saveTheme();
    themeNoticeUntil = nowSeconds() + 3;
    logEvent("Theme changed to: " ~ themeName);
}

void listThemes()
{
    foreach (t; THEMES)
        writef("  %-8s %s████%s\n", t.name, t.primary, t.secondary);
}

// ---------------------------------------------------------------------------
// Environment overrides (captured before the defaults are applied; D runs
// module initializers at compile time, so this happens in main())
// ---------------------------------------------------------------------------
string envAlertSound, envSinkName, envStateDir, envMaxLogBytes;
string envQuotes, envTheme;

// ---------------------------------------------------------------------------
// Built-in defaults
// ---------------------------------------------------------------------------
string home;
string alertSound;
string sinkName = "OBS_Alert_Sink";
string stateDir = "";
long maxLogBytes = 1048576;
int fileBarWidth = 20;
int nonTtyEnterTimeout = 300;
int alertPid = 0;
string dir = ".";
string[] quoteList = DEFAULT_QUOTES.dup;
int points;
string lastDate = "";

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------
string prog = "OBS.d";
string configFile = "";
bool dryRun;
bool useAlert = true;
bool useSink = true;
int rounds, studyMin, breakMin;
string cliTheme = "";
string durationUnit = "minutes";
int secondsPerUnit = 60;
string configTheme = "";
string configQuotes = "";
string configLoaded = "";

class CrashExitException : Exception
{
    int code;
    this(int c) { super("crash exit"); code = c; }
}

// Used by the crash-injection test point (tests/ports.tsv).
void crashExit(int code)
{
    throw new CrashExitException(code);
}

string helpText() @safe
{
    return format(
`Usage: %s [options] <rounds> <study_minutes> <break_minutes>

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
`, prog, prog, prog, prog);
}

void printHelp(int code)
{
    stdout.rawWrite(helpText());
    exit(code);
}

void usageError()
{
    stderr.rawWrite(helpText());
    exit(1);
}

bool badNumber(string v)
{
    // ^[1-9][0-9]{0,3}$
    if (v.length < 1 || v.length > 4) return true;
    if (v[0] < '1' || v[0] > '9') return true;
    foreach (c; v[1 .. $])
        if (c < '0' || c > '9') return true;
    return false;
}

long parseIntOr(string v, long fallback)
{
    try
    {
        if (!v.empty && v.all!(c => c >= '0' && c <= '9'))
            return v.to!long;
    }
    catch (ConvException) {}
    return fallback;
}

void parseArgs(string[] argv)
{
    string[] positional;
    int i = 0;
    outer: while (i < cast(int) argv.length)
    {
        string a = argv[i];
        if (a == "-h" || a == "--help") printHelp(0);
        else if (a == "-c" || a == "--config")
        {
            if (i + 1 >= argv.length)
            {
                stderr.writef("Error: %s needs a file argument\n", a);
                usageError();
            }
            configFile = argv[i + 1];
            i += 2;
        }
        else if (a == "-d" || a == "--dry-run") { dryRun = true; i++; }
        else if (a == "-n" || a == "--no-alert") { useAlert = false; i++; }
        else if (a == "-s" || a == "--no-sink") { useSink = false; i++; }
        else if (a == "-t" || a == "--theme")
        {
            if (i + 1 >= argv.length)
            {
                stderr.writef("Error: %s needs a theme name\n", a);
                usageError();
            }
            cliTheme = argv[i + 1];
            i += 2;
        }
        else if (a == "--list-themes")
        {
            listThemes();
            exit(0);
        }
        else if (a == "--")
        {
            foreach (j; i + 1 .. argv.length) positional ~= argv[j];
            break outer;
        }
        else if (a.length > 0 && a[0] == '-')
        {
            stderr.writef("Error: unknown option: %s\n", a);
            usageError();
        }
        else
        {
            foreach (j; i .. argv.length) positional ~= argv[j];
            break outer;
        }
    }

    if (positional.length != 3) usageError();
    foreach (v; positional)
        if (badNumber(v)) usageError();
    rounds = positional[0].to!int;
    studyMin = positional[1].to!int;
    breakMin = positional[2].to!int;
    if (rounds > 50) { stderr.writeln("Error: rounds must be <= 50"); usageError(); }
    if (studyMin > 600) { stderr.writeln("Error: study minutes must be <= 600"); usageError(); }
    if (breakMin > 120) { stderr.writeln("Error: break minutes must be <= 120"); usageError(); }
    if (dryRun)
    {
        durationUnit = "seconds";
        secondsPerUnit = 1;
    }
}

// ---------------------------------------------------------------------------
// Configuration file (bash syntax, loaded by a child bash)
// ---------------------------------------------------------------------------
immutable CONFIG_DUMP_SH = `
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
`;

bool fileExists(string p) { return exists(p) && isFile(p); }

string findConfigFile()
{
    if (!configFile.empty) return configFile;
    string envCfg = environment.get("OBS_PANEL_CONFIG", "");
    if (!envCfg.empty) return envCfg;
    string xdg = environment.get("XDG_CONFIG_HOME", "");
    if (xdg.empty)
        xdg = home != "" ? home ~ "/.config" : "/.config";
    string xdgCfg = buildPath(xdg, "obs-study-panel", "config");
    if (fileExists(xdgCfg)) return xdgCfg;
    string localCfg = buildPath(dir, "obs-panel.conf");
    if (fileExists(localCfg)) return localCfg;
    return null;
}

string[] quotesToList(string raw)
{
    string[] list;
    foreach (line0; raw.splitter('\n'))
    {
        string line = line0.endsWith("\r") ? line0[0 .. $ - 1] : line0;
        if (!line.empty) list ~= line;
    }
    return list;
}

void loadConfig(string path)
{
    // bash's [[ -r ]]: readability probe via access(2).
    if (access(path.toStringz, 4) != 0)
    {
        stderr.writeln("Error: config file is not readable: " ~ path);
        exit(1);
    }
    if (which("bash") is null)
    {
        stderr.writeln("Error: bash is required to read the config file: "
            ~ path);
        exit(1);
    }
    // Syntax gate: bash -n, first 3 lines of its stderr.
    {
        auto cap = captureOutput(["bash", "-n", path]);
        if (cap[1] != 0)
        {
            stderr.writeln("Error: syntax error in config file: " ~ path);
            int printed = 0;
            foreach (line; cap[0].splitter('\n'))
            {
                if (line.strip.empty || printed >= 3) continue;
                stderr.writeln(line);
                printed++;
            }
            exit(1);
        }
    }

    // Seed the pre-config defaults, exactly what the reference holds while
    // it sources the file (the real environment's THEME/QUOTES pass through).
    string dumpPath = buildPath(tempDir,
        "obs-panel-conf-" ~ text(getpid));
    int childRc = 0;
    {
        string[string] envAdd = [
            "ALERT_SOUND": alertSound,
            "SINK_NAME": sinkName,
            "STATE_DIR": "",
            "MAX_LOG_BYTES": "1048576",
            "FILE_BAR_WIDTH": "20",
            "NON_TTY_ENTER_TIMEOUT": "300",
            "POINTS": text(points),
            "LAST_DATE": lastDate,
            "QUOTES_SEED": quoteList.join("\x1f"),
        ];
        int pid = spawnInherit(
            ["bash", "-c", CONFIG_DUMP_SH, "obs-panel", path, dumpPath],
            envAdd);
        childRc = pid > 0 ? waitPid(pid) : 1;
    }

    string raw = "";
    if (exists(dumpPath))
        raw = cast(string) read(dumpPath);
    if (exists(dumpPath))
    {
        try remove(dumpPath);
        catch (Exception) {}
    }
    if (raw.empty)
    {
        // The config called exit N before the dump was written.
        exit(childRc != 0 ? childRc : 1);
    }

    string[string] values;
    string[] quotes;
    {
        auto data = cast(ubyte[]) raw;
        size_t idx = 0;
        while (idx <= data.length)
        {
            ptrdiff_t recEnd = -1;
            foreach (k; idx .. data.length)
                if (data[k] == 0x1E) { recEnd = cast(ptrdiff_t) k; break; }
            size_t endPos = recEnd < 0 ? data.length : cast(size_t) recEnd;
            if (endPos > idx)
            {
                ptrdiff_t sep = -1;
                foreach (k; idx .. endPos)
                    if (data[k] == 0x1F) { sep = cast(ptrdiff_t) k; break; }
                if (sep >= 0)
                {
                    string recKey = cast(string) data[idx .. cast(size_t) sep];
                    string value = cast(string) data[cast(size_t) sep + 1 .. endPos];
                    if (recKey == "QUOTE") quotes ~= value;
                    else values[recKey] = value;
                }
            }
            if (recEnd < 0) break;
            idx = endPos + 1;
        }
    }

    alertSound = "ALERT_SOUND" in values ? values["ALERT_SOUND"] : alertSound;
    sinkName = "SINK_NAME" in values ? values["SINK_NAME"] : sinkName;
    stateDir = "STATE_DIR" in values ? values["STATE_DIR"] : "";
    maxLogBytes = parseIntOr(
        "MAX_LOG_BYTES" in values ? values["MAX_LOG_BYTES"] : "1048576",
        1048576);
    fileBarWidth = cast(int) parseIntOr(
        "FILE_BAR_WIDTH" in values ? values["FILE_BAR_WIDTH"] : "20", 20);
    nonTtyEnterTimeout = cast(int) parseIntOr(
        "NON_TTY_ENTER_TIMEOUT" in values
            ? values["NON_TTY_ENTER_TIMEOUT"] : "300", 300);
    configTheme = "THEME" in values ? values["THEME"] : "";
    points = cast(int) parseIntOr(
        "POINTS" in values ? values["POINTS"] : "0", 0);
    lastDate = "LAST_DATE" in values ? values["LAST_DATE"] : "";
    configQuotes = "QUOTES" in values ? values["QUOTES"] : "";
    quoteList = quotes;
    configLoaded = path;
}

void applyQuoteSources()
{
    if (!envQuotes.empty) quoteList = quotesToList(envQuotes);
    else if (!configQuotes.empty) quoteList = quotesToList(configQuotes);
}

void sanityKnobs()
{
    if (maxLogBytes <= 0) maxLogBytes = 1048576;
    if (fileBarWidth <= 0 || fileBarWidth > 200) fileBarWidth = 20;
    if (nonTtyEnterTimeout <= 0 || nonTtyEnterTimeout > 3600)
        nonTtyEnterTimeout = 300;
}

// ---------------------------------------------------------------------------
// Paths and runtime state
// ---------------------------------------------------------------------------
string dateFile, dayFile, sessionFile, timerFile, logFile;
string progressFile, pointsFile, messageFile, nextFile, overlayFile;

string sessionText = "";
string remainingStr = "00:00:00";
int pct;
string nextText = "";
string messageText = "";
string lastDay = "";
bool stateReady, stateFinalized, inCleanup;

void setupPaths()
{
    if (stateDir.empty) stateDir = dir;
    try mkdirRecurse(stateDir);
    catch (Exception)
    {
        stderr.writeln("Error: cannot create state dir: " ~ stateDir);
        exit(1);
    }
    dateFile = buildPath(stateDir, "date.txt");
    dayFile = buildPath(stateDir, "day.txt");
    sessionFile = buildPath(stateDir, "session.txt");
    timerFile = buildPath(stateDir, "timer.txt");
    logFile = buildPath(stateDir, "log.txt");
    progressFile = buildPath(stateDir, "progress.txt");
    pointsFile = buildPath(stateDir, "points.txt");
    messageFile = buildPath(stateDir, "message.txt");
    nextFile = buildPath(stateDir, "next.txt");
    overlayFile = buildPath(stateDir, "overlay.txt");
    themeFile = buildPath(stateDir, "theme.txt");
}

void selectTheme()
{
    string request = cliTheme;
    if (request.empty && !envTheme.empty) request = envTheme;
    if (request.empty && !configTheme.empty) request = configTheme;
    if (request.empty && !themeFile.empty && fileExists(themeFile))
    {
        try
        {
            foreach (line; File(themeFile).byLineCopy)
            {
                request = line;
                break;
            }
        }
        catch (Exception) {}
    }
    if (!request.empty)
    {
        int idx = themeIndexByName(request);
        if (idx < 0)
            stderr.writef("Warning: unknown theme '%s', using %s\n",
                request, themeName);
        else
            setTheme(idx);
    }
}

// ---------------------------------------------------------------------------
// Startup logo
// ---------------------------------------------------------------------------
void printLogo()
{
    writeln(primary);
    writeln(LOGO);
    writeln(NC);
    writeln(primary ~ BOLD ~ "     Study / Break Timer Protocol" ~ NC);
    writeln(DIM ~ "── live state written to date · day · session · timer · log" ~ NC);
    writeln();
}

// ---------------------------------------------------------------------------
// OBS state files
// ---------------------------------------------------------------------------
void writeFileLine(string path, string text)
{
    try std.file.write(path, text ~ "\n");
    catch (Exception) {}
}

void updateDateDay()
{
    string d = localTimeStr("%Y-%m-%d");
    if (d == lastDate) return;
    lastDate = d;
    lastDay = localTimeStr("%A");
    writeFileLine(dateFile, d);
    writeFileLine(dayFile, lastDay);
}

void syncState()
{
    updateDateDay();
    publishState();
}

string makeBar(int filled, int width, char fill, char empty, char head = '\0')
{
    auto sb = appender!(char[])();
    foreach (i; 0 .. width)
    {
        if (i < filled)
            sb.put(head != '\0' && i == filled - 1 ? head : fill);
        else
            sb.put(empty);
    }
    return cast(string) sb.data;
}

string fileBar()
{
    return makeBar(pct * fileBarWidth / 100, fileBarWidth, '#', '-');
}

void publishState()
{
    string bar = fileBar();
    writeFileLine(sessionFile, sessionText);
    writeFileLine(timerFile, remainingStr);
    writeFileLine(pointsFile, text(points));
    writeFileLine(nextFile, nextText);
    writeFileLine(messageFile, messageText);
    string pctLine = format("[%s] %3d%%", bar, pct);
    writeFileLine(progressFile, pctLine);
    string overlay = lastDate ~ "  " ~ lastDay ~ "\n" ~ sessionText ~ "\n"
        ~ remainingStr ~ "\n" ~ pctLine ~ "\n" ~ "Pts: " ~ text(points) ~ "\n"
        ~ "Next: " ~ nextText;
    if (!messageText.empty) overlay ~= "\n" ~ messageText;
    overlay ~= "\n";
    try std.file.write(overlayFile, overlay);
    catch (Exception) {}
}

void rotateLogIfNeeded()
{
    try
    {
        if (!exists(logFile)) return;
        if (getSize(logFile) < maxLogBytes) return;
        if (exists(logFile ~ ".1")) remove(logFile ~ ".1");
        rename(logFile, logFile ~ ".1");
        std.file.write(logFile, "");
    }
    catch (Exception) {}
}

void logEvent(string msg)
{
    rotateLogIfNeeded();
    try append(logFile,
        format("[%s] %s\n", localTimeStr("%Y-%m-%d %H:%M:%S"), msg));
    catch (Exception) {}
}

// ---------------------------------------------------------------------------
// Audio alerts
// ---------------------------------------------------------------------------
bool sinkIsReady()
{
    if (which("pactl") is null) return false;
    auto cap = captureOutput(["pactl", "list", "short", "sinks"]);
    if (cap[1] != 0) return false;
    foreach (line; cap[0].splitter('\n'))
    {
        auto fields = line.splitter().array();
        if (fields.length > 1 && fields[1] == sinkName) return true;
    }
    return false;
}

void setupAudioSink()
{
    if (!useSink) return;
    if (which("pactl") is null) return;
    if (sinkIsReady()) return;
    int pid = spawnDevNull(["pactl", "load-module", "module-null-sink",
        "sink_name=" ~ sinkName,
        "sink_properties=device.description=" ~ sinkName]);
    if (pid > 0) waitPid(pid);
}

void stopAlert()
{
    if (alertPid > 0)
    {
        kill(alertPid, 15);
        int status;
        waitpid(alertPid, &status, WNOHANG);
        alertPid = 0;
    }
}

void playAlert()
{
    if (!useAlert) return;
    stopAlert();   // never let two alarms overlap
    if (alertSound.empty || !fileExists(alertSound))
    {
        writeln(DIM ~ "(alert file not found: "
            ~ (!alertSound.empty ? alertSound : "none") ~ ")" ~ NC);
        return;
    }

    string[] player;
    if (which("mpv") !is null) player = ["mpv", "--no-video", "--volume=70"];
    else if (which("paplay") !is null) player = ["paplay"];
    else if (which("ffplay") !is null) player = ["ffplay", "-nodisp", "-autoexit"];
    else if (which("cvlc") !is null)
        player = ["cvlc", "--play-and-exit", "--no-video", "--volume=70"];
    else
    {
        writeln(DIM ~ "(no audio player found - install mpv / paplay / ffplay)"
            ~ NC);
        return;
    }

    if (useSink && !sinkIsReady()) setupAudioSink();

    bool onSink = useSink && sinkIsReady();
    string[] argv = player ~ alertSound;
    if (onSink)
    {
        alertPid = spawnDevNull(argv, ["PULSE_SINK": sinkName]);
        writeln(DIM ~ "-> alert on OBS sink (" ~ sinkName ~ ")" ~ NC);
    }
    else
    {
        alertPid = spawnDevNull(argv);
        writeln(secondary ~ "-> alert on default device (OBS sink unavailable)"
            ~ NC);
    }
}

// ---------------------------------------------------------------------------
// Keyboard input
// ---------------------------------------------------------------------------
bool stdinIsTty;
termios termSaved;
bool termSavedValid;
string key = "";
bool keyRead;

void setupTerminal()
{
    stdinIsTty = isatty(0) == 1;
    if (!stdinIsTty) return;
    termios t;
    if (tcgetattr(0, &t) == 0)
    {
        termSaved = t;
        termSavedValid = true;
        // cbreak like the reference's `read -s`: echo and canonical mode
        // off, ISIG stays on so Ctrl+C still generates SIGINT.
        t.c_lflag &= ~(ICANON | ECHO);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        tcsetattr(0, TCSAFLUSH, &t);
    }
}

void restoreTerminal()
{
    if (termSavedValid)
    {
        tcsetattr(0, TCSADRAIN, &termSaved);
        termSavedValid = false;
    }
}

void waitKey(double timeoutSec)
{
    key = "";
    keyRead = false;
    if (!stdinIsTty)
    {
        sleepMs(cast(long) (timeoutSec * 1000));
        return;
    }
    int b = readByteTimeout(cast(long) (timeoutSec * 1000));
    if (b < 0) return;
    keyRead = true;
    if (b == 27)
    {
        key = "";
        int nxt = readByteTimeout(300);
        if (nxt == 't' || nxt == 'T') key = "alt-t";
    }
    else
    {
        key = text(cast(char) b);
    }
}

void discardPendingInput()
{
    if (!stdinIsTty) return;
    while (true)
    {
        int b = readByteTimeout(10);
        if (b < 0) return;
    }
}

void waitForEnter()
{
    if (stdinIsTty)
    {
        while (true)
        {
            int b = readByteTimeout(1000);
            if (b == -1) updateDateDay();
            else if (b == -2 || b == '\n') return;
        }
    }
    // Not a terminal: bounded wait, 5 s slices.
    int waited = 0;
    while (waited < nonTtyEnterTimeout)
    {
        long sliceEnd = nowMs() + 5000;
        sliceLoop: while (true)
        {
            checkSignal();
            long left = sliceEnd - nowMs();
            if (left <= 0) break sliceLoop;
            if (!pollReadable(left)) break sliceLoop;
            ubyte[4096] buf;
            ptrdiff_t n = pread(0, &buf, buf.length);
            if (n <= 0) return;   // EOF
            foreach (i; 0 .. n)
                if (buf[i] == '\n') return;
        }
        waited += 5;
    }
}

// ---------------------------------------------------------------------------
// Status / progress UI
// ---------------------------------------------------------------------------
enum TERM_BAR_WIDTH = 24;
enum BOX_INNER = 62;

string phaseColor(string label)
{
    return label == "STUDY" ? primary : secondary;
}

void drawStatus(string label, int round, int totalRounds, int elapsed,
    int total, bool paused)
{
    int filled = 0;
    if (total > 0) filled = elapsed * TERM_BAR_WIDTH / total;
    if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH;
    string bar = makeBar(filled, TERM_BAR_WIDTH, '=', ' ', '>');
    string color = phaseColor(label);
    string flag = "";
    if (paused) flag = primary ~ " PAUSED" ~ NC;
    if (nowSeconds() < themeNoticeUntil)
        flag ~= "  " ~ DIM ~ "Theme: " ~ themeName ~ NC;
    stdout.rawWrite("\r\x1b[K");
    writef("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
        BOLD, color, label, NC, round, totalRounds,
        color, bar, NC, pct, remainingStr, primary, points, NC, flag);
    stdout.flush();
}

void boxRow(string color, string plain, string styled)
{
    int pad = BOX_INNER - cast(int) plain.length;
    if (pad < 0) pad = 0;
    writeln(color ~ "║" ~ styled ~ replicate(" ", pad) ~ color ~ "║" ~ NC);
}

string durationLabel(int n)
{
    if (n == 1) return durationUnit == "seconds" ? "1 second" : "1 minute";
    return text(n) ~ " " ~ durationUnit;
}

string roundsLabel(int n)
{
    return n == 1 ? "1 round" : text(n) ~ " rounds";
}

void phaseHeader(string label, int round, int total, int minutes,
    string subtitle0)
{
    string subtitle = subtitle0.length > BOX_INNER - 4
        ? subtitle0[0 .. BOX_INNER - 4] : subtitle0;
    string color = phaseColor(label);
    string bar = replicate("═", BOX_INNER);
    string info = label ~ "  ·  Round " ~ text(round) ~ " / " ~ text(total)
        ~ "  ·  " ~ durationLabel(minutes);
    writeln();
    writeln(color ~ "╔" ~ bar ~ "╗" ~ NC);
    boxRow(color, "  " ~ info,
        "  " ~ BOLD ~ label ~ NC ~ color ~ "  ·  Round " ~ text(round)
        ~ " / " ~ text(total) ~ "  ·  " ~ durationLabel(minutes));
    boxRow(color, "  " ~ subtitle, "  " ~ DIM ~ subtitle ~ NC ~ color);
    if (stdinIsTty)
    {
        string keys = "  p pause  ·  s skip  ·  q quit  ·  Alt+T theme";
        boxRow(color, keys, DIM ~ keys ~ NC ~ color);
    }
    writeln(color ~ "╚" ~ bar ~ "╝" ~ NC);
    writeln();
}

void showCompletion(string phase, int round, int totalRounds,
    string nextPhase, bool skipped)
{
    enum width = 60;
    string line = replicate("=", width);
    string title = skipped ? "PHASE SKIPPED"
        : phase == "STUDY" ? "STUDY SESSION COMPLETE" : "BREAK COMPLETE";
    string color = phaseColor(phase);
    writeln();
    writeln(color ~ line ~ NC);
    writeln(color ~ replicate(" ", (width + cast(int) title.length) / 2)
        ~ title ~ NC);
    writeln(color ~ line ~ NC);
    writeln();
    writefln("  Round:   %s%d%s / %d", BOLD, round, NC, totalRounds);
    writefln("  Points:  %s%d%s", primary, points, NC);
    writeln();
    if (nextPhase == "None")
        writefln("  Next:    %sSession complete%s", DIM, NC);
    else
        writefln("  Next:    %s%s%s", BOLD, nextPhase, NC);
    writeln();
    stdout.rawWrite("  " ~ primary ~ "Press Enter to continue..." ~ NC);
    stdout.flush();
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------
string phaseLabel = "";
string phaseSubtitle = "";
string phaseNext = "";
int phaseTotal, phaseElapsed;
bool phasePaused, phaseSkipped;
long phaseStart, phasePausedTotal, phasePauseAt;

string fmtHms(int total)
{
    return format("%02d:%02d:%02d",
        total / 3600, total % 3600 / 60, total % 60);
}

void phasePrepare(string ptype, int minutes, int round, int totalRounds)
{
    if (ptype == "study")
    {
        phaseLabel = "STUDY";
        if (!quoteList.empty)
            phaseSubtitle = quoteList[uniform(0, cast(size_t) quoteList.length)];
        else
            phaseSubtitle = "Stay focused.";
    }
    else
    {
        phaseLabel = "BREAK";
        phaseSubtitle = "Relax and recharge.";
    }
    if (ptype == "study")
    {
        phaseNext = round < totalRounds
            ? "Break (" ~ durationLabel(breakMin) ~ ")" : "None";
    }
    else
    {
        phaseNext = "Study (" ~ durationLabel(studyMin) ~ ")";
    }
    phaseTotal = minutes * secondsPerUnit;
    phaseElapsed = 0;
    phasePaused = false;
    phaseSkipped = false;
    phaseStart = nowSeconds();
    phasePausedTotal = 0;
    phasePauseAt = 0;

    sessionText = phaseLabel ~ " " ~ text(round) ~ "/" ~ text(totalRounds);
    remainingStr = fmtHms(phaseTotal);
    pct = 0;
    nextText = phaseNext == "None" ? "Session complete" : phaseNext;
    messageText = phaseSubtitle;

    logEvent("Start: " ~ phaseLabel ~ " " ~ text(round) ~ "/"
        ~ text(totalRounds) ~ " (" ~ durationLabel(minutes) ~ ")");
    phaseHeader(phaseLabel, round, totalRounds, minutes, phaseSubtitle);
    syncState();
}

void phaseHandleKey(int round, int totalRounds)
{
    if (key == "p" || key == "P" || key == " ")
    {
        if (phasePaused)
        {
            phasePausedTotal += nowSeconds() - phasePauseAt;
            phasePaused = false;
            logEvent("Resumed: " ~ phaseLabel ~ " " ~ text(round) ~ "/"
                ~ text(totalRounds));
        }
        else
        {
            phasePaused = true;
            phasePauseAt = nowSeconds();
            logEvent("Paused: " ~ phaseLabel ~ " " ~ text(round) ~ "/"
                ~ text(totalRounds));
        }
    }
    else if (key == "s" || key == "S")
    {
        phaseSkipped = true;
        logEvent("Skipped: " ~ phaseLabel ~ " " ~ text(round) ~ "/"
            ~ text(totalRounds));
    }
    else if (key == "q" || key == "Q")
    {
        logEvent("Quit requested by user");
        cleanup(0);
    }
    else if (key == "alt-t")
    {
        cycleTheme();
    }
}

void phaseCount(int round, int totalRounds)
{
    while (phaseElapsed < phaseTotal)
    {
        int remaining = phaseTotal - phaseElapsed;
        if (remaining < 0) remaining = 0;
        remainingStr = fmtHms(remaining);
        pct = phaseTotal > 0 ? phaseElapsed * 100 / phaseTotal : 0;
        if (pct > 100) pct = 100;
        sessionText = phaseLabel ~ " " ~ text(round) ~ "/"
            ~ text(totalRounds) ~ (phasePaused ? " (PAUSED)" : "");

        syncState();
        drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal,
            phasePaused);

        waitKey(1.0);
        if (keyRead)
        {
            phaseHandleKey(round, totalRounds);
            if (phaseSkipped) break;
        }
        // CRASH-INJECT-POINT
        if (!phasePaused)
        {
            phaseElapsed = cast(int) (nowSeconds() - phaseStart
                - phasePausedTotal);
        }
    }
}

void phaseFinish(int round, int totalRounds)
{
    if (phaseSkipped)
    {
        sessionText = phaseLabel ~ " " ~ text(round) ~ "/"
            ~ text(totalRounds) ~ " (SKIPPED)";
    }
    else
    {
        pct = 100;
        points += 1;
    }
    remainingStr = "00:00:00";
    syncState();
    drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal, false);
    writeln();
    logEvent("End: " ~ phaseLabel ~ " " ~ text(round) ~ "/" ~ text(totalRounds));

    playAlert();

    discardPendingInput();
    showCompletion(phaseLabel, round, totalRounds, phaseNext, phaseSkipped);
    waitForEnter();
    stopAlert();
    writeln();
}

void runPhase(string ptype, int minutes, int round, int totalRounds)
{
    phasePrepare(ptype, minutes, round, totalRounds);
    phaseCount(round, totalRounds);
    phaseFinish(round, totalRounds);
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------
void resetStateFiles()
{
    sessionText = "stopped";
    remainingStr = "00:00:00";
    pct = 0;
    nextText = "";
    syncState();
}

void cleanup(int code)
{
    if (inCleanup) return;
    inCleanup = true;
    stateFinalized = true;
    try stopAlert();
    catch (Exception) {}
    try resetStateFiles();
    catch (Exception) {}
    try logEvent("Protocol stopped manually");
    catch (Exception) {}
    try
    {
        writeln();
        writeln(secondary ~ BOLD ~ "Interrupted." ~ NC ~ " " ~ DIM
            ~ "State files reset to stopped." ~ NC);
    }
    catch (Exception) {}
    restoreTerminal();
    exit(code);
}

void onUnexpectedDeath(int rc)
{
    if (!stateReady) return;
    if (stateFinalized) return;
    stateFinalized = true;
    try stopAlert();
    catch (Exception) {}
    try resetStateFiles();
    catch (Exception) {}
    try logEvent("Protocol ended unexpectedly (exit " ~ text(rc) ~ ")");
    catch (Exception) {}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
void finalizeSession()
{
    sessionText = "session complete";
    remainingStr = "00:00:00";
    pct = 100;
    nextText = "";
    syncState();
    stateFinalized = true;
    logEvent("Protocol complete - total points: " ~ text(points));
}

void finalBanner()
{
    enum bannerWidth = 60;
    enum title = "ALL SESSIONS COMPLETE";
    enum inner = bannerWidth - 2;
    int pad = (inner - cast(int) title.length) / 2;
    string border = replicate("#", bannerWidth);
    writeln();
    writeln(primary ~ border ~ NC);
    writeln(primary ~ "#" ~ NC ~ replicate(" ", pad) ~ BOLD ~ title
        ~ replicate(" ", inner - pad - cast(int) title.length) ~ NC ~ "#"
        ~ primary);
    writeln(primary ~ border ~ NC);
    writeln();
    writefln("  %sTotal Rounds:%s  %s%d%s", BOLD, NC, primary, rounds, NC);
    writefln("  %sTotal Points:%s %s%d%s", BOLD, NC, primary, points, NC);
    writeln();
    writeln(primary ~ BOLD ~ "Great work!" ~ NC ~ " " ~ DIM ~ "Exiting." ~ NC);
}

void runAll(string[] argv)
{
    parseArgs(argv);

    string cfg = findConfigFile();
    if (cfg !is null) loadConfig(cfg);

    // Environment variables beat the config file.
    if (!envAlertSound.empty) alertSound = envAlertSound;
    if (!envSinkName.empty) sinkName = envSinkName;
    if (!envStateDir.empty) stateDir = envStateDir;
    if (!envMaxLogBytes.empty)
    {
        long v = parseIntOr(envMaxLogBytes, -1);
        if (v > 0) maxLogBytes = v;
    }

    applyQuoteSources();
    sanityKnobs();

    setupPaths();
    selectTheme();
    installSignalHandlers();
    setupTerminal();

    printLogo();
    setupAudioSink();
    updateDateDay();
    stateReady = true;
    logEvent("Starting new study protocol: " ~ roundsLabel(rounds) ~ ", "
        ~ durationLabel(studyMin) ~ " study, "
        ~ durationLabel(breakMin) ~ " break");

    writeln(secondary ~ "Protocol:" ~ NC ~ " " ~ BOLD ~ roundsLabel(rounds)
        ~ NC ~ "  " ~ DIM ~ "|" ~ NC ~ "  " ~ BOLD
        ~ durationLabel(studyMin) ~ NC ~ " study  " ~ DIM ~ "|" ~ NC ~ "  "
        ~ BOLD ~ durationLabel(breakMin) ~ NC ~ " break  " ~ DIM ~ "|"
        ~ NC ~ "  " ~ BOLD ~ "Theme: " ~ themeName ~ NC);
    if (!configLoaded.empty)
        writeln(DIM ~ "Config: " ~ configLoaded ~ NC);
    writeln();

    foreach (round; 1 .. rounds + 1)
    {
        runPhase("study", studyMin, round, rounds);
        if (round < rounds)
            runPhase("break", breakMin, round, rounds);
    }

    finalizeSession();
    finalBanner();
    restoreTerminal();
    exit(0);
}

int main(string[] args)
{
    startWall = cast(long) time(null);
    envAlertSound = environment.get("ALERT_SOUND", "");
    envSinkName = environment.get("SINK_NAME", "");
    envStateDir = environment.get("STATE_DIR", "");
    envMaxLogBytes = environment.get("MAX_LOG_BYTES", "");
    envQuotes = environment.get("QUOTES", "");
    envTheme = environment.get("THEME", "");
    home = environment.get("HOME", "");
    alertSound = home != "" ? home ~ "/Videos/Alarm/n_alarm.mp3" : "";
    if (args.length > 0)
    {
        prog = baseName(args[0]);
        dir = dirName(absolutePath(args[0]));
        try dir = buildNormalizedPath(dir);
        catch (Exception) {}
    }
    try
    {
        runAll(args[1 .. $]);
    }
    catch (CrashExitException e)
    {
        onUnexpectedDeath(e.code);
        restoreTerminal();
        exit(e.code);
    }
    catch (Throwable e)
    {
        onUnexpectedDeath(1);
        restoreTerminal();
        stderr.writeln("OBS.d: internal error: " ~ e.msg);
        exit(1);
    }
    return 0;
}
