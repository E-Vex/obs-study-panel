// OBS.java - Study/break timer protocol (Java port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: Java 17+ (uses Process.pid()), bash (to load the bash-syntax
// config file).
//
// Build: javac OBS.java
// Usage: java OBS [options] <rounds> <study_minutes> <break_minutes>
// Stop:  Ctrl+C, or press 'q' while a phase is running
// Theme: press Alt+T while a phase is running (see --list-themes)
//
// NOTE: uses sun.misc.Signal for exact INT/TERM/HUP exit codes (130/143/129);
// the JDK prints an "internal proprietary API" warning when compiling this.
// That is expected and harmless - it is still fully functional on JDK 21.

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

public class OBS {
    // -----------------------------------------------------------------------
    // Color themes
    // -----------------------------------------------------------------------
    private static final String[][] THEMES = {
        {"Purple", "\u001b[1;35m", "\u001b[0;35m"},
        {"Ocean", "\u001b[1;36m", "\u001b[0;34m"},
        {"Forest", "\u001b[1;32m", "\u001b[0;32m"},
        {"Sunset", "\u001b[1;33m", "\u001b[0;31m"},
        {"Rose", "\u001b[1;95m", "\u001b[0;31m"},
        {"Gold", "\u001b[1;93m", "\u001b[0;33m"},
        {"Mono", "\u001b[1;37m", "\u001b[0;37m"},
        {"Ice", "\u001b[1;96m", "\u001b[0;36m"},
        {"Ember", "\u001b[1;91m", "\u001b[0;31m"},
        {"Neon", "\u001b[1;92m", "\u001b[0;96m"},
        {"Cobalt", "\u001b[1;34m", "\u001b[0;36m"},
        {"Cherry", "\u001b[1;91m", "\u001b[0;35m"},
    };

    private static final String BOLD = "\u001b[1m";
    private static final String DIM = "\u001b[2m";
    private static final String NC = "\u001b[0m";

    private static final String LOGO =
        " /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$\n"
        + "| $$_____/     | $$   | $$| $$_____/| $$  / $$\n"
        + "| $$           | $$   | $$| $$      |  $$/ $$/\n"
        + "| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \\  $$$$/\n"
        + "| $$__/|______/ \\  $$ $$/ | $$__/     >$$  $$\n"
        + "| $$             \\  $$$/  | $$       /$$/\\  $$\n"
        + "| $$$$$$$$        \\  $/   | $$$$$$$$| $$  \\ $$\n"
        + "|________/         \\_/    |________/|__/  |__/";

    private static final String[] DEFAULT_QUOTE_LIST = {
        "Focused effort beats scattered hours",
        "Every round finished is progress made",
        "Consistency beats intensity",
        "Start now, figure out the rest along the way",
        "A short break now means sharper focus next round",
    };

    // -----------------------------------------------------------------------
    // Mutable program state (mirrors the reference's global variables)
    // -----------------------------------------------------------------------
    static String prog = "OBS";
    static final long START_NANO = System.nanoTime();

    static String primary = THEMES[0][1];
    static String secondary = THEMES[0][2];
    static String themeName = THEMES[0][0];
    static int themeIndex = 0;
    static long themeNoticeUntil = 0;

    static final String envAlertSound = env("ALERT_SOUND");
    static final String envSinkName = env("SINK_NAME");
    static final String envStateDir = env("STATE_DIR");
    static final String envMaxLogBytes = env("MAX_LOG_BYTES");
    static final String envQuotes = env("QUOTES");
    static final String envTheme = env("THEME");

    static Path dir;
    static String alertSound = "";
    static String sinkName = "OBS_Alert_Sink";
    static String stateDir = "";
    static long maxLogBytes = 1048576;
    static long fileBarWidth = 20;
    static long nonTtyEnterTimeout = 300;
    static long alertPid = 0;
    static List<String> quoteList = new ArrayList<>();
    static long points = 0;
    static String lastDate = "";

    static String configFile = "";
    static boolean dryRun = false;
    static boolean useAlert = true;
    static boolean useSink = true;
    static int rounds = 0, studyMin = 0, breakMin = 0;
    static String cliTheme = "";
    static String durationUnit = "minutes";
    static int secondsPerUnit = 60;
    static String configTheme = "";
    static String configQuotes = "";
    static String configLoaded = "";

    static Path dateFile, dayFile, sessionFile, timerFile, logFile;
    static Path progressFile, pointsFile, messageFile, nextFile;
    static Path overlayFile, themeFile;

    static String sessionText = "";
    static String remainingStr = "00:00:00";
    static int pct = 0;
    static String nextText = "";
    static String messageText = "";
    static String lastDay = "";
    static boolean stateReady = false;
    static boolean stateFinalized = false;
    static boolean inCleanup = false;

    static String phaseLabel = "";
    static String phaseSubtitle = "";
    static String phaseNext = "";
    static long phaseTotal = 0;
    static long phaseElapsed = 0;
    static boolean phasePaused = false;
    static boolean phaseSkipped = false;
    static long phaseStart = 0;
    static long phasePausedTotal = 0;
    static long phasePauseAt = 0;

    static boolean stdinIsTty = false;
    static String savedTermSettings = null;
    static String key = "";
    static boolean keyRead = false;

    static final int TERM_BAR_WIDTH = 24;
    static final int BOX_INNER = 62;

    // -----------------------------------------------------------------------
    // Keyboard input: a reader thread feeds a queue; EOF is a sentinel.
    // -----------------------------------------------------------------------
    static final int EOF = -1;
    static final int EOF_MARKER = 256;   // bytes are 0-255
    static final BlockingQueue<Integer> inputQueue = new LinkedBlockingQueue<>();

    static void startInputReader() {
        Thread t = new Thread(() -> {
            byte[] buf = new byte[256];
            try {
                while (true) {
                    int n = System.in.read(buf);
                    if (n < 0) {
                        inputQueue.put(EOF_MARKER);
                        return;
                    }
                    for (int i = 0; i < n; i++) {
                        inputQueue.put((int) buf[i] & 0xff);
                    }
                }
            } catch (Exception e) {
                try {
                    inputQueue.put(EOF_MARKER);
                } catch (InterruptedException ie) { /* ignore */ }
            }
        });
        t.setDaemon(true);
        t.start();
    }

    static boolean sawEof = false;

    /** One byte with a timeout (seconds). Returns the byte (0-255),
     *  EOF (-1) when the input ended, or -2 on timeout. */
    static int waitByte(double timeout) {
        if (sawEof) return EOF;
        Integer b;
        try {
            b = inputQueue.poll((long) (timeout * 1000000000.0),
                                TimeUnit.NANOSECONDS);
        } catch (InterruptedException e) {
            return -2;
        }
        if (b == null) return -2;          // timeout
        if (b == EOF_MARKER) {
            sawEof = true;
            return EOF;                    // end of input
        }
        return b;
    }

    // -----------------------------------------------------------------------
    // Small helpers
    // -----------------------------------------------------------------------
    static String env(String name) {
        String v = System.getenv(name);
        return v == null ? "" : v;
    }

    static long nowSeconds() {
        return (long) ((System.nanoTime() - START_NANO) / 1e9);
    }

    static void out(String s) {
        System.out.print(s);
    }

    static void setTheme(int i) {
        if (i < 0 || i >= THEMES.length) return;
        themeIndex = i;
        themeName = THEMES[i][0];
        primary = THEMES[i][1];
        secondary = THEMES[i][2];
    }

    static int themeIndexOf(String want) {
        if (want == null || want.isEmpty()) return -1;
        for (int i = 0; i < THEMES.length; i++) {
            if (THEMES[i][0].equalsIgnoreCase(want)) return i;
        }
        return -1;
    }

    static void saveTheme() {
        if (themeFile != null) {
            try {
                Files.write(themeFile, (themeName + "\n")
                        .getBytes(StandardCharsets.UTF_8));
            } catch (IOException e) { /* best effort */ }
        }
    }

    static void cycleTheme() {
        setTheme((themeIndex + 1) % THEMES.length);
        saveTheme();
        themeNoticeUntil = nowSeconds() + 3;
        logEvent("Theme changed to: " + themeName);
    }

    static void printThemeList() {
        for (String[] t : THEMES) {
            out(String.format("  %-8s %s\u2588\u2588\u2588\u2588%s%n", t[0],
                    t[1], t[2]));
        }
    }

    static String fmtHms(long total) {
        return String.format("%02d:%02d:%02d", total / 3600,
                (total % 3600) / 60, total % 60);
    }

    static String makeBar(long filled, long width, String fill, String empty,
                          String head) {
        StringBuilder bar = new StringBuilder();
        for (long i = 0; i < width; i++) {
            if (i < filled) {
                bar.append(head != null && !head.isEmpty() && i == filled - 1
                        ? head : fill);
            } else {
                bar.append(empty);
            }
        }
        return bar.toString();
    }

    static String which(String cmd) {
        String pathEnv = System.getenv("PATH");
        if (pathEnv == null) return null;
        for (String p : pathEnv.split(File.pathSeparator)) {
            if (p.isEmpty()) continue;
            File f = new File(p, cmd);
            if (f.canExecute()) return f.getPath();
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Help and argument parsing
    // -----------------------------------------------------------------------
    static String helpText() {
        return String.format(
            "Usage: %s [options] <rounds> <study_minutes> <break_minutes>%n%n"
            + "Runs a Pomodoro-style study/break loop and writes the live state to text%n"
            + "files that OBS Studio can display as \"Text (read from file)\" sources.%n%n"
            + "Options:%n"
            + "  -h, --help          Show this help and exit%n"
            + "  -c, --config FILE   Load settings from FILE (bash syntax)%n"
            + "  -d, --dry-run       Treat the durations as seconds (fast testing)%n"
            + "  -n, --no-alert      Disable the audio alert%n"
            + "  -s, --no-sink       Don't create or use the OBS virtual audio sink%n"
            + "  -t, --theme NAME    Use a color theme (see --list-themes)%n"
            + "      --list-themes   Show the available color themes and exit%n%n"
            + "Arguments:%n"
            + "  rounds             1-50   number of study rounds%n"
            + "  study_minutes      1-600  length of a study phase%n"
            + "  break_minutes      1-120  length of a break phase%n%n"
            + "Examples:%n"
            + "  %s 5 50 10           # 5 rounds, 50 min study, 10 min break%n"
            + "  %s --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break%n"
            + "  %s --theme Ocean 5 50 10%n%n"
            + "Keys (while a phase is running):%n"
            + "  p / space   pause and resume the current phase%n"
            + "  s           skip the rest of the current phase%n"
            + "  q           quit the session%n"
            + "  Alt+T       switch to the next color theme%n%n"
            + "Environment overrides:%n"
            + "  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME%n%n"
            + "Config file (first one that exists):%n"
            + "  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config%n",
            prog, prog, prog, prog);
    }

    static void printHelp(int code, boolean toStderr) {
        if (toStderr) {
            System.err.print(helpText());
        } else {
            System.out.print(helpText());
        }
        System.exit(code);
    }

    static void usageError() {
        printHelp(1, true);
    }

    static boolean validNumber(String s) {
        if (s == null || s.isEmpty() || s.length() > 4
                || s.charAt(0) < '1' || s.charAt(0) > '9') {
            return false;
        }
        for (char c : s.toCharArray()) {
            if (c < '0' || c > '9') return false;
        }
        return true;
    }

    static void parseArgs(String[] argv) {
        List<String> args = new ArrayList<>();
        Deque<String> rest = new ArrayDeque<>();
        for (String a : argv) rest.add(a);
        List<String> pos = new ArrayList<>();
        boolean done = false;
        while (!done && !rest.isEmpty()) {
            String a = rest.peek();
            if (a.equals("-h") || a.equals("--help")) {
                printHelp(0, false);
            } else if (a.equals("-c") || a.equals("--config")) {
                if (rest.size() < 2) {
                    System.err.println("Error: " + a + " needs a file argument");
                    usageError();
                }
                rest.remove();
                configFile = rest.remove();
            } else if (a.equals("-d") || a.equals("--dry-run")) {
                dryRun = true;
                rest.remove();
            } else if (a.equals("-n") || a.equals("--no-alert")) {
                useAlert = false;
                rest.remove();
            } else if (a.equals("-s") || a.equals("--no-sink")) {
                useSink = false;
                rest.remove();
            } else if (a.equals("-t") || a.equals("--theme")) {
                if (rest.size() < 2) {
                    System.err.println("Error: " + a + " needs a theme name");
                    usageError();
                }
                rest.remove();
                cliTheme = rest.remove();
            } else if (a.equals("--list-themes")) {
                printThemeList();
                System.exit(0);
            } else if (a.equals("--")) {
                rest.remove();
                pos.addAll(rest);
                rest.clear();
                done = true;
            } else if (a.startsWith("-")) {
                System.err.println("Error: unknown option: " + a);
                usageError();
            } else {
                pos.addAll(rest);
                rest.clear();
                done = true;
            }
        }
        if (pos.size() != 3) usageError();
        for (String v : pos) {
            if (!validNumber(v)) usageError();
        }
        rounds = Integer.parseInt(pos.get(0));
        studyMin = Integer.parseInt(pos.get(1));
        breakMin = Integer.parseInt(pos.get(2));
        if (rounds > 50) {
            System.err.println("Error: rounds must be <= 50");
            usageError();
        }
        if (studyMin > 600) {
            System.err.println("Error: study minutes must be <= 600");
            usageError();
        }
        if (breakMin > 120) {
            System.err.println("Error: break minutes must be <= 120");
            usageError();
        }
        if (dryRun) {
            durationUnit = "seconds";
            secondsPerUnit = 1;
        }
    }

    // -----------------------------------------------------------------------
    // Configuration file
    // -----------------------------------------------------------------------
    // The config file is bash source code (exactly like the reference). It is
    // interpreted by a child bash that first seeds the pre-config default
    // knobs, sources the file, and then dumps the resulting values: unit
    // separator 0x1F between key and value, record separator 0x1E between
    // records. A sourced file that calls `exit N` terminates the child before
    // the dump is written, which this program detects and mirrors.
    static final String CONFIG_DUMP_SH =
        "set -u\n"
        + "IFS=$'\\037' read -r -a QUOTE_LIST <<< \"${QUOTES_SEED-}\"\n"
        + "unset QUOTES_SEED\n"
        + "source \"$1\" || true\n"
        + "{\n"
        + "  d() { printf '%s\\037%s\\036' \"$1\" \"${2-}\"; }\n"
        + "  d ALERT_SOUND \"${ALERT_SOUND-}\"\n"
        + "  d SINK_NAME \"${SINK_NAME-}\"\n"
        + "  d STATE_DIR \"${STATE_DIR-}\"\n"
        + "  d MAX_LOG_BYTES \"${MAX_LOG_BYTES-}\"\n"
        + "  d FILE_BAR_WIDTH \"${FILE_BAR_WIDTH-}\"\n"
        + "  d NON_TTY_ENTER_TIMEOUT \"${NON_TTY_ENTER_TIMEOUT-}\"\n"
        + "  d THEME \"${THEME-}\"\n"
        + "  d POINTS \"${POINTS-}\"\n"
        + "  d LAST_DATE \"${LAST_DATE-}\"\n"
        + "  d QUOTES \"${QUOTES-}\"\n"
        + "  for q in ${QUOTE_LIST[@]+\"${QUOTE_LIST[@]}\"}; do d QUOTE \"$q\"; done\n"
        + "} > \"$2\"\n";

    static String findConfigFile() {
        if (!configFile.isEmpty()) return configFile;
        String p = env("OBS_PANEL_CONFIG");
        if (!p.isEmpty()) return p;
        String xdgBase = env("XDG_CONFIG_HOME");
        if (xdgBase.isEmpty()) {
            xdgBase = env("HOME") + "/.config";
        }
        Path xdg = Paths.get(xdgBase, "obs-study-panel", "config");
        if (Files.isRegularFile(xdg)) return xdg.toString();
        Path local = dir.resolve("obs-panel.conf");
        if (Files.isRegularFile(local)) return local.toString();
        return null;
    }

    static void quotesToList(String raw) {
        quoteList.clear();
        for (String line : raw.split("\n", -1)) {
            while (line.endsWith("\r")) line = line.substring(0, line.length() - 1);
            if (!line.isEmpty()) quoteList.add(line);
        }
    }

    static void loadConfig(String path) {
        if (!Files.isReadable(Paths.get(path))) {
            System.err.println("Error: config file is not readable: " + path);
            System.exit(1);
        }
        // Syntax check up front, exactly like the reference.
        if (which("bash") == null) {
            System.err.println("Error: bash is required to read the config file: "
                    + path);
            System.exit(1);
        }
        ProcessBuilder pb = new ProcessBuilder("bash", "-n", path);
        pb.redirectErrorStream(true);
        try {
            Process p = pb.start();
            String output = new String(p.getInputStream().readAllBytes(),
                    StandardCharsets.UTF_8);
            int rc = p.waitFor();
            if (rc != 0) {
                System.err.println("Error: syntax error in config file: " + path);
                String[] lines = output.split("\n");
                int shown = 0;
                for (String l : lines) {
                    if (l.trim().isEmpty()) continue;
                    System.err.println(l);
                    if (++shown >= 3) break;
                }
                System.exit(1);
            }
        } catch (IOException | InterruptedException e) {
            System.exit(1);
        }

        Path dumpPath;
        try {
            dumpPath = Files.createTempFile("obs-panel-conf-", "");
        } catch (IOException e) {
            System.exit(1);
            return;
        }

        // Seed the pre-config defaults in the child environment.
        ProcessBuilder pb2 = new ProcessBuilder("bash", "-c", CONFIG_DUMP_SH,
                "obs-panel", path, dumpPath.toString());
        Map<String, String> envMap = new HashMap<>(System.getenv());
        envMap.put("ALERT_SOUND", alertSound);
        envMap.put("SINK_NAME", sinkName);
        envMap.put("STATE_DIR", "");
        envMap.put("MAX_LOG_BYTES", "1048576");
        envMap.put("FILE_BAR_WIDTH", "20");
        envMap.put("NON_TTY_ENTER_TIMEOUT", "300");
        envMap.put("POINTS", Long.toString(points));
        envMap.put("LAST_DATE", lastDate);
        envMap.put("QUOTES_SEED", String.join("\u001f", quoteList));
        pb2.environment().clear();
        pb2.environment().putAll(envMap);
        pb2.inheritIO();
        int cRc = 1;
        try {
            Process p = pb2.start();
            cRc = p.waitFor();
        } catch (IOException | InterruptedException e) {
            // fall through with rc 1
        }

        String raw;
        try {
            raw = new String(Files.readAllBytes(dumpPath),
                    StandardCharsets.UTF_8);
            Files.deleteIfExists(dumpPath);
        } catch (IOException e) {
            raw = "";
        }

        if (raw.isEmpty()) {
            // The config called exit N before the dump was written.
            System.exit(cRc != 0 ? cRc : 1);
        }

        Map<String, String> values = new HashMap<>();
        List<String> quotes = new ArrayList<>();
        for (String record : raw.split("\u001e", -1)) {
            if (record.isEmpty()) continue;
            int i = record.indexOf('\u001f');
            if (i < 0) continue;
            String k = record.substring(0, i);
            String v = record.substring(i + 1);
            if (k.equals("QUOTE")) {
                quotes.add(v);
            } else {
                values.put(k, v);
            }
        }

        if (values.containsKey("ALERT_SOUND")) alertSound = values.get("ALERT_SOUND");
        if (values.containsKey("SINK_NAME")) sinkName = values.get("SINK_NAME");
        stateDir = values.getOrDefault("STATE_DIR", "");
        maxLogBytes = parseLongOr(values.get("MAX_LOG_BYTES"), 1048576);
        if (maxLogBytes <= 0) maxLogBytes = 1048576;
        fileBarWidth = parseLongOr(values.get("FILE_BAR_WIDTH"), 20);
        if (fileBarWidth <= 0 || fileBarWidth > 200) fileBarWidth = 20;
        nonTtyEnterTimeout = parseLongOr(values.get("NON_TTY_ENTER_TIMEOUT"), 300);
        if (nonTtyEnterTimeout <= 0 || nonTtyEnterTimeout > 3600)
            nonTtyEnterTimeout = 300;
        configTheme = values.getOrDefault("THEME", "");
        points = parseLongOr(values.get("POINTS"), 0);
        lastDate = values.getOrDefault("LAST_DATE", "");
        configQuotes = values.getOrDefault("QUOTES", "");
        quoteList = quotes;
        configLoaded = path;
    }

    static long parseLongOr(String v, long dflt) {
        if (v == null || v.isEmpty()) return dflt;
        try {
            return Long.parseLong(v.trim());
        } catch (NumberFormatException e) {
            return dflt;
        }
    }

    static void applyQuoteSources() {
        if (!envQuotes.isEmpty()) quotesToList(envQuotes);
        else if (!configQuotes.isEmpty()) quotesToList(configQuotes);
    }

    // -----------------------------------------------------------------------
    // Paths and theme selection
    // -----------------------------------------------------------------------
    static void setupPaths() {
        if (stateDir.isEmpty()) stateDir = dir.toString();
        try {
            Files.createDirectories(Paths.get(stateDir));
        } catch (IOException e) {
            System.err.println("Error: cannot create state dir: " + stateDir);
            System.exit(1);
        }
        Path base = Paths.get(stateDir);
        dateFile = base.resolve("date.txt");
        dayFile = base.resolve("day.txt");
        sessionFile = base.resolve("session.txt");
        timerFile = base.resolve("timer.txt");
        logFile = base.resolve("log.txt");
        progressFile = base.resolve("progress.txt");
        pointsFile = base.resolve("points.txt");
        messageFile = base.resolve("message.txt");
        nextFile = base.resolve("next.txt");
        overlayFile = base.resolve("overlay.txt");
        themeFile = base.resolve("theme.txt");
    }

    static void selectTheme() {
        String request = cliTheme;
        if (request.isEmpty()) request = envTheme;
        if (request.isEmpty()) request = configTheme;
        if (request.isEmpty() && themeFile != null
                && Files.isRegularFile(themeFile)) {
            try {
                List<String> lines = Files.readAllLines(themeFile,
                        StandardCharsets.UTF_8);
                if (!lines.isEmpty()) request = lines.get(0);
            } catch (IOException e) { /* best effort */ }
        }
        if (!request.isEmpty()) {
            int idx = themeIndexOf(request);
            if (idx < 0) {
                System.err.println("Warning: unknown theme '" + request
                        + "', using " + themeName);
            } else {
                setTheme(idx);
            }
        }
    }

    // -----------------------------------------------------------------------
    // OBS state files
    // -----------------------------------------------------------------------
    static void writeStateFile(Path path, String text) {
        try {
            Files.write(path, (text + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) { /* best effort */ }
    }

    static void updateDateDay() {
        LocalDateTime now = LocalDateTime.now();
        String d = now.format(DateTimeFormatter.ofPattern("yyyy-MM-dd"));
        if (d.equals(lastDate)) return;
        lastDate = d;
        lastDay = now.getDayOfWeek().getDisplayName(
                java.time.format.TextStyle.FULL, Locale.ENGLISH);
        writeStateFile(dateFile, d);
        writeStateFile(dayFile, lastDay);
    }

    static void syncState() {
        updateDateDay();
        publishState();
    }

    static void publishState() {
        long filled = (long) pct * fileBarWidth / 100;
        String bar = makeBar(filled, fileBarWidth, "#", "-", null);
        String pctS = String.format("%3d%%", pct);

        writeStateFile(sessionFile, sessionText);
        writeStateFile(timerFile, remainingStr);
        writeStateFile(pointsFile, Long.toString(points));
        writeStateFile(nextFile, nextText);
        writeStateFile(messageFile, messageText);
        writeStateFile(progressFile, "[" + bar + "] " + pctS);

        StringBuilder sb = new StringBuilder();
        sb.append(lastDate).append(' ').append(lastDay).append('\n');
        sb.append(sessionText).append('\n');
        sb.append(remainingStr).append('\n');
        sb.append('[').append(bar).append("] ").append(pctS).append('\n');
        sb.append("Pts: ").append(points).append('\n');
        sb.append("Next: ").append(nextText).append('\n');
        if (!messageText.isEmpty()) sb.append(messageText).append('\n');
        try {
            Files.write(overlayFile,
                    sb.toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) { /* best effort */ }
    }

    static void rotateLogIfNeeded() {
        try {
            if (Files.isRegularFile(logFile)
                    && Files.size(logFile) >= maxLogBytes) {
                Files.move(logFile, logFile.resolveSibling("log.txt.1"),
                        java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                Files.write(logFile, new byte[0]);
            }
        } catch (IOException e) { /* best effort */ }
    }

    static void logEvent(String msg) {
        rotateLogIfNeeded();
        try {
            Files.write(logFile, ("["
                    + LocalDateTime.now().format(
                        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"))
                    + "] " + msg + "\n").getBytes(StandardCharsets.UTF_8),
                    java.nio.file.StandardOpenOption.APPEND,
                    java.nio.file.StandardOpenOption.CREATE);
        } catch (IOException e) { /* best effort */ }
    }

    // -----------------------------------------------------------------------
    // Audio alerts
    // -----------------------------------------------------------------------
    static boolean sinkIsReady() {
        if (which("pactl") == null) return false;
        try {
            Process p = new ProcessBuilder("pactl", "list", "short", "sinks")
                    .redirectErrorStream(false).start();
            BufferedReader r = new BufferedReader(new InputStreamReader(
                    p.getInputStream(), StandardCharsets.UTF_8));
            String line;
            boolean found = false;
            while ((line = r.readLine()) != null) {
                String[] fields = line.trim().split("\\s+");
                if (fields.length > 1 && fields[1].equals(sinkName)) {
                    found = true;
                    break;
                }
            }
            p.waitFor();
            return found;
        } catch (IOException | InterruptedException e) {
            return false;
        }
    }

    static void setupAudioSink() {
        if (!useSink) return;
        if (which("pactl") == null) return;
        if (sinkIsReady()) return;
        try {
            new ProcessBuilder("pactl", "load-module", "module-null-sink",
                    "sink_name=" + sinkName,
                    "sink_properties=device.description=" + sinkName)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .start().waitFor();
        } catch (IOException | InterruptedException e) { /* best effort */ }
    }

    static void stopAlert() {
        if (alertPid > 0) {
            try {
                new ProcessBuilder("kill", Long.toString(alertPid))
                        .start().waitFor();
            } catch (IOException | InterruptedException e) { /* already gone */ }
            alertPid = 0;
        }
    }

    static void playAlert() {
        if (!useAlert) return;
        stopAlert();
        boolean fileOk = !alertSound.isEmpty()
                && Files.isRegularFile(Paths.get(alertSound));
        if (!fileOk) {
            out(String.format("%s(alert file not found: %s)%s%n", DIM,
                    alertSound.isEmpty() ? "none" : alertSound, NC));
            return;
        }

        List<String> player = null;
        if (which("mpv") != null) {
            player = List.of("mpv", "--no-video", "--volume=70");
        } else if (which("paplay") != null) {
            player = List.of("paplay");
        } else if (which("ffplay") != null) {
            player = List.of("ffplay", "-nodisp", "-autoexit");
        } else if (which("cvlc") != null) {
            player = List.of("cvlc", "--play-and-exit", "--no-video", "--volume=70");
        } else {
            out(String.format("%s(no audio player found - install mpv / paplay / ffplay)%s%n",
                    DIM, NC));
            return;
        }

        if (useSink && !sinkIsReady()) setupAudioSink();

        try {
            List<String> argv = new ArrayList<>(player);
            argv.add(alertSound);
            ProcessBuilder pb = new ProcessBuilder(argv);
            pb.redirectOutput(ProcessBuilder.Redirect.DISCARD);
            pb.redirectError(ProcessBuilder.Redirect.DISCARD);
            if (useSink && sinkIsReady()) {
                pb.environment().put("PULSE_SINK", sinkName);
            }
            Process p = pb.start();
            alertPid = p.pid();
        } catch (IOException e) { /* best effort */ }

        if (useSink && sinkIsReady()) {
            out(String.format("%s-> alert on OBS sink (%s)%s%n", DIM, sinkName, NC));
        } else {
            out(String.format("%s-> alert on default device (OBS sink unavailable)%s%n",
                    secondary, NC));
        }
    }

    // -----------------------------------------------------------------------
    // Terminal handling (stty on the controlling terminal)
    // -----------------------------------------------------------------------
    static String runSttyCapture(String[] argv) {
        try {
            ProcessBuilder pb = new ProcessBuilder(argv);
            pb.redirectInput(ProcessBuilder.Redirect.INHERIT);
            Process p = pb.start();
            String out = new String(p.getInputStream().readAllBytes(),
                    StandardCharsets.UTF_8);
            p.waitFor();
            return out.trim();
        } catch (IOException | InterruptedException e) {
            return "";
        }
    }

    static void runStty(String[] argv) {
        try {
            ProcessBuilder pb = new ProcessBuilder(argv);
            pb.redirectInput(ProcessBuilder.Redirect.INHERIT);
            pb.redirectOutput(ProcessBuilder.Redirect.DISCARD);
            pb.redirectError(ProcessBuilder.Redirect.DISCARD);
            pb.start().waitFor();
        } catch (IOException | InterruptedException e) { /* best effort */ }
    }

    static void setupTerminal() {
        stdinIsTty = isattyProbe();
        if (!stdinIsTty) return;
        savedTermSettings = runSttyCapture(new String[] { "stty", "-g" });
        runStty(new String[] { "stty", "-icanon", "-echo" });
    }

    /* The reference checks stdin only (bash [[ -t 0 ]]) - not stdout - so
     * probe the same way via the shell (stdin inherited). */
    static boolean isattyProbe() {
        try {
            ProcessBuilder pb = new ProcessBuilder("sh", "-c",
                    "test -t 0 && echo tty || echo no");
            pb.redirectInput(ProcessBuilder.Redirect.INHERIT);
            Process p = pb.start();
            String line = new String(p.getInputStream().readAllBytes(),
                    StandardCharsets.UTF_8).trim();
            p.waitFor();
            return "tty".equals(line);
        } catch (IOException | InterruptedException e) {
            return System.console() != null;
        }
    }

    static void restoreTerminal() {
        if (!stdinIsTty) return;
        if (savedTermSettings != null && !savedTermSettings.isEmpty()) {
            runStty(new String[] { "stty", savedTermSettings });
        } else {
            runStty(new String[] { "stty", "sane" });
        }
        savedTermSettings = null;
    }

    static void waitKey(double timeout) {
        key = "";
        keyRead = false;
        if (!stdinIsTty) {
            try {
                Thread.sleep((long) (timeout * 1000));
            } catch (InterruptedException e) { /* best effort */ }
            return;
        }
        int b = waitByte(timeout);
        if (b < 0) return;                 // timeout or EOF: no key
        keyRead = true;
        if (b == 0x1b) {
            int nxt = waitByte(0.3);
            if (nxt == 't' || nxt == 'T') key = "alt-t";
        } else {
            key = new String(new byte[] { (byte) b },
                    StandardCharsets.ISO_8859_1);
        }
    }

    static void discardPendingInput() {
        if (!stdinIsTty) return;
        while (true) {
            int b = waitByte(0.01);
            if (b <= 0) return;
        }
    }

    static void waitForEnter() {
        if (stdinIsTty) {
            while (true) {
                int b = waitByte(1);
                if (b == EOF) return;
                if (b == -2) {
                    updateDateDay();
                    continue;
                }
                if (b == '\n') return;
            }
        }
        long waited = 0;
        while (waited < nonTtyEnterTimeout) {
            long sliceStart = System.nanoTime();
            while (true) {
                double elapsed = (System.nanoTime() - sliceStart) / 1e9;
                if (elapsed >= 5.0) {
                    waited += 5;
                    break;
                }
                int b = waitByte(5.0 - elapsed);
                if (b == EOF) return;
                if (b == -2) {
                    waited += 5;
                    break;
                }
                if (b == '\n') return;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Status / progress UI
    // -----------------------------------------------------------------------
    static String phaseColor(String label) {
        return label.equals("STUDY") ? primary : secondary;
    }

    static String durationLabel(int n) {
        if (n == 1) {
            return durationUnit.equals("seconds") ? "1 second" : "1 minute";
        }
        return n + " " + durationUnit;
    }

    static String roundsLabel(int n) {
        return n == 1 ? "1 round" : n + " rounds";
    }

    static void drawStatus(String label, int round, int totalRounds,
                           long elapsed, long total, boolean paused) {
        long filled = 0;
        if (total > 0) filled = elapsed * TERM_BAR_WIDTH / total;
        if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH;
        String bar = makeBar(filled, TERM_BAR_WIDTH, "=", " ", ">");
        String color = phaseColor(label);
        StringBuilder flag = new StringBuilder();
        if (paused) flag.append(primary).append(" PAUSED").append(NC);
        if (nowSeconds() < themeNoticeUntil) {
            flag.append("  ").append(DIM).append("Theme: ")
               .append(themeName).append(NC);
        }
        out("\r\u001b[K");
        out(String.format("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
                BOLD, color, label, NC, round, totalRounds,
                color, bar, NC, pct, remainingStr,
                primary, points, NC, flag.toString()));
    }

    static void boxRow(String color, String plain, String styled) {
        int pad = BOX_INNER - plain.length();
        if (pad < 0) pad = 0;
        out(String.format("%s\u2551%s%s%s\u2551%s%n", color, styled,
                " ".repeat(pad), color, NC));
    }

    static void phaseHeader(String label, int round, int total, int minutes,
                           String subtitle) {
        if (subtitle.length() > BOX_INNER - 4) {
            subtitle = subtitle.substring(0, BOX_INNER - 4);
        }
        String color = phaseColor(label);
        String bar = "\u2550".repeat(BOX_INNER);
        String dur = durationLabel(minutes);
        String info = String.format("%s  \u00b7  Round %d / %d  \u00b7  %s",
                label, round, total, dur);
        String styled1 = String.format(
                "  %s%s%s%s  \u00b7  Round %d / %d  \u00b7  %s",
                BOLD, label, NC, color, round, total, dur);
        String styled2 = "  " + DIM + subtitle + NC + color;
        out(String.format("%n"));
        out(String.format("%s\u2554%s\u2557%s%n", color, bar, NC));
        boxRow(color, "  " + info, styled1);
        boxRow(color, "  " + subtitle, styled2);
        if (stdinIsTty) {
            String keys = "  p pause  \u00b7  s skip  \u00b7  q quit  \u00b7  Alt+T theme";
            boxRow(color, keys, DIM + keys + NC + color);
        }
        out(String.format("%s\u255a%s\u255d%s%n", color, bar, NC));
        out(String.format("%n"));
    }

    static void showCompletion(String phase, int round, int totalRounds,
                              String nextPhase, boolean skipped) {
        int width = 60;
        String line = "=".repeat(width);
        String title;
        if (skipped) title = "PHASE SKIPPED";
        else if (phase.equals("STUDY")) title = "STUDY SESSION COMPLETE";
        else title = "BREAK COMPLETE";
        String color = phaseColor(phase);
        int pad = (width + title.length()) / 2;
        out(String.format("%n"));
        out(String.format("%s%s%s%n", color, line, NC));
        out(String.format("%s%s%s%s%n", color, " ".repeat(pad), title, NC));
        out(String.format("%s%s%s%n", color, line, NC));
        out(String.format("%n"));
        out(String.format("  Round:   %s%d%s / %d%n", BOLD, round, NC,
                totalRounds));
        out(String.format("  Points:  %s%d%s%n", primary, points, NC));
        out(String.format("%n"));
        if (nextPhase.equals("None")) {
            out(String.format("  Next:    %sSession complete%s%n", DIM, NC));
        } else {
            out(String.format("  Next:    %s%s%s%n", BOLD, nextPhase, NC));
        }
        out(String.format("%n"));
        out(String.format("  %sPress Enter to continue...%s", primary, NC));
    }

    // -----------------------------------------------------------------------
    // Phase runner
    // -----------------------------------------------------------------------
    static void phasePrepare(String ptype, int minutes, int round,
                             int totalRounds) {
        Random rnd = new Random();
        if (ptype.equals("study")) {
            phaseLabel = "STUDY";
            if (!quoteList.isEmpty()) {
                phaseSubtitle = quoteList.get(rnd.nextInt(quoteList.size()));
            } else {
                phaseSubtitle = "Stay focused.";
            }
        } else {
            phaseLabel = "BREAK";
            phaseSubtitle = "Relax and recharge.";
        }

        if (ptype.equals("study")) {
            if (round < totalRounds) {
                phaseNext = "Break (" + durationLabel(breakMin) + ")";
            } else {
                phaseNext = "None";
            }
        } else {
            phaseNext = "Study (" + durationLabel(studyMin) + ")";
        }

        phaseTotal = (long) minutes * secondsPerUnit;
        phaseElapsed = 0;
        phasePaused = false;
        phaseSkipped = false;
        phaseStart = nowSeconds();
        phasePausedTotal = 0;
        phasePauseAt = 0;

        sessionText = String.format("%s %d/%d", phaseLabel, round, totalRounds);
        remainingStr = fmtHms(phaseTotal);
        pct = 0;
        nextText = phaseNext.equals("None") ? "Session complete" : phaseNext;
        messageText = phaseSubtitle;

        logEvent(String.format("Start: %s %d/%d (%s)", phaseLabel, round,
                totalRounds, durationLabel(minutes)));
        phaseHeader(phaseLabel, round, totalRounds, minutes, phaseSubtitle);
        syncState();
    }

    static void phaseHandleKey(int round, int totalRounds) {
        if (key.equals("p") || key.equals("P") || key.equals(" ")) {
            if (phasePaused) {
                phasePausedTotal += nowSeconds() - phasePauseAt;
                phasePaused = false;
                logEvent(String.format("Resumed: %s %d/%d", phaseLabel, round,
                        totalRounds));
            } else {
                phasePaused = true;
                phasePauseAt = nowSeconds();
                logEvent(String.format("Paused: %s %d/%d", phaseLabel, round,
                        totalRounds));
            }
        } else if (key.equals("s") || key.equals("S")) {
            phaseSkipped = true;
            logEvent(String.format("Skipped: %s %d/%d", phaseLabel, round,
                    totalRounds));
        } else if (key.equals("q") || key.equals("Q")) {
            logEvent("Quit requested by user");
            cleanup(0);
        } else if (key.equals("alt-t")) {
            cycleTheme();
        }
    }

    static void phaseCount(int round, int totalRounds) {
        while (phaseElapsed < phaseTotal) {
            long remaining = phaseTotal - phaseElapsed;
            if (remaining < 0) remaining = 0;
            remainingStr = fmtHms(remaining);
            pct = phaseTotal > 0 ? (int) (phaseElapsed * 100 / phaseTotal) : 0;
            if (pct > 100) pct = 100;
            sessionText = String.format("%s %d/%d", phaseLabel, round,
                    totalRounds);
            if (phasePaused) sessionText += " (PAUSED)";

            syncState();
            drawStatus(phaseLabel, round, totalRounds, phaseElapsed,
                    phaseTotal, phasePaused);

            waitKey(1);
            if (keyRead) {
                phaseHandleKey(round, totalRounds);
                if (phaseSkipped) break;
            }
            // CRASH-INJECT-POINT
            if (!phasePaused) {
                phaseElapsed = nowSeconds() - phaseStart - phasePausedTotal;
            }
        }
    }

    static void phaseFinish(int round, int totalRounds) {
        if (phaseSkipped) {
            sessionText = String.format("%s %d/%d (SKIPPED)", phaseLabel,
                    round, totalRounds);
        } else {
            pct = 100;
            points += 1;
        }
        remainingStr = "00:00:00";
        syncState();
        drawStatus(phaseLabel, round, totalRounds, phaseElapsed, phaseTotal,
                false);
        out(String.format("%n"));
        logEvent(String.format("End: %s %d/%d", phaseLabel, round,
                totalRounds));

        playAlert();

        discardPendingInput();
        showCompletion(phaseLabel, round, totalRounds, phaseNext,
                phaseSkipped);
        waitForEnter();
        stopAlert();
        out(String.format("%n"));
    }

    static void runPhase(String ptype, int minutes, int round, int totalRounds) {
        phasePrepare(ptype, minutes, round, totalRounds);
        phaseCount(round, totalRounds);
        phaseFinish(round, totalRounds);
    }

    // -----------------------------------------------------------------------
    // Cleanup
    // -----------------------------------------------------------------------
    static void resetStateFiles() {
        sessionText = "stopped";
        remainingStr = "00:00:00";
        pct = 0;
        nextText = "";
        syncState();
    }

    static void cleanup(int code) {
        if (inCleanup) return;
        inCleanup = true;
        stateFinalized = true;
        stopAlert();
        resetStateFiles();
        logEvent("Protocol stopped manually");
        out(String.format("%n"));
        out(String.format("%s%sInterrupted.%s %sState files reset to stopped.%s%n",
                secondary, BOLD, NC, DIM, NC));
        restoreTerminal();
        System.exit(code);
    }

    static void onUnexpectedDeath(int rc) {
        if (!stateReady || stateFinalized) return;
        stateFinalized = true;
        stopAlert();
        resetStateFiles();
        logEvent("Protocol ended unexpectedly (exit " + rc + ")");
    }

    static void finalizeSession() {
        sessionText = "session complete";
        remainingStr = "00:00:00";
        pct = 100;
        nextText = "";
        syncState();
        stateFinalized = true;
        logEvent("Protocol complete - total points: " + points);
    }

    static void finalBanner() {
        int bannerWidth = 60;
        String title = "ALL SESSIONS COMPLETE";
        int inner = bannerWidth - 2;
        int pad = (inner - title.length()) / 2;
        String border = "#".repeat(bannerWidth);
        out(String.format("%n"));
        out(String.format("%s%s%s%n", primary, border, NC));
        out(String.format("%s#%s%s%s%s%s%s#%s%n", primary, NC,
                " ".repeat(pad), BOLD, title,
                " ".repeat(inner - pad - title.length()), NC, primary));
        out(String.format("%s%s%s%n", primary, border, NC));
        out(String.format("%n"));
        out(String.format("  %sTotal Rounds:%s  %s%d%s%n", BOLD, NC, primary,
                rounds, NC));
        out(String.format("  %sTotal Points:%s %s%d%s%n", BOLD, NC, primary,
                points, NC));
        out(String.format("%n"));
        out(String.format("%s%sGreat work!%s %sExiting.%s%n", primary, BOLD,
                NC, DIM, NC));
    }

    static void printLogo() {
        out(primary + String.format("%n"));
        out(LOGO + String.format("%n"));
        out(NC + String.format("%n"));
        out(String.format("%s%s     Study / Break Timer Protocol%s%n",
                primary, BOLD, NC));
        out(String.format("%s\u2500\u2500 live state written to date "
                + "\u00b7 day \u00b7 session \u00b7 timer \u00b7 log%s%n", DIM, NC));
        out(String.format("%n"));
    }

    // -----------------------------------------------------------------------
    // Main
    // -----------------------------------------------------------------------
    public static void main(String[] argv) throws Exception {
        prog = "OBS";   // the class name (basename of the java invocation)
        dir = Paths.get(OBS.class.getProtectionDomain().getCodeSource()
                .getLocation().toURI()).getParent();
        if (dir == null) dir = Paths.get(".");

        if (!env("HOME").isEmpty()) {
            alertSound = env("HOME") + "/Videos/Alarm/n_alarm.mp3";
        }
        quoteList.addAll(java.util.Arrays.asList(DEFAULT_QUOTE_LIST));

        parseArgs(argv);

        String cfg = findConfigFile();
        if (cfg != null) loadConfig(cfg);

        // Environment variables beat the config file.
        if (!envAlertSound.isEmpty()) alertSound = envAlertSound;
        if (!envSinkName.isEmpty()) sinkName = envSinkName;
        if (!envStateDir.isEmpty()) stateDir = envStateDir;
        if (!envMaxLogBytes.isEmpty()) {
            try {
                long v = Long.parseLong(envMaxLogBytes.trim());
                if (v > 0) maxLogBytes = v;
            } catch (NumberFormatException e) { /* keep default */ }
        }

        applyQuoteSources();
        setupPaths();
        selectTheme();

        // The EXIT-trap equivalent: runs on System.exit and on JVM shutdown
        // (including uncaught exceptions); resets the state files when the
        // session had not finalized. It must not change the exit code.
        Runtime.getRuntime().addShutdownHook(new Thread(OBS::shutdownHook));

        // Signals: conventional exit codes 128 + signal number.
        installSignal("INT", 130);
        installSignal("TERM", 143);
        installSignal("HUP", 129);

        startInputReader();
        setupTerminal();

        printLogo();
        setupAudioSink();
        updateDateDay();
        stateReady = true;
        logEvent(String.format("Starting new study protocol: %s, %s study, %s break",
                roundsLabel(rounds), durationLabel(studyMin),
                durationLabel(breakMin)));

        out(String.format("%sProtocol:%s %s%s%s  %s|%s  %s%s%s study  %s|%s  "
                        + "%s%s%s break  %s|%s  %sTheme: %s%s%n",
                secondary, NC, BOLD, roundsLabel(rounds), NC, DIM, NC,
                BOLD, durationLabel(studyMin), NC, DIM, NC, BOLD,
                durationLabel(breakMin), NC, DIM, NC, BOLD, themeName, NC));
        if (!configLoaded.isEmpty()) {
            out(String.format("%sConfig: %s%s%n", DIM, configLoaded, NC));
        }
        out(String.format("%n"));

        try {
            for (int round = 1; round <= rounds; round++) {
                runPhase("study", studyMin, round, rounds);
                if (round < rounds) {
                    runPhase("break", breakMin, round, rounds);
                }
            }
        } catch (RuntimeException e) {
            // An unexpected runtime error resets the files and exits with 1.
            e.printStackTrace();
            onUnexpectedDeath(1);
            restoreTerminal();
            System.exit(1);
        }

        finalizeSession();
        finalBanner();
        restoreTerminal();
        System.exit(0);
    }

    static void shutdownHook() {
        onUnexpectedDeath(exitCodeForLog.getOrDefault("code", 1));
        restoreTerminal();
    }

    static final java.util.concurrent.ConcurrentHashMap<String, Integer>
            exitCodeForLog = new java.util.concurrent.ConcurrentHashMap<>();

    /* Used by the crash-injection test (tests/ports.tsv): records the code
     * for the shutdown hook's log message, then exits with it. */
    static void crashExit(int code) {
        exitCodeForLog.put("code", code);
        System.exit(code);
    }

    static void installSignal(String name, int code) {
        try {
            sun.misc.Signal.handle(new sun.misc.Signal(name), sig -> {
                exitCodeForLog.put("code", code);
                cleanup(code);
            });
        } catch (Throwable t) {
            // Signal handling unavailable: fall back to the shutdown hook only.
        }
    }
}
