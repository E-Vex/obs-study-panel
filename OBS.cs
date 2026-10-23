// OBS.cs - Study/break timer protocol (C# port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: .NET SDK 8+ (net8.0), bash (to load the bash-syntax config
// file). No NuGet packages - standard library only.
//
// Usage:   OBS.cs [options] <rounds> <study_minutes> <break_minutes>
// Example: OBS.cs 5 50 10            ->  5 rounds, 50 min study, 10 min break
//          OBS.cs --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
// Stop:    Ctrl+C, or press 'q' while a phase is running
// Theme:   press Alt+T while a phase is running (see --list-themes)
//
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// C# port of OBS.sh. POSIX details (poll, termios, kill, stat) come in via
// P/Invoke; signals use PosixSignalRegistration (130/143/129).
internal static class Program
{
    // ---------------------------------------------------------------- P/Invoke
    private const short POLLIN = 0x001;
    private const short POLLHUP = 0x010;
    private const short POLLERR = 0x008;
    private const int EINTR = 4;
    private const int SIGINT = 2, SIGHUP = 1, SIGTERM = 15;
    private const uint TCISIG = 1, TCICANON = 2, TCIECHO = 8;  // c_lflag bits
    private const int VTIME = 5, VMIN = 6;
    private const int TCSADRAIN = 1, TCSAFLUSH = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct PollFd
    {
        public int fd;
        public short events;
        public short revents;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct Termios
    {
        public uint c_iflag, c_oflag, c_cflag, c_lflag;
        public byte c_line;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] c_cc;
        public uint c_ispeed, c_ospeed;
    }

    [DllImport("libc", SetLastError = true)]
    private static extern int poll(ref PollFd fds, uint nfds, int timeoutMs);

    [DllImport("libc", SetLastError = true)]
    private static extern IntPtr read(int fd, [Out] byte[] buf, IntPtr count);

    [DllImport("libc", SetLastError = true)]
    private static extern int isatty(int fd);

    [DllImport("libc", SetLastError = true)]
    private static extern int tcgetattr(int fd, ref Termios t);

    [DllImport("libc", SetLastError = true)]
    private static extern int tcsetattr(int fd, int optionalActions, ref Termios t);

    [DllImport("libc", SetLastError = true)]
    private static extern int kill(int pid, int sig);

    [DllImport("libc", SetLastError = true)]
    private static extern int stat([MarshalAs(UnmanagedType.LPStr)] string path, byte[] buf);

    [DllImport("libc", SetLastError = true)]
    private static extern int access([MarshalAs(UnmanagedType.LPStr)] string path, int mode);

    private static int Errno() => Marshal.GetLastWin32Error();

    private static readonly DateTime StartUtc = DateTime.UtcNow;

    // ---------------------------------------------------------------- signals
    // .NET re-raises a POSIX signal with the default action once the
    // PosixSignalRegistration callback returns, so the callback itself has
    // to perform the full cleanup (like the Perl/Ruby ports' traps do) and
    // then exit with 130/143/129. It first parks the main thread via a
    // handshake so the cleanup does not race the tick writes.
    private static volatile int SigFlag;      // 0 = none, else exit code
    private static volatile bool SignalAck;   // main thread parked
    private static readonly List<PosixSignalRegistration> SigRegs = new();

    private static void InstallSignalHandlers()
    {
        void Handle(int code)
        {
            SigFlag = code;
            long deadline = NowMs() + 2000;
            while (!SignalAck && NowMs() < deadline) Thread.Sleep(5);
            Cleanup(code);
        }
        SigRegs.Add(PosixSignalRegistration.Create(PosixSignal.SIGINT, _ => Handle(130)));
        SigRegs.Add(PosixSignalRegistration.Create(PosixSignal.SIGTERM, _ => Handle(143)));
        SigRegs.Add(PosixSignalRegistration.Create(PosixSignal.SIGHUP, _ => Handle(129)));
    }

    // Called from every wait loop (at least every 200 ms). Parks the main
    // thread once a signal has arrived; the callback cleans up and exits.
    private static void CheckSignal()
    {
        if (SigFlag != 0)
        {
            SignalAck = true;
            while (true) Thread.Sleep(50);
        }
    }

    private static long NowMs() =>
        (long)(DateTime.UtcNow - StartUtc).TotalMilliseconds;

    private static int NowSeconds() =>
        (int)(DateTime.UtcNow - StartUtc).TotalSeconds;

    // ---------------------------------------------------------------- output
    private static StreamWriter Stdout;
    private static StreamWriter Stderr;

    private static void Out(string s) { Stdout.Write(s); Stdout.Write('\n'); }
    private static void OutRaw(string s) { Stdout.Write(s); Stdout.Flush(); }
    private static void Err(string s) { Stderr.Write(s); Stderr.Write('\n'); Stderr.Flush(); }

    // ---------------------------------------------------------------- themes
    private static readonly string[] ThemeNames =
        { "Purple", "Ocean", "Forest", "Sunset", "Rose", "Gold",
          "Mono", "Ice", "Ember", "Neon", "Cobalt", "Cherry" };
    private static readonly string[] ThemePrimary =
        { "\x1b[1;35m", "\x1b[1;36m", "\x1b[1;32m", "\x1b[1;33m", "\x1b[1;95m", "\x1b[1;93m",
          "\x1b[1;37m", "\x1b[1;96m", "\x1b[1;91m", "\x1b[1;92m", "\x1b[1;34m", "\x1b[1;91m" };
    private static readonly string[] ThemeSecondary =
        { "\x1b[0;35m", "\x1b[0;34m", "\x1b[0;32m", "\x1b[0;31m", "\x1b[0;31m", "\x1b[0;33m",
          "\x1b[0;37m", "\x1b[0;36m", "\x1b[0;31m", "\x1b[0;96m", "\x1b[0;36m", "\x1b[0;35m" };

    private static string Primary = ThemePrimary[0];
    private static string Secondary = ThemeSecondary[0];
    private static string ThemeName = ThemeNames[0];
    private static int ThemeIndex = 0;
    private static long ThemeNoticeUntil = 0;

    private const string BOLD = "\x1b[1m";
    private const string DIM = "\x1b[2m";
    private const string NC = "\x1b[0m";

    private const string Logo = @" /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/";

    private static readonly string[] DefaultQuoteList =
    {
        "Focused effort beats scattered hours",
        "Every round finished is progress made",
        "Consistency beats intensity",
        "Start now, figure out the rest along the way",
        "A short break now means sharper focus next round",
    };

    private static bool SetTheme(int i)
    {
        if (i < 0 || i >= ThemeNames.Length) return false;
        ThemeIndex = i;
        ThemeName = ThemeNames[i];
        Primary = ThemePrimary[i];
        Secondary = ThemeSecondary[i];
        return true;
    }

    private static int ThemeIndexByName(string name)
    {
        if (string.IsNullOrEmpty(name)) return -1;
        for (int i = 0; i < ThemeNames.Length; i++)
            if (ThemeNames[i].ToLowerInvariant() == name.ToLowerInvariant()) return i;
        return -1;
    }

    private static string ThemeFile = "";

    private static void SaveTheme()
    {
        if (ThemeFile == "") return;
        try { File.WriteAllText(ThemeFile, ThemeName + "\n"); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void CycleTheme()
    {
        SetTheme((ThemeIndex + 1) % ThemeNames.Length);
        SaveTheme();
        ThemeNoticeUntil = NowSeconds() + 3;
        LogEvent("Theme changed to: " + ThemeName);
    }

    private static void ListThemes()
    {
        for (int i = 0; i < ThemeNames.Length; i++)
            Out(string.Format(CultureInfo.InvariantCulture, "  {0,-8} {1}████{2}",
                ThemeNames[i], ThemePrimary[i], ThemeSecondary[i]));
    }

    // ---------------------------------------------------------------- env/defaults
    private static readonly string EnvAlertSound = Environment.GetEnvironmentVariable("ALERT_SOUND") ?? "";
    private static readonly string EnvSinkName = Environment.GetEnvironmentVariable("SINK_NAME") ?? "";
    private static readonly string EnvStateDir = Environment.GetEnvironmentVariable("STATE_DIR") ?? "";
    private static readonly string EnvMaxLogBytes = Environment.GetEnvironmentVariable("MAX_LOG_BYTES") ?? "";
    private static readonly string EnvQuotes = Environment.GetEnvironmentVariable("QUOTES") ?? "";
    private static readonly string EnvTheme = Environment.GetEnvironmentVariable("THEME") ?? "";

    private static string Home = Environment.GetEnvironmentVariable("HOME") ?? "";
    private static string AlertSound = "";
    private static string SinkName = "OBS_Alert_Sink";
    private static string StateDir = "";
    private static string MaxLogBytes = "1048576";
    private static string FileBarWidth = "20";
    private static string NonTtyEnterTimeout = "300";
    private static int AlertPid;
    private static Process AlertProc;
    private static List<string> QuoteList = new(DefaultQuoteList);
    private static int Points;
    private static string LastDate = "";
    private static string Dir = "";

    // ---------------------------------------------------------------- args
    private static string Prog = "OBS.cs";
    private static string ConfigFile = "";
    private static bool DryRun;
    private static bool UseAlert = true;
    private static bool UseSink = true;
    private static int Rounds, StudyMin, BreakMin;
    private static string CliTheme = "";
    private static string DurationUnit = "minutes";
    private static int SecondsPerUnit = 60;
    private static string ConfigTheme = "";
    private static string ConfigQuotes = "";
    private static string ConfigLoaded = "";

    private sealed class CrashExitException : Exception
    {
        public readonly int ExitCode;
        public CrashExitException(int code) : base("crash exit " + code) { ExitCode = code; }
    }

    // Used by the crash-injection test point.
    private static void CrashExit(int code) => throw new CrashExitException(code);

    private static string HelpText() => string.Format(CultureInfo.InvariantCulture, @"Usage: {0} [options] <rounds> <study_minutes> <break_minutes>

Runs a Pomodoro-style study/break loop and writes the live state to text
files that OBS Studio can display as ""Text (read from file)"" sources.

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
  {0} 5 50 10           # 5 rounds, 50 min study, 10 min break
  {0} --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  {0} --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
", Prog);

    private static void PrintHelp(int code, TextWriter stream)
    {
        stream ??= Console.Out;
        stream.Write(HelpText());
        stream.Flush();
        Environment.Exit(code);
    }

    private static void UsageError() => PrintHelp(1, Stderr ?? Console.Error);

    private static bool BadNumber(string v)
    {
        // ^[1-9][0-9]{0,3}$
        if (v.Length < 1 || v.Length > 4) return true;
        if (v[0] < '1' || v[0] > '9') return true;
        for (int i = 1; i < v.Length; i++)
            if (v[i] < '0' || v[i] > '9') return true;
        return false;
    }

    private static void ParseArgs(string[] argv)
    {
        List<string> positional = new();
        int i = 0;
        while (i < argv.Length)
        {
            string a = argv[i];
            if (a == "-h" || a == "--help") PrintHelp(0, Stdout);
            else if (a == "-c" || a == "--config")
            {
                if (i + 1 >= argv.Length)
                {
                    Err("Error: " + a + " needs a file argument");
                    UsageError();
                }
                ConfigFile = argv[i + 1];
                i += 2;
            }
            else if (a == "-d" || a == "--dry-run") { DryRun = true; i++; }
            else if (a == "-n" || a == "--no-alert") { UseAlert = false; i++; }
            else if (a == "-s" || a == "--no-sink") { UseSink = false; i++; }
            else if (a == "-t" || a == "--theme")
            {
                if (i + 1 >= argv.Length)
                {
                    Err("Error: " + a + " needs a theme name");
                    UsageError();
                }
                CliTheme = argv[i + 1];
                i += 2;
            }
            else if (a == "--list-themes")
            {
                ListThemes();
                Stdout.Flush();
                Environment.Exit(0);
            }
            else if (a == "--")
            {
                for (int j = i + 1; j < argv.Length; j++) positional.Add(argv[j]);
                break;
            }
            else if (a.StartsWith("-"))
            {
                Err("Error: unknown option: " + a);
                UsageError();
            }
            else
            {
                for (int j = i; j < argv.Length; j++) positional.Add(argv[j]);
                break;
            }
        }

        if (positional.Count != 3) UsageError();
        foreach (string v in positional)
            if (BadNumber(v)) UsageError();
        Rounds = int.Parse(positional[0], CultureInfo.InvariantCulture);
        StudyMin = int.Parse(positional[1], CultureInfo.InvariantCulture);
        BreakMin = int.Parse(positional[2], CultureInfo.InvariantCulture);
        if (Rounds > 50) { Err("Error: rounds must be <= 50"); UsageError(); }
        if (StudyMin > 600) { Err("Error: study minutes must be <= 600"); UsageError(); }
        if (BreakMin > 120) { Err("Error: break minutes must be <= 120"); UsageError(); }

        if (DryRun)
        {
            DurationUnit = "seconds";
            SecondsPerUnit = 1;
        }
    }

    // ---------------------------------------------------------------- config
    private const string ConfigDumpSh = @"
set -u
IFS=$'\037' read -r -a QUOTE_LIST <<< ""${QUOTES_SEED-}""
unset QUOTES_SEED
source ""$1"" || true
{
  d() { printf '%s\037%s\036' ""$1"" ""${2-}""; }
  d ALERT_SOUND ""${ALERT_SOUND-}""
  d SINK_NAME ""${SINK_NAME-}""
  d STATE_DIR ""${STATE_DIR-}""
  d MAX_LOG_BYTES ""${MAX_LOG_BYTES-}""
  d FILE_BAR_WIDTH ""${FILE_BAR_WIDTH-}""
  d NON_TTY_ENTER_TIMEOUT ""${NON_TTY_ENTER_TIMEOUT-}""
  d THEME ""${THEME-}""
  d POINTS ""${POINTS-}""
  d LAST_DATE ""${LAST_DATE-}""
  d QUOTES ""${QUOTES-}""
  for q in ${QUOTE_LIST[@]+""${QUOTE_LIST[@]}""}; do d QUOTE ""$q""; done
} > ""$2""
";

    private static bool FileExists(string p)
    {
        try { return File.Exists(p); }
        catch { return false; }
    }

    private static uint StatMode(string path)
    {
        byte[] buf = new byte[144];
        if (stat(path, buf) != 0) return 0;
        return BitConverter.ToUInt32(buf, 24);   // st_mode at offset 24 (x86_64)
    }

    private static bool IsRegularFile(string path)
    {
        uint mode = StatMode(path);
        return (mode & 0xF000) == 0x8000;        // S_IFREG
    }

    private static bool IsDir(string path) => (StatMode(path) & 0xF000) == 0x4000;

    private static string FindConfigFile()
    {
        if (ConfigFile != "") return ConfigFile;
        string envCfg = Environment.GetEnvironmentVariable("OBS_PANEL_CONFIG");
        if (!string.IsNullOrEmpty(envCfg)) return envCfg;
        string xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (string.IsNullOrEmpty(xdg)) xdg = Path.Combine(Home, ".config");
        string xdgCfg = Path.Combine(xdg, "obs-study-panel", "config");
        if (FileExists(xdgCfg)) return xdgCfg;
        string localCfg = Path.Combine(Dir, "obs-panel.conf");
        if (FileExists(localCfg)) return localCfg;
        return null;
    }

    private static List<string> QuotesToList(string raw)
    {
        List<string> list = new();
        foreach (string line in raw.Split('\n'))
        {
            string l = line.EndsWith("\r") ? line[..^1] : line;
            if (l != "") list.Add(l);
        }
        return list;
    }

    private static int ParseInt(string value, int fallback)
    {
        if (int.TryParse(value?.Trim(), NumberStyles.Integer,
                CultureInfo.InvariantCulture, out int n)) return n;
        return fallback;
    }

    private static void LoadConfig(string path)
    {
        if (access(path, 4) != 0)   // R_OK, like the reference's [[ -r ]]
        {
            Err("Error: config file is not readable: " + path);
            Environment.Exit(1);
        }
        if (Which("bash") == null)
        {
            Err("Error: bash is required to read the config file: " + path);
            Environment.Exit(1);
        }
        // Syntax gate: bash -n, first 3 lines of its stderr.
        string bashErr;
        using (var p = new Process
        {
            StartInfo = new ProcessStartInfo("bash")
            {
                UseShellExecute = false,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
            },
        })
        {
            p.StartInfo.ArgumentList.Add("-n");
            p.StartInfo.ArgumentList.Add(path);
            p.Start();
            bashErr = p.StandardError.ReadToEnd();
            p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0)
            {
                Err("Error: syntax error in config file: " + path);
                int printed = 0;
                foreach (string line in bashErr.Split('\n'))
                {
                    if (line.Trim() == "" || printed >= 3) continue;
                    Err(line);
                    printed++;
                }
                Environment.Exit(1);
            }
        }

        // Seed the pre-config defaults, exactly what the reference holds while
        // it sources the file (the real environment's THEME/QUOTES pass through).
        string dumpPath = Path.Combine(Path.GetTempPath(), "obs-panel-conf-"
            + Guid.NewGuid().ToString("N"));
        try
        {
            int childRc;
            using (var p = new Process
            {
                StartInfo = new ProcessStartInfo("bash") { UseShellExecute = false },
            })
            {
                p.StartInfo.ArgumentList.Add("-c");
                p.StartInfo.ArgumentList.Add(ConfigDumpSh);
                p.StartInfo.ArgumentList.Add("obs-panel");
                p.StartInfo.ArgumentList.Add(path);
                p.StartInfo.ArgumentList.Add(dumpPath);
                p.StartInfo.EnvironmentVariables["ALERT_SOUND"] = AlertSound;
                p.StartInfo.EnvironmentVariables["SINK_NAME"] = SinkName;
                p.StartInfo.EnvironmentVariables["STATE_DIR"] = "";
                p.StartInfo.EnvironmentVariables["MAX_LOG_BYTES"] = "1048576";
                p.StartInfo.EnvironmentVariables["FILE_BAR_WIDTH"] = "20";
                p.StartInfo.EnvironmentVariables["NON_TTY_ENTER_TIMEOUT"] = "300";
                p.StartInfo.EnvironmentVariables["POINTS"] = Points.ToString(CultureInfo.InvariantCulture);
                p.StartInfo.EnvironmentVariables["LAST_DATE"] = LastDate;
                p.StartInfo.EnvironmentVariables["QUOTES_SEED"] = string.Join("\x1f", QuoteList);
                p.Start();
                p.WaitForExit();
                childRc = p.ExitCode;
            }

            byte[] raw;
            try { raw = File.ReadAllBytes(dumpPath); }
            catch (IOException) { raw = null; }

            if (raw == null || raw.Length == 0)
            {
                // The config called exit N before the dump was written.
                Environment.Exit(childRc != 0 ? childRc : 1);
            }

            var values = new Dictionary<string, string>();
            var quotes = new List<string>();
            var enc = Encoding.Latin1;
            int start = 0;
            while (start <= raw.Length)
            {
                int recEnd = Array.IndexOf(raw, (byte)0x1e, start);
                int recLen = (recEnd < 0 ? raw.Length : recEnd) - start;
                if (recLen > 0)
                {
                    int sep = Array.IndexOf(raw, (byte)0x1f, start, recLen);
                    if (sep >= 0)
                    {
                        string key = enc.GetString(raw, start, sep - start);
                        string value = enc.GetString(raw, sep + 1, start + recLen - sep - 1);
                        if (key == "QUOTE") quotes.Add(value);
                        else values[key] = value;
                    }
                }
                if (recEnd < 0) break;
                start = recEnd + 1;
            }

            AlertSound = values.GetValueOrDefault("ALERT_SOUND", AlertSound);
            SinkName = values.GetValueOrDefault("SINK_NAME", SinkName);
            StateDir = values.GetValueOrDefault("STATE_DIR", "");
            MaxLogBytes = values.GetValueOrDefault("MAX_LOG_BYTES", "1048576");
            FileBarWidth = values.GetValueOrDefault("FILE_BAR_WIDTH", "20");
            NonTtyEnterTimeout = values.GetValueOrDefault("NON_TTY_ENTER_TIMEOUT", "300");
            ConfigTheme = values.GetValueOrDefault("THEME", "");
            Points = ParseInt(values.GetValueOrDefault("POINTS", "0"), 0);
            LastDate = values.GetValueOrDefault("LAST_DATE", "");
            ConfigQuotes = values.GetValueOrDefault("QUOTES", "");
            QuoteList = quotes;
            ConfigLoaded = path;
        }
        finally
        {
            try { File.Delete(dumpPath); } catch (IOException) { }
        }
    }

    private static string Which(string name)
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        if (path == "") return null;
        foreach (string dir in path.Split(':'))
        {
            if (dir == "") continue;
            string full = Path.Join(dir, name);
            try
            {
                if (File.Exists(full) && access(full, 1) == 0)   // X_OK
                    return full;
            }
            catch { /* permission etc. */ }
        }
        return null;
    }

    private static void ApplyQuoteSources()
    {
        if (EnvQuotes != "") QuoteList = QuotesToList(EnvQuotes);
        else if (ConfigQuotes != "") QuoteList = QuotesToList(ConfigQuotes);
    }

    private static void SanityKnobs()
    {
        if (!uint.TryParse(MaxLogBytes, NumberStyles.None, CultureInfo.InvariantCulture,
                out uint mlb) || mlb == 0)
            MaxLogBytes = "1048576";
        if (!uint.TryParse(FileBarWidth, NumberStyles.None, CultureInfo.InvariantCulture,
                out uint fbw) || fbw == 0 || fbw > 200)
            FileBarWidth = "20";
        if (!uint.TryParse(NonTtyEnterTimeout, NumberStyles.None, CultureInfo.InvariantCulture,
                out uint ntt) || ntt == 0 || ntt > 3600)
            NonTtyEnterTimeout = "300";
    }

    // ---------------------------------------------------------------- paths
    private static string DateFile, DayFile, SessionFile, TimerFile, LogFile;
    private static string ProgressFile, PointsFile, MessageFile, NextFile;
    private static string OverlayFile;

    private static string SessionText = "";
    private static string RemainingStr = "00:00:00";
    private static int Pct;
    private static string NextText = "";
    private static string MessageText = "";
    private static string LastDay = "";
    private static bool StateReady, StateFinalized, InCleanup;

    private static void SetupPaths()
    {
        if (StateDir == "") StateDir = Dir;
        try
        {
            Directory.CreateDirectory(StateDir);
        }
        catch (Exception)
        {
            Err("Error: cannot create state dir: " + StateDir);
            Environment.Exit(1);
        }
        string P(string n) => Path.Combine(StateDir, n);
        DateFile = P("date.txt");
        DayFile = P("day.txt");
        SessionFile = P("session.txt");
        TimerFile = P("timer.txt");
        LogFile = P("log.txt");
        ProgressFile = P("progress.txt");
        PointsFile = P("points.txt");
        MessageFile = P("message.txt");
        NextFile = P("next.txt");
        OverlayFile = P("overlay.txt");
        ThemeFile = P("theme.txt");
    }

    private static void SelectTheme()
    {
        string request = CliTheme;
        if (request == "" && EnvTheme != "") request = EnvTheme;
        if (request == "" && ConfigTheme != "") request = ConfigTheme;
        if (request == "" && ThemeFile != "" && IsRegularFile(ThemeFile))
        {
            try
            {
                using var fh = new StreamReader(ThemeFile);
                request = fh.ReadLine() ?? "";
            }
            catch (IOException) { }
        }
        if (request != "")
        {
            int idx = ThemeIndexByName(request);
            if (idx < 0)
                Err("Warning: unknown theme '" + request + "', using " + ThemeName);
            else
                SetTheme(idx);
        }
    }

    // ---------------------------------------------------------------- state files
    private static void WriteFile(string path, string text)
    {
        try { File.WriteAllText(path, text + "\n"); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void UpdateDateDay()
    {
        string d = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (d == LastDate) return;
        LastDate = d;
        LastDay = DateTime.Now.ToString("dddd", CultureInfo.InvariantCulture);
        WriteFile(DateFile, d);
        WriteFile(DayFile, LastDay);
    }

    private static void SyncState()
    {
        UpdateDateDay();
        PublishState();
    }

    private static string MakeBar(int filled, int width, string fill, string empty, string head = "")
    {
        var sb = new StringBuilder();
        for (int i = 0; i < width; i++)
        {
            if (i < filled)
                sb.Append(head != "" && i == filled - 1 ? head : fill);
            else
                sb.Append(empty);
        }
        return sb.ToString();
    }

    private static int BarWidth() => int.Parse(FileBarWidth, CultureInfo.InvariantCulture);

    private static string FileBar() => MakeBar(Pct * BarWidth() / 100, BarWidth(), "#", "-");

    private static void PublishState()
    {
        string bar = FileBar();
        WriteFile(SessionFile, SessionText);
        WriteFile(TimerFile, RemainingStr);
        WriteFile(PointsFile, Points.ToString(CultureInfo.InvariantCulture));
        WriteFile(NextFile, NextText);
        WriteFile(MessageFile, MessageText);
        string pctLine = string.Format(CultureInfo.InvariantCulture,
            "[{0}] {1,3}%", bar, Pct);
        WriteFile(ProgressFile, pctLine);
        var overlay = new List<string>
        {
            LastDate + "  " + LastDay,
            SessionText,
            RemainingStr,
            pctLine,
            "Pts: " + Points.ToString(CultureInfo.InvariantCulture),
            "Next: " + NextText,
        };
        if (MessageText != "") overlay.Add(MessageText);
        try { File.WriteAllText(OverlayFile, string.Join("\n", overlay) + "\n"); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void RotateLogIfNeeded()
    {
        try
        {
            if (!File.Exists(LogFile)) return;
            if (new FileInfo(LogFile).Length <
                long.Parse(MaxLogBytes, CultureInfo.InvariantCulture)) return;
            File.Move(LogFile, LogFile + ".1", overwrite: true);
            File.WriteAllText(LogFile, "");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void LogEvent(string msg)
    {
        RotateLogIfNeeded();
        try
        {
            File.AppendAllText(LogFile, string.Format(CultureInfo.InvariantCulture,
                "[{0}] {1}\n",
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
                msg));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    // ---------------------------------------------------------------- audio
    private static bool SinkIsReady()
    {
        if (Which("pactl") == null) return false;
        try
        {
            using var p = new Process
            {
                StartInfo = new ProcessStartInfo("pactl")
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                },
            };
            p.StartInfo.ArgumentList.Add("list");
            p.StartInfo.ArgumentList.Add("short");
            p.StartInfo.ArgumentList.Add("sinks");
            p.Start();
            var outTask = p.StandardOutput.ReadToEndAsync();
            var errTask = p.StandardError.ReadToEndAsync();
            p.WaitForExit();
            if (p.ExitCode != 0) return false;
            foreach (string line in outTask.Result.Split('\n'))
            {
                var fields = line.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                if (fields.Length > 1 && fields[1] == SinkName) return true;
            }
        }
        catch (Exception) { return false; }
        return false;
    }

    private static void SetupAudioSink()
    {
        if (!UseSink) return;
        if (Which("pactl") == null) return;
        if (SinkIsReady()) return;
        try
        {
            using var p = new Process
            {
                StartInfo = new ProcessStartInfo("pactl")
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                },
            };
            p.StartInfo.ArgumentList.Add("load-module");
            p.StartInfo.ArgumentList.Add("module-null-sink");
            p.StartInfo.ArgumentList.Add("sink_name=" + SinkName);
            p.StartInfo.ArgumentList.Add("sink_properties=device.description=" + SinkName);
            p.Start();
            p.WaitForExit();
        }
        catch (Exception) { }
    }

    private static void StopAlert()
    {
        if (AlertPid > 0)
        {
            try { kill(AlertPid, SIGTERM); } catch { }
            try { AlertProc?.WaitForExit(2000); } catch { }
            try { AlertProc?.Dispose(); } catch { }
            AlertProc = null;
            AlertPid = 0;
        }
    }

    private static void PlayAlert()
    {
        if (!UseAlert) return;
        StopAlert();   // never let two alarms overlap
        if (AlertSound == "" || !IsRegularFile(AlertSound))
        {
            Out(DIM + "(alert file not found: " +
                (AlertSound != "" ? AlertSound : "none") + ")" + NC);
            return;
        }

        List<string> player;
        if (Which("mpv") != null) player = new List<string> { "mpv", "--no-video", "--volume=70" };
        else if (Which("paplay") != null) player = new List<string> { "paplay" };
        else if (Which("ffplay") != null) player = new List<string> { "ffplay", "-nodisp", "-autoexit" };
        else if (Which("cvlc") != null) player = new List<string> { "cvlc", "--play-and-exit", "--no-video", "--volume=70" };
        else
        {
            Out(DIM + "(no audio player found - install mpv / paplay / ffplay)" + NC);
            return;
        }

        if (UseSink && !SinkIsReady()) SetupAudioSink();

        void Spawn(bool onSink)
        {
            var p = new Process
            {
                StartInfo = new ProcessStartInfo(player[0])
                {
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                },
            };
            foreach (string a in player.Skip(1)) p.StartInfo.ArgumentList.Add(a);
            p.StartInfo.ArgumentList.Add(AlertSound);
            if (onSink) p.StartInfo.EnvironmentVariables["PULSE_SINK"] = SinkName;
            p.OutputDataReceived += (_, _) => { };
            p.ErrorDataReceived += (_, _) => { };
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            AlertProc = p;
            AlertPid = p.Id;
        }

        try
        {
            if (UseSink && SinkIsReady())
            {
                Spawn(true);
                Out(DIM + "-> alert on OBS sink (" + SinkName + ")" + NC);
            }
            else
            {
                Spawn(false);
                Out(Secondary + "-> alert on default device (OBS sink unavailable)" + NC);
            }
        }
        catch (Exception) { }
    }

    // ---------------------------------------------------------------- keyboard
    private static bool StdinIsTty;
    private static Termios? TermSaved;
    private static string Key = "";
    private static bool KeyRead;

    private static void SetupTerminal()
    {
        StdinIsTty = isatty(0) == 1;
        if (StdinIsTty)
        {
            var t = new Termios { c_cc = new byte[32] };
            if (tcgetattr(0, ref t) == 0)
            {
                TermSaved = t;
                var mode = new Termios
                {
                    c_iflag = t.c_iflag, c_oflag = t.c_oflag,
                    c_cflag = t.c_cflag, c_lflag = t.c_lflag,
                    c_line = t.c_line, c_cc = (byte[])t.c_cc.Clone(),
                    c_ispeed = t.c_ispeed, c_ospeed = t.c_ospeed,
                };
                // cbreak like the reference's `read -s`: echo and canonical
                // mode off, ISIG stays on so Ctrl+C still generates SIGINT.
                mode.c_lflag &= ~(TCICANON | TCIECHO);
                mode.c_cc[VMIN] = 1;
                mode.c_cc[VTIME] = 0;
                tcsetattr(0, TCSAFLUSH, ref mode);
            }
        }
    }

    private static void RestoreTerminal()
    {
        if (TermSaved != null)
        {
            var t = TermSaved.Value;
            tcsetattr(0, TCSADRAIN, ref t);
            TermSaved = null;
        }
    }

    // Sleep in short slices so a signal is noticed within ~200 ms even if
    // the runtime restarts interrupted syscalls.
    private static void SleepSliced(double seconds)
    {
        long deadline = NowMs() + (long)(seconds * 1000);
        while (true)
        {
            CheckSignal();
            long left = deadline - NowMs();
            if (left <= 0) return;
            Thread.Sleep((int)Math.Min(left, 200));
        }
    }

    // One byte with a timeout: 0..255 = byte, -1 = timeout, -2 = EOF.
    private static int ReadByteTimeout(double seconds)
    {
        long deadline = NowMs() + (long)(seconds * 1000);
        byte[] buf = new byte[1];
        while (true)
        {
            CheckSignal();
            long left = deadline - NowMs();
            if (left < 0) left = 0;
            var pfd = new PollFd { fd = 0, events = POLLIN };
            int rc = poll(ref pfd, 1, (int)Math.Min(left, 200));
            if (rc > 0)
            {
                if ((pfd.revents & (POLLIN | POLLHUP | POLLERR)) == 0) continue;
                IntPtr n = read(0, buf, (IntPtr)1);
                long got = (long)n;
                if (got == 1) return buf[0];
                if (got == 0) return -2;                 // EOF
                if (Errno() == EINTR) continue;
                return -1;
            }
            if (rc == 0)
            {
                if (NowMs() >= deadline) return -1;
                continue;
            }
            // rc < 0 (EINTR): loop, the flag check runs first.
        }
    }

    private static void WaitKey(double timeoutSec)
    {
        Key = "";
        KeyRead = false;
        if (!StdinIsTty)
        {
            SleepSliced(timeoutSec);
            return;
        }
        int b = ReadByteTimeout(timeoutSec);
        if (b < 0) return;
        KeyRead = true;
        if (b == 27)   // ESC: only Alt+T is used, the rest is swallowed
        {
            Key = "";
            int nxt = ReadByteTimeout(0.3);
            if (nxt == 't' || nxt == 'T') Key = "alt-t";
        }
        else
        {
            Key = ((char)b).ToString();
        }
    }

    private static void DiscardPendingInput()
    {
        if (!StdinIsTty) return;
        while (true)
        {
            int b = ReadByteTimeout(0.01);
            if (b < 0) return;
        }
    }

    private static void WaitForEnter()
    {
        if (StdinIsTty)
        {
            while (true)
            {
                int b = ReadByteTimeout(1);
                if (b == -1) { UpdateDateDay(); continue; }
                if (b == -2 || b == '\n') return;
            }
        }
        // Not a terminal: bounded wait, 5 s slices.
        int nonTtyTimeout = int.Parse(NonTtyEnterTimeout, CultureInfo.InvariantCulture);
        int waited = 0;
        byte[] buf = new byte[4096];
        while (waited < nonTtyTimeout)
        {
            long sliceEnd = NowMs() + 5000;
            while (true)
            {
                CheckSignal();
                long left = sliceEnd - NowMs();
                if (left <= 0) { waited += 5; break; }
                var pfd = new PollFd { fd = 0, events = POLLIN };
                int rc = poll(ref pfd, 1, (int)Math.Min(left, 200));
                if (rc == 0) { waited += 5; break; }
                if (rc < 0) continue;
                IntPtr n = read(0, buf, (IntPtr)buf.Length);
                long got = (long)n;
                if (got <= 0) return;   // EOF
                for (long i = 0; i < got; i++)
                    if (buf[i] == (byte)'\n') return;
            }
        }
    }

    // ---------------------------------------------------------------- UI
    private const int TermBarWidth = 24;
    private const int BoxInner = 62;

    private static string PhaseColor(string label) =>
        label == "STUDY" ? Primary : Secondary;

    private static void DrawStatus(string label, int round, int totalRounds,
        int elapsed, int total, bool paused)
    {
        int filled = 0;
        if (total > 0) filled = elapsed * TermBarWidth / total;
        if (filled > TermBarWidth) filled = TermBarWidth;
        string bar = MakeBar(filled, TermBarWidth, "=", " ", ">");
        string color = PhaseColor(label);
        string flag = paused ? Primary + " PAUSED" + NC : "";
        if (NowSeconds() < ThemeNoticeUntil)
            flag += "  " + DIM + "Theme: " + ThemeName + NC;
        OutRaw("\r\x1b[K");
        OutRaw(string.Format(CultureInfo.InvariantCulture,
            "{0}{1}{2,-6}{3} [{4}/{5}] {6}[{7}]{8} {9,3}%  {10}  {11}Pts:{12}{13}{14}",
            BOLD, color, label, NC, round, totalRounds,
            color, bar, NC, Pct, RemainingStr, Primary, Points, NC, flag));
    }

    private static void BoxRow(string color, string plain, string styled)
    {
        int pad = BoxInner - plain.Length;
        if (pad < 0) pad = 0;
        Out(color + "║" + styled + new string(' ', pad) + color + "║" + NC);
    }

    private static string DurationLabel(int n)
    {
        if (n == 1) return DurationUnit == "seconds" ? "1 second" : "1 minute";
        return n + " " + DurationUnit;
    }

    private static string RoundsLabel(int n) => n == 1 ? "1 round" : n + " rounds";

    private static void PhaseHeader(string label, int round, int total,
        int minutes, string subtitle)
    {
        if (subtitle.Length > BoxInner - 4) subtitle = subtitle[..(BoxInner - 4)];
        string color = PhaseColor(label);
        string bar = new string('═', BoxInner);
        string info = label + "  ·  Round " + round + " / " + total
            + "  ·  " + DurationLabel(minutes);
        Out("");
        Out(color + "╔" + bar + "╗" + NC);
        BoxRow(color, "  " + info,
            "  " + BOLD + label + NC + color + "  ·  Round " + round + " / "
            + total + "  ·  " + DurationLabel(minutes));
        BoxRow(color, "  " + subtitle, "  " + DIM + subtitle + NC + color);
        if (StdinIsTty)
        {
            string keys = "  p pause  ·  s skip  ·  q quit  ·  Alt+T theme";
            BoxRow(color, keys, DIM + keys + NC + color);
        }
        Out(color + "╚" + bar + "╝" + NC);
        Out("");
    }

    private static void ShowCompletion(string phase, int round, int totalRounds,
        string nextPhase, int skipped)
    {
        const int width = 60;
        string line = new string('=', width);
        string title = skipped == 1 ? "PHASE SKIPPED"
            : phase == "STUDY" ? "STUDY SESSION COMPLETE"
            : "BREAK COMPLETE";
        string color = PhaseColor(phase);
        Out("");
        Out(color + line + NC);
        Out(color + new string(' ', (width + title.Length) / 2) + title + NC);
        Out(color + line + NC);
        Out("");
        Out("  Round:   " + BOLD + round + NC + " / " + totalRounds);
        Out("  Points:  " + Primary + Points + NC);
        Out("");
        if (nextPhase == "None") Out("  Next:    " + DIM + "Session complete" + NC);
        else Out("  Next:    " + BOLD + nextPhase + NC);
        Out("");
        OutRaw("  " + Primary + "Press Enter to continue..." + NC);
    }

    // ---------------------------------------------------------------- phases
    private static string PhaseLabel = "", PhaseSubtitle = "", PhaseNext = "";
    private static int PhaseTotal, PhaseElapsed, PhaseStart, PhasePausedTotal, PhasePauseAt;
    private static bool PhasePaused, PhaseSkipped;

    private static string FmtHms(int total) =>
        string.Format(CultureInfo.InvariantCulture, "{0:D2}:{1:D2}:{2:D2}",
            total / 3600, total % 3600 / 60, total % 60);

    private static void PhasePrepare(string ptype, int minutes, int round, int totalRounds)
    {
        if (ptype == "study")
        {
            PhaseLabel = "STUDY";
            PhaseSubtitle = QuoteList.Count > 0
                ? QuoteList[Random.Shared.Next(QuoteList.Count)]
                : "Stay focused.";
        }
        else
        {
            PhaseLabel = "BREAK";
            PhaseSubtitle = "Relax and recharge.";
        }

        if (ptype == "study")
        {
            PhaseNext = round < totalRounds
                ? "Break (" + DurationLabel(BreakMin) + ")"
                : "None";
        }
        else
        {
            PhaseNext = "Study (" + DurationLabel(StudyMin) + ")";
        }

        PhaseTotal = minutes * SecondsPerUnit;
        PhaseElapsed = 0;
        PhasePaused = false;
        PhaseSkipped = false;
        PhaseStart = NowSeconds();
        PhasePausedTotal = 0;
        PhasePauseAt = 0;

        SessionText = PhaseLabel + " " + round + "/" + totalRounds;
        RemainingStr = FmtHms(PhaseTotal);
        Pct = 0;
        NextText = PhaseNext == "None" ? "Session complete" : PhaseNext;
        MessageText = PhaseSubtitle;

        LogEvent("Start: " + PhaseLabel + " " + round + "/" + totalRounds
            + " (" + DurationLabel(minutes) + ")");
        PhaseHeader(PhaseLabel, round, totalRounds, minutes, PhaseSubtitle);
        SyncState();
    }

    private static void PhaseHandleKey(int round, int totalRounds)
    {
        if (Key == "p" || Key == "P" || Key == " ")
        {
            if (PhasePaused)
            {
                PhasePausedTotal += NowSeconds() - PhasePauseAt;
                PhasePaused = false;
                LogEvent("Resumed: " + PhaseLabel + " " + round + "/" + totalRounds);
            }
            else
            {
                PhasePaused = true;
                PhasePauseAt = NowSeconds();
                LogEvent("Paused: " + PhaseLabel + " " + round + "/" + totalRounds);
            }
        }
        else if (Key == "s" || Key == "S")
        {
            PhaseSkipped = true;
            LogEvent("Skipped: " + PhaseLabel + " " + round + "/" + totalRounds);
        }
        else if (Key == "q" || Key == "Q")
        {
            LogEvent("Quit requested by user");
            Cleanup(0);
        }
        else if (Key == "alt-t")
        {
            CycleTheme();
        }
    }

    private static void PhaseCount(int round, int totalRounds)
    {
        while (PhaseElapsed < PhaseTotal)
        {
            int remaining = PhaseTotal - PhaseElapsed;
            if (remaining < 0) remaining = 0;
            RemainingStr = FmtHms(remaining);
            Pct = PhaseTotal > 0 ? PhaseElapsed * 100 / PhaseTotal : 0;
            if (Pct > 100) Pct = 100;
            SessionText = PhaseLabel + " " + round + "/" + totalRounds
                + (PhasePaused ? " (PAUSED)" : "");

            SyncState();
            DrawStatus(PhaseLabel, round, totalRounds, PhaseElapsed, PhaseTotal, PhasePaused);

            WaitKey(1);
            if (KeyRead)
            {
                PhaseHandleKey(round, totalRounds);
                if (PhaseSkipped) break;
            }
            // CRASH-INJECT-POINT
            if (!PhasePaused)
            {
                PhaseElapsed = NowSeconds() - PhaseStart - PhasePausedTotal;
            }
        }
    }

    private static void PhaseFinish(int round, int totalRounds)
    {
        if (PhaseSkipped)
        {
            SessionText = PhaseLabel + " " + round + "/" + totalRounds + " (SKIPPED)";
        }
        else
        {
            Pct = 100;
            Points += 1;
        }
        RemainingStr = "00:00:00";
        SyncState();
        DrawStatus(PhaseLabel, round, totalRounds, PhaseElapsed, PhaseTotal, false);
        Out("");
        LogEvent("End: " + PhaseLabel + " " + round + "/" + totalRounds);

        PlayAlert();

        DiscardPendingInput();
        ShowCompletion(PhaseLabel, round, totalRounds, PhaseNext, PhaseSkipped ? 1 : 0);
        WaitForEnter();
        StopAlert();
        Out("");
    }

    private static void RunPhase(string ptype, int minutes, int round, int totalRounds)
    {
        PhasePrepare(ptype, minutes, round, totalRounds);
        PhaseCount(round, totalRounds);
        PhaseFinish(round, totalRounds);
    }

    // ---------------------------------------------------------------- cleanup
    private static void ResetStateFiles()
    {
        SessionText = "stopped";
        RemainingStr = "00:00:00";
        Pct = 0;
        NextText = "";
        SyncState();
    }

    private static void Cleanup(int code)
    {
        if (InCleanup)
        {
            // Repeated signals are ignored while shutting down: block
            // forever (returning would re-raise the signal's default action).
            while (true) Thread.Sleep(1000);
        }
        InCleanup = true;
        StateFinalized = true;
        try { StopAlert(); } catch { }
        try { ResetStateFiles(); } catch { }
        try { LogEvent("Protocol stopped manually"); } catch { }
        try
        {
            Out("");
            Out(Secondary + BOLD + "Interrupted." + NC + " "
                + DIM + "State files reset to stopped." + NC);
        }
        catch { }
        RestoreTerminal();
        Environment.Exit(code);
    }

    private static void OnUnexpectedDeath(int rc)
    {
        if (!StateReady) return;
        if (StateFinalized) return;
        StateFinalized = true;
        try { StopAlert(); } catch { }
        try { ResetStateFiles(); } catch { }
        try { LogEvent("Protocol ended unexpectedly (exit " + rc + ")"); } catch { }
    }

    // ---------------------------------------------------------------- main
    private static void FinalizeSession()
    {
        SessionText = "session complete";
        RemainingStr = "00:00:00";
        Pct = 100;
        NextText = "";
        SyncState();
        StateFinalized = true;
        LogEvent("Protocol complete - total points: " + Points);
    }

    private static void FinalBanner()
    {
        const int bannerWidth = 60;
        const string title = "ALL SESSIONS COMPLETE";
        int inner = bannerWidth - 2;
        int pad = (inner - title.Length) / 2;
        string border = new string('#', bannerWidth);
        Out("");
        Out(Primary + border + NC);
        Out(Primary + "#" + NC + new string(' ', pad) + BOLD + title
            + new string(' ', inner - pad - title.Length) + NC + "#" + Primary);
        Out(Primary + border + NC);
        Out("");
        Out("  " + BOLD + "Total Rounds:" + NC + "  " + Primary + Rounds + NC);
        Out("  " + BOLD + "Total Points:" + NC + " " + Primary + Points + NC);
        Out("");
        Out(Primary + BOLD + "Great work!" + NC + " " + DIM + "Exiting." + NC);
    }

    private static void RunAll()
    {
        ParseArgs(Environment.GetCommandLineArgs().Skip(1).ToArray());

        string cfg = FindConfigFile();
        if (cfg != null) LoadConfig(cfg);

        // Environment variables beat the config file.
        if (EnvAlertSound != "") AlertSound = EnvAlertSound;
        if (EnvSinkName != "") SinkName = EnvSinkName;
        if (EnvStateDir != "") StateDir = EnvStateDir;
        if (EnvMaxLogBytes != "") MaxLogBytes = EnvMaxLogBytes;

        ApplyQuoteSources();
        SanityKnobs();

        SetupPaths();
        SelectTheme();
        InstallSignalHandlers();
        SetupTerminal();

        Out(Primary);
        Out(Logo);
        Out(NC);
        Out(Primary + BOLD + "     Study / Break Timer Protocol" + NC);
        Out(DIM + "── live state written to date · day · session · timer · log" + NC);
        Out("");
        SetupAudioSink();
        UpdateDateDay();
        StateReady = true;
        LogEvent("Starting new study protocol: " + RoundsLabel(Rounds) + ", "
            + DurationLabel(StudyMin) + " study, " + DurationLabel(BreakMin) + " break");

        Out(Secondary + "Protocol:" + NC + " " + BOLD + RoundsLabel(Rounds) + NC
            + "  " + DIM + "|" + NC + "  " + BOLD + DurationLabel(StudyMin)
            + NC + " study  " + DIM + "|" + NC + "  " + BOLD + DurationLabel(BreakMin)
            + NC + " break  " + DIM + "|" + NC + "  " + BOLD + "Theme: "
            + ThemeName + NC);
        if (ConfigLoaded != "") Out(DIM + "Config: " + ConfigLoaded + NC);
        Out("");

        for (int round = 1; round <= Rounds; round++)
        {
            RunPhase("study", StudyMin, round, Rounds);
            if (round < Rounds) RunPhase("break", BreakMin, round, Rounds);
        }

        FinalizeSession();
        FinalBanner();
        RestoreTerminal();
        Environment.Exit(0);
    }

    private static int Main()
    {
        try
        {
            Console.OutputEncoding = Encoding.UTF8;
            Stdout = new StreamWriter(Console.OpenStandardOutput(),
                new UTF8Encoding(false)) { AutoFlush = true };
            Stderr = new StreamWriter(Console.OpenStandardError(),
                new UTF8Encoding(false)) { AutoFlush = true };

            string exe = Environment.ProcessPath
                ?? System.Reflection.Assembly.GetEntryAssembly()?.Location
                ?? "OBS.cs";
            Prog = Path.GetFileName(exe);
            Dir = Path.GetDirectoryName(Path.GetFullPath(exe)) ?? ".";

            // The default alert lives in $HOME; HOME may be unset.
            Home = Environment.GetEnvironmentVariable("HOME") ?? "";
            AlertSound = Home != "" ? Path.Combine(Home, "Videos/Alarm/n_alarm.mp3") : "";

            AppDomain.CurrentDomain.ProcessExit += (_, _) => RestoreTerminal();

            RunAll();
            return 0;
        }
        catch (CrashExitException e)
        {
            OnUnexpectedDeath(e.ExitCode);
            RestoreTerminal();
            Environment.Exit(e.ExitCode);
            return e.ExitCode;
        }
        catch (Exception)
        {
            OnUnexpectedDeath(1);
            RestoreTerminal();
            throw;
        }
    }
}
