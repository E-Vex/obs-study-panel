// OBS.zig - Study/break timer protocol (Zig port of OBS.sh)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: Zig 0.15+, bash (to load the bash-syntax config file).
// Build: zig build-exe -O ReleaseSafe -lc OBS.zig
//
// POSIX details (termios, poll, sigaction, fork/exec) come from std.posix;
// date formatting uses libc's localtime_r/strftime via extern declarations
// (the exact same formatting as the reference's bash printf '%(...)T').
//
const std = @import("std");
const posix = std.posix;

// ---------------------------------------------------------------------------
// libc externs (glibc)
// ---------------------------------------------------------------------------
const Tm = extern struct {
    sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int,
    wday: c_int, yday: c_int, isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;
extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;

var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const alloc = arena_state.allocator();

var out_buf: [8192]u8 = undefined;

fn print(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&out_buf, fmt, args) catch return;
    _ = posix.write(1, s) catch {};
}

fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(2, s) catch {};
}

fn envOr(name: []const u8) []const u8 {
    return std.process.getEnvVarOwned(alloc, name) catch "";
}

fn dup(s: []const u8) []const u8 {
    return alloc.dupe(u8, s) catch "";
}

// ---------------------------------------------------------------------------
// Signals: the handler only stores the exit code (a plain store, safe in
// signal context); the interrupted poll loop sees it and runs the cleanup.
// ---------------------------------------------------------------------------
var sig_flag: c_int = 0;

fn onSignalInt(_: c_int) callconv(.c) void { sig_flag = 130; }
fn onSignalTerm(_: c_int) callconv(.c) void { sig_flag = 143; }
fn onSignalHup(_: c_int) callconv(.c) void { sig_flag = 129; }

fn installSignalHandlers() void {
    var sa = posix.Sigaction{
        .handler = .{ .handler = onSignalInt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    sa.handler = .{ .handler = onSignalTerm };
    posix.sigaction(posix.SIG.TERM, &sa, null);
    sa.handler = .{ .handler = onSignalHup };
    posix.sigaction(posix.SIG.HUP, &sa, null);
}

fn checkSignal() void {
    if (sig_flag != 0) {
        const code: u8 = @intCast(sig_flag);
        cleanup(code);
    }
}

// ---------------------------------------------------------------------------
// Clocks
// ---------------------------------------------------------------------------
var start_instant: i64 = 0;

fn nowSeconds() i64 {
    return std.time.timestamp() - start_instant;
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn sleepMs(ms: i64) void {
    var waited: i64 = 0;
    while (waited < ms) : (waited += 50) {
        checkSignal();
        const slice: u64 = @intCast(@min(ms - waited, 50));
        std.Thread.sleep(slice * std.time.ns_per_ms);
    }
}

// localTimeStr(fmt): strftime on the current local time.
fn localTimeStr(comptime fmt: [:0]const u8) []const u8 {
    var t: c_long = std.time.timestamp();
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return "";
    var buf: [128]u8 = undefined;
    const n = strftime(&buf, buf.len, fmt.ptr, &tm);
    if (n == 0) return "";
    return dup(buf[0..n]);
}

// ---------------------------------------------------------------------------
// Color themes
// ---------------------------------------------------------------------------
const Theme = struct { name: []const u8, primary: []const u8, secondary: []const u8 };
const THEMES = [_]Theme{
    .{ .name = "Purple", .primary = "\x1b[1;35m", .secondary = "\x1b[0;35m" },
    .{ .name = "Ocean", .primary = "\x1b[1;36m", .secondary = "\x1b[0;34m" },
    .{ .name = "Forest", .primary = "\x1b[1;32m", .secondary = "\x1b[0;32m" },
    .{ .name = "Sunset", .primary = "\x1b[1;33m", .secondary = "\x1b[0;31m" },
    .{ .name = "Rose", .primary = "\x1b[1;95m", .secondary = "\x1b[0;31m" },
    .{ .name = "Gold", .primary = "\x1b[1;93m", .secondary = "\x1b[0;33m" },
    .{ .name = "Mono", .primary = "\x1b[1;37m", .secondary = "\x1b[0;37m" },
    .{ .name = "Ice", .primary = "\x1b[1;96m", .secondary = "\x1b[0;36m" },
    .{ .name = "Ember", .primary = "\x1b[1;91m", .secondary = "\x1b[0;31m" },
    .{ .name = "Neon", .primary = "\x1b[1;92m", .secondary = "\x1b[0;96m" },
    .{ .name = "Cobalt", .primary = "\x1b[1;34m", .secondary = "\x1b[0;36m" },
    .{ .name = "Cherry", .primary = "\x1b[1;91m", .secondary = "\x1b[0;35m" },
};

const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const NC = "\x1b[0m";

const LOGO =
    \\ /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
    \\| $$_____/     | $$   | $$| $$_____/| $$  / $$
    \\| $$           | $$   | $$| $$      |  $$/ $$/
    \\| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
    \\| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
    \\| $$             \  $$$/  | $$       /$$/\  $$
    \\| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
    \\|________/         \_/    |________/|__/  |__/
;

const DEFAULT_QUOTES = [_][]const u8{
    "Focused effort beats scattered hours",
    "Every round finished is progress made",
    "Consistency beats intensity",
    "Start now, figure out the rest along the way",
    "A short break now means sharper focus next round",
};

var primary: []const u8 = THEMES[0].primary;
var secondary: []const u8 = THEMES[0].secondary;
var theme_name: []const u8 = THEMES[0].name;
var theme_index: usize = 0;
var theme_notice_until: i64 = 0;

fn setTheme(i: usize) bool {
    if (i >= THEMES.len) return false;
    theme_index = i;
    theme_name = THEMES[i].name;
    primary = THEMES[i].primary;
    secondary = THEMES[i].secondary;
    return true;
}

fn themeIndexByName(name: []const u8) ?usize {
    if (name.len == 0) return null;
    for (THEMES, 0..) |t, i| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return i;
    }
    return null;
}

var theme_file: []const u8 = "";

fn saveTheme() void {
    if (theme_file.len == 0) return;
    const f = std.fs.cwd().createFile(theme_file, .{}) catch return;
    defer f.close();
    f.writeAll(theme_name) catch {};
    f.writeAll("\n") catch {};
}

fn cycleTheme() void {
    _ = setTheme((theme_index + 1) % THEMES.len);
    saveTheme();
    theme_notice_until = nowSeconds() + 3;
    logEvent("Theme changed to: {s}", .{theme_name});
}

fn listThemes() void {
    for (THEMES) |t| {
        print("  {s:<8} {s}████{s}\n", .{ t.name, t.primary, t.secondary });
    }
}

// ---------------------------------------------------------------------------
// Environment overrides (captured before the defaults are applied)
// ---------------------------------------------------------------------------
var env_alert_sound: []const u8 = "";
var env_sink_name: []const u8 = "";
var env_state_dir: []const u8 = "";
var env_max_log_bytes: []const u8 = "";
var env_quotes: []const u8 = "";
var env_theme: []const u8 = "";

// ---------------------------------------------------------------------------
// Built-in defaults
// ---------------------------------------------------------------------------
var home: []const u8 = "";
var alert_sound: []const u8 = "";
var sink_name: []const u8 = "OBS_Alert_Sink";
var state_dir: []const u8 = "";
var max_log_bytes: i64 = 1048576;
var file_bar_width: i64 = 20;
var non_tty_enter_timeout: i64 = 300;
var alert_pid: posix.pid_t = 0;
var dir: []const u8 = "";
var quote_list: std.ArrayListUnmanaged([]const u8) = .{};
var points: i64 = 0;
var last_date: []const u8 = "";

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------
var prog: []const u8 = "OBS.zig";
var config_file: []const u8 = "";
var dry_run = false;
var use_alert = true;
var use_sink = true;
var rounds: i64 = 0;
var study_min: i64 = 0;
var break_min: i64 = 0;
var cli_theme: []const u8 = "";
var duration_unit: []const u8 = "minutes";
var seconds_per_unit: i64 = 60;
var config_theme: []const u8 = "";
var config_quotes: []const u8 = "";
var config_loaded: []const u8 = "";

// Used by the crash-injection test point (tests/ports.tsv).
fn crashExit(code: u8) void {
    onUnexpectedDeath(@as(i64, code));
    restoreTerminal();
    std.process.exit(code);
}

fn helpText(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\Usage: {s} [options] <rounds> <study_minutes> <break_minutes>
        \\
        \\Runs a Pomodoro-style study/break loop and writes the live state to text
        \\files that OBS Studio can display as "Text (read from file)" sources.
        \\
        \\Options:
        \\  -h, --help          Show this help and exit
        \\  -c, --config FILE   Load settings from FILE (bash syntax)
        \\  -d, --dry-run       Treat the durations as seconds (fast testing)
        \\  -n, --no-alert      Disable the audio alert
        \\  -s, --no-sink       Don't create or use the OBS virtual audio sink
        \\  -t, --theme NAME    Use a color theme (see --list-themes)
        \\      --list-themes   Show the available color themes and exit
        \\
        \\Arguments:
        \\  rounds             1-50   number of study rounds
        \\  study_minutes      1-600  length of a study phase
        \\  break_minutes      1-120  length of a break phase
        \\
        \\Examples:
        \\  {s} 5 50 10           # 5 rounds, 50 min study, 10 min break
        \\  {s} --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
        \\  {s} --theme Ocean 5 50 10
        \\
        \\Keys (while a phase is running):
        \\  p / space   pause and resume the current phase
        \\  s           skip the rest of the current phase
        \\  q           quit the session
        \\  Alt+T       switch to the next color theme
        \\
        \\Environment overrides:
        \\  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME
        \\
        \\Config file (first one that exists):
        \\  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
        \\
    , .{ prog, prog, prog, prog }) catch "";
}

fn printHelp(code: u8) noreturn {
    var buf: [4096]u8 = undefined;
    _ = posix.write(1, helpText(&buf)) catch {};
    std.process.exit(code);
}

fn usageError() noreturn {
    var buf: [4096]u8 = undefined;
    _ = posix.write(2, helpText(&buf)) catch {};
    std.process.exit(1);
}

fn badNumber(v: []const u8) bool {
    // ^[1-9][0-9]{0,3}$
    if (v.len < 1 or v.len > 4) return true;
    if (v[0] < '1' or v[0] > '9') return true;
    for (v[1..]) |c| {
        if (c < '0' or c > '9') return true;
    }
    return false;
}

fn parseInt(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn parseArgs(argv: [][:0]u8) void {
    var positional = std.ArrayListUnmanaged([]const u8){};
    var i: usize = 0;
    outer: while (i < argv.len) {
        const a: []const u8 = argv[i];
        if (eq(a, "-h") or eq(a, "--help")) {
            printHelp(0);
        } else if (eq(a, "-c") or eq(a, "--config")) {
            if (i + 1 >= argv.len) {
                eprint("Error: {s} needs a file argument\n", .{a});
                usageError();
            }
            config_file = argv[i + 1];
            i += 2;
        } else if (eq(a, "-d") or eq(a, "--dry-run")) {
            dry_run = true;
            i += 1;
        } else if (eq(a, "-n") or eq(a, "--no-alert")) {
            use_alert = false;
            i += 1;
        } else if (eq(a, "-s") or eq(a, "--no-sink")) {
            use_sink = false;
            i += 1;
        } else if (eq(a, "-t") or eq(a, "--theme")) {
            if (i + 1 >= argv.len) {
                eprint("Error: {s} needs a theme name\n", .{a});
                usageError();
            }
            cli_theme = argv[i + 1];
            i += 2;
        } else if (eq(a, "--list-themes")) {
            listThemes();
            std.process.exit(0);
        } else if (eq(a, "--")) {
            var j = i + 1;
            while (j < argv.len) : (j += 1) positional.append(alloc, argv[j]) catch {};
            break :outer;
        } else if (a.len > 0 and a[0] == '-') {
            eprint("Error: unknown option: {s}\n", .{a});
            usageError();
        } else {
            var j = i;
            while (j < argv.len) : (j += 1) positional.append(alloc, argv[j]) catch {};
            break :outer;
        }
    }

    if (positional.items.len != 3) usageError();
    for (positional.items) |v| {
        if (badNumber(v)) usageError();
    }
    rounds = parseInt(positional.items[0]) orelse usageError();
    study_min = parseInt(positional.items[1]) orelse usageError();
    break_min = parseInt(positional.items[2]) orelse usageError();
    if (rounds > 50) {
        eprint("Error: rounds must be <= 50\n", .{});
        usageError();
    }
    if (study_min > 600) {
        eprint("Error: study minutes must be <= 600\n", .{});
        usageError();
    }
    if (break_min > 120) {
        eprint("Error: break minutes must be <= 120\n", .{});
        usageError();
    }
    if (dry_run) {
        duration_unit = "seconds";
        seconds_per_unit = 1;
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn joinPath(a_dir: []const u8, name: []const u8) []const u8 {
    return std.fs.path.join(alloc, &.{ a_dir, name }) catch "";
}

// ---------------------------------------------------------------------------
// Configuration file (bash syntax, loaded by a child bash)
// ---------------------------------------------------------------------------
const CONFIG_DUMP_SH =
    \\set -u
    \\IFS=$'\037' read -r -a QUOTE_LIST <<< "${QUOTES_SEED-}"
    \\unset QUOTES_SEED
    \\source "$1" || true
    \\{
    \\  d() { printf '%s\037%s\036' "$1" "${2-}"; }
    \\  d ALERT_SOUND "${ALERT_SOUND-}"
    \\  d SINK_NAME "${SINK_NAME-}"
    \\  d STATE_DIR "${STATE_DIR-}"
    \\  d MAX_LOG_BYTES "${MAX_LOG_BYTES-}"
    \\  d FILE_BAR_WIDTH "${FILE_BAR_WIDTH-}"
    \\  d NON_TTY_ENTER_TIMEOUT "${NON_TTY_ENTER_TIMEOUT-}"
    \\  d THEME "${THEME-}"
    \\  d POINTS "${POINTS-}"
    \\  d LAST_DATE "${LAST_DATE-}"
    \\  d QUOTES "${QUOTES-}"
    \\  for q in ${QUOTE_LIST[@]+"${QUOTE_LIST[@]}"}; do d QUOTE "$q"; done
    \\} > "$2"
;

fn fileExists(p: []const u8) bool {
    const st = std.fs.cwd().statFile(p) catch return false;
    return st.kind == .file;
}

fn findConfigFile() ?[]const u8 {
    if (config_file.len != 0) return config_file;
    const env_cfg = envOr("OBS_PANEL_CONFIG");
    if (env_cfg.len != 0) return env_cfg;
    var xdg = envOr("XDG_CONFIG_HOME");
    if (xdg.len == 0) {
        xdg = if (home.len != 0) joinPath(home, ".config") else "/.config";
    }
    const xdg_cfg = joinPath(xdg, "obs-study-panel/config");
    if (fileExists(xdg_cfg)) return xdg_cfg;
    const local_cfg = joinPath(dir, "obs-panel.conf");
    if (fileExists(local_cfg)) return local_cfg;
    return null;
}

fn quotesToList(raw: []const u8) std.ArrayListUnmanaged([]const u8) {
    var list = std.ArrayListUnmanaged([]const u8){};
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line0| {
        const line = if (std.mem.endsWith(u8, line0, "\r"))
            line0[0 .. line0.len - 1] else line0;
        if (line.len != 0) list.append(alloc, dup(line)) catch {};
    }
    return list;
}

fn loadConfig(path: []const u8) void {
    // bash's [[ -r ]]: readability probe via access(2).
    const pathZ = alloc.dupeZ(u8, path) catch "";
    if (std.c.access(pathZ.ptr, 4) != 0) {
        eprint("Error: config file is not readable: {s}\n", .{path});
        std.process.exit(1);
    }
    if (which("bash") == null) {
        eprint("Error: bash is required to read the config file: {s}\n", .{path});
        std.process.exit(1);
    }
    // Syntax gate: bash -n, first 3 lines of its stderr.
    {
        var child = std.process.Child.init(&.{ "bash", "-n", path }, alloc);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Pipe;
        child.spawn() catch {};
        var err_buf = std.ArrayListUnmanaged(u8){};
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(child.stderr.?.handle, &buf) catch 0;
            if (n == 0) break;
            err_buf.appendSlice(alloc, buf[0..n]) catch {};
        }
        const term = child.wait() catch {
            std.process.exit(1);
        };
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    eprint("Error: syntax error in config file: {s}\n", .{path});
                    var printed: usize = 0;
                    var lit = std.mem.splitScalar(u8, err_buf.items, '\n');
                    while (lit.next()) |line| {
                        if (line.len == 0 or printed >= 3) continue;
                        eprint("{s}\n", .{line});
                        printed += 1;
                    }
                    std.process.exit(1);
                }
            },
            else => std.process.exit(1),
        }
    }

    // Seed the pre-config defaults, exactly what the reference holds while it
    // sources the file (the real environment's THEME/QUOTES pass through).
    var dump_path_buf: [128]u8 = undefined;
    const dump_path = std.fmt.bufPrint(&dump_path_buf, "/tmp/obs-panel-conf-{d}-{d}",
        .{ std.c.getpid(), nowMs() }) catch return;
    {
        var env_map = std.process.getEnvMap(alloc) catch return;
        env_map.put("ALERT_SOUND", alert_sound) catch {};
        env_map.put("SINK_NAME", sink_name) catch {};
        env_map.put("STATE_DIR", "") catch {};
        env_map.put("MAX_LOG_BYTES", "1048576") catch {};
        env_map.put("FILE_BAR_WIDTH", "20") catch {};
        env_map.put("NON_TTY_ENTER_TIMEOUT", "300") catch {};
        env_map.put("POINTS", intToString(points)) catch {};
        env_map.put("LAST_DATE", last_date) catch {};
        var seed = std.ArrayListUnmanaged(u8){};
        for (quote_list.items, 0..) |q, qi| {
            if (qi > 0) seed.append(alloc, 0x1f) catch {};
            seed.appendSlice(alloc, q) catch {};
        }
        env_map.put("QUOTES_SEED", seed.items) catch {};

        var child = std.process.Child.init(&.{
            "bash", "-c", CONFIG_DUMP_SH, "obs-panel", path, dump_path,
        }, alloc);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;   // config echo goes to our stdout
        child.stderr_behavior = .Inherit;
        child.env_map = &env_map;
        child.spawn() catch {};
        const term = child.wait() catch {
            std.process.exit(1);
        };
        const child_rc: i64 = switch (term) {
            .Exited => |c| c,
            .Signal => |s| 128 + @as(i64, @intCast(s)),
            else => 1,
        };

        const raw = std.fs.cwd().readFileAlloc(alloc, dump_path, 1 << 20) catch "";
        std.fs.cwd().deleteFile(dump_path) catch {};
        if (raw.len == 0) {
            // The config called exit N before the dump was written.
            std.process.exit(@intCast(if (child_rc != 0) child_rc else 1));
        }

        var values = std.StringHashMapUnmanaged([]const u8){};
        var quotes = std.ArrayListUnmanaged([]const u8){};
        var start: usize = 0;
        while (start <= raw.len) {
            const rec_end = std.mem.indexOfScalarPos(u8, raw, start, 0x1e);
            const end = rec_end orelse raw.len;
            if (end > start) {
                if (std.mem.indexOfScalarPos(u8, raw, start, 0x1f)) |sep| {
                    if (sep < end) {
                        const rec_key = raw[start..sep];
                        const value = raw[sep + 1 .. end];
                        if (eq(rec_key, "QUOTE")) {
                            quotes.append(alloc, dup(value)) catch {};
                        } else {
                            values.put(alloc, rec_key, dup(value)) catch {};
                        }
                    }
                }
            }
            if (rec_end == null) break;
            start = end + 1;
        }

        alert_sound = values.get("ALERT_SOUND") orelse alert_sound;
        sink_name = values.get("SINK_NAME") orelse sink_name;
        state_dir = values.get("STATE_DIR") orelse "";
        max_log_bytes = parseInt(values.get("MAX_LOG_BYTES") orelse "1048576") orelse 1048576;
        file_bar_width = parseInt(values.get("FILE_BAR_WIDTH") orelse "20") orelse 20;
        non_tty_enter_timeout =
            parseInt(values.get("NON_TTY_ENTER_TIMEOUT") orelse "300") orelse 300;
        config_theme = values.get("THEME") orelse "";
        points = parseInt(values.get("POINTS") orelse "0") orelse 0;
        last_date = values.get("LAST_DATE") orelse "";
        config_quotes = values.get("QUOTES") orelse "";
        quote_list = quotes;
        config_loaded = dup(path);
    }
}

fn u(v: i64) u64 {
    return @intCast(v);
}

fn intToString(v: i64) []const u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{v}) catch "0";
}

fn applyQuoteSources() void {
    if (env_quotes.len != 0) {
        quote_list = quotesToList(env_quotes);
    } else if (config_quotes.len != 0) {
        quote_list = quotesToList(config_quotes);
    }
}

fn sanityKnobs() void {
    if (max_log_bytes <= 0) max_log_bytes = 1048576;
    if (file_bar_width <= 0 or file_bar_width > 200) file_bar_width = 20;
    if (non_tty_enter_timeout <= 0 or non_tty_enter_timeout > 3600)
        non_tty_enter_timeout = 300;
}

// ---------------------------------------------------------------------------
// Paths and runtime state
// ---------------------------------------------------------------------------
var date_file: []const u8 = "";
var day_file: []const u8 = "";
var session_file: []const u8 = "";
var timer_file: []const u8 = "";
var log_file: []const u8 = "";
var progress_file: []const u8 = "";
var points_file: []const u8 = "";
var message_file: []const u8 = "";
var next_file: []const u8 = "";
var overlay_file: []const u8 = "";

var session_text: []const u8 = "";
var remaining_str: []const u8 = "00:00:00";
var pct: i64 = 0;
var next_text: []const u8 = "";
var message_text: []const u8 = "";
var last_day: []const u8 = "";
var state_ready = false;
var state_finalized = false;
var in_cleanup = false;

fn setupPaths() void {
    if (state_dir.len == 0) state_dir = dir;
    std.fs.cwd().makePath(state_dir) catch {
        eprint("Error: cannot create state dir: {s}\n", .{state_dir});
        std.process.exit(1);
    };
    date_file = joinPath(state_dir, "date.txt");
    day_file = joinPath(state_dir, "day.txt");
    session_file = joinPath(state_dir, "session.txt");
    timer_file = joinPath(state_dir, "timer.txt");
    log_file = joinPath(state_dir, "log.txt");
    progress_file = joinPath(state_dir, "progress.txt");
    points_file = joinPath(state_dir, "points.txt");
    message_file = joinPath(state_dir, "message.txt");
    next_file = joinPath(state_dir, "next.txt");
    overlay_file = joinPath(state_dir, "overlay.txt");
    theme_file = joinPath(state_dir, "theme.txt");
}

fn selectTheme() void {
    var request = cli_theme;
    if (request.len == 0 and env_theme.len != 0) request = env_theme;
    if (request.len == 0 and config_theme.len != 0) request = config_theme;
    if (request.len == 0 and theme_file.len != 0 and fileExists(theme_file)) {
        const fh = std.fs.cwd().openFile(theme_file, .{}) catch null;
        if (fh) |f| {
            defer f.close();
            var buf: [512]u8 = undefined;
            const n = posix.read(f.handle, &buf) catch 0;
            var line = buf[0..n];
            if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
            request = dup(line);
        }
    }
    if (request.len != 0) {
        if (themeIndexByName(request)) |idx| {
            _ = setTheme(idx);
        } else {
            eprint("Warning: unknown theme '{s}', using {s}\n", .{ request, theme_name });
        }
    }
}

// ---------------------------------------------------------------------------
// Startup logo
// ---------------------------------------------------------------------------
fn printLogo() void {
    print("{s}\n", .{primary});
    print("{s}\n", .{LOGO});
    print("{s}\n", .{NC});
    print("{s}{s}     Study / Break Timer Protocol{s}\n", .{ primary, BOLD, NC });
    print("{s}── live state written to date · day · session · timer · log{s}\n", .{ DIM, NC });
    print("\n", .{});
}

// ---------------------------------------------------------------------------
// OBS state files
// ---------------------------------------------------------------------------
fn writeWholeFile(p: []const u8, data: []const u8) void {
    const f = std.fs.cwd().createFile(p, .{}) catch return;
    defer f.close();
    f.writeAll(data) catch {};
}

fn updateDateDay() void {
    const d = localTimeStr("%Y-%m-%d");
    if (eq(d, last_date)) return;
    last_date = d;
    last_day = localTimeStr("%A");
    var buf: [600]u8 = undefined;
    writeWholeFile(date_file, std.fmt.bufPrint(&buf, "{s}\n", .{d}) catch return);
    writeWholeFile(day_file, std.fmt.bufPrint(&buf, "{s}\n", .{last_day}) catch return);
}

fn syncState() void {
    updateDateDay();
    publishState();
}

fn makeBar(out: []u8, filled: i64, width: i64, fill: u8, empty: u8, head: u8) []const u8 {
    if (width < 0) return out[0..0];
    const w: usize = @intCast(width);
    for (0..w) |i| {
        if (@as(i64, @intCast(i)) < filled) {
            out[i] = if (head != 0 and @as(i64, @intCast(i)) == filled - 1) head else fill;
        } else {
            out[i] = empty;
        }
    }
    return out[0..w];
}

var bar_buf: [256]u8 = undefined;

var overlay_buf: [8192]u8 = undefined;

fn publishState() void {
    var buf: [4096]u8 = undefined;
    const obuf = &overlay_buf;
    const fbw: usize = @intCast(file_bar_width);
    const filled = @divTrunc(pct * file_bar_width, 100);
    const bar = makeBar(&bar_buf, filled, file_bar_width, '#', '-', 0);

    writeWholeFile(session_file, std.fmt.bufPrint(&buf, "{s}\n", .{session_text}) catch return);
    writeWholeFile(timer_file, std.fmt.bufPrint(&buf, "{s}\n", .{remaining_str}) catch return);
    writeWholeFile(points_file, std.fmt.bufPrint(&buf, "{d}\n", .{points}) catch return);
    writeWholeFile(next_file, std.fmt.bufPrint(&buf, "{s}\n", .{next_text}) catch return);
    writeWholeFile(message_file, std.fmt.bufPrint(&buf, "{s}\n", .{message_text}) catch return);
    const pct_line = std.fmt.bufPrint(&buf, "[{s}] {d:>3}%\n", .{ bar, u(pct) }) catch return;
    writeWholeFile(progress_file, pct_line);

    const overlay = if (message_text.len != 0)
        std.fmt.bufPrint(obuf,
            "{s}  {s}\n{s}\n{s}\n{s}Pts: {d}\nNext: {s}\n{s}\n", .{
                last_date, last_day, session_text, remaining_str,
                pct_line, u(points), next_text, message_text,
            })
    else
        std.fmt.bufPrint(obuf,
            "{s}  {s}\n{s}\n{s}\n{s}Pts: {d}\nNext: {s}\n", .{
                last_date, last_day, session_text, remaining_str,
                pct_line, u(points), next_text,
            });
    const overlay_s = overlay catch return;
    writeWholeFile(overlay_file, overlay_s);
    _ = fbw;
}

fn rotateLogIfNeeded() void {
    const st = std.fs.cwd().statFile(log_file) catch return;
    if (st.kind != .file) return;
    if (@as(i64, @intCast(st.size)) < max_log_bytes) return;
    const backup = std.fmt.allocPrint(alloc, "{s}.1", .{log_file}) catch return;
    std.fs.cwd().rename(log_file, backup) catch return;
    writeWholeFile(log_file, "");
}

fn logEvent(comptime fmt: []const u8, args: anytype) void {
    rotateLogIfNeeded();
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    var line_buf: [4608]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "[{s}] {s}\n", .{
        localTimeStr("%Y-%m-%d %H:%M:%S"), msg,
    }) catch return;
    const f = std.fs.cwd().createFile(log_file, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    f.writeAll(line) catch {};
}

// ---------------------------------------------------------------------------
// Audio alerts
// ---------------------------------------------------------------------------
fn which(name: []const u8) ?[]const u8 {
    const path = envOr("PATH");
    if (path.len == 0) return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d0| {
        if (d0.len == 0) continue;
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ d0, name }) catch continue;
        const st = std.fs.cwd().statFile(full) catch continue;
        if (st.kind != .file) continue;
        // executable bit (X_OK): at least one of x for owner/group/other
        if (st.mode & 0o111 != 0) return full;
    }
    return null;
}

fn sinkIsReady() bool {
    if (which("pactl") == null) return false;
    var child = std.process.Child.init(&.{ "pactl", "list", "short", "sinks" }, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return false;
    var text = std.ArrayListUnmanaged(u8){};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(child.stdout.?.handle, &buf) catch 0;
        if (n == 0) break;
        text.appendSlice(alloc, buf[0..n]) catch {};
    }
    const term = child.wait() catch return false;
    switch (term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \\t");
        _ = fields.next() orelse continue;
        const second = fields.next() orelse continue;
        if (eq(second, sink_name)) return true;
    }
    return false;
}

fn setupAudioSink() void {
    if (!use_sink) return;
    if (which("pactl") == null) return;
    if (sinkIsReady()) return;
    const sink_arg = std.fmt.allocPrint(alloc, "sink_name={s}", .{sink_name}) catch return;
    const desc_arg = std.fmt.allocPrint(alloc, "sink_properties=device.description={s}", .{sink_name}) catch return;
    var child = std.process.Child.init(
        &.{ "pactl", "load-module", "module-null-sink", sink_arg, desc_arg }, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    _ = child.wait() catch {};
}

var alert_proc: ?std.process.Child = null;

fn stopAlert() void {
    if (alert_proc) |*child| {
        posix.kill(child.id, posix.SIG.TERM) catch {};
        _ = child.wait() catch {};
        alert_proc = null;
    }
}

fn playAlert() void {
    if (!use_alert) return;
    stopAlert();   // never let two alarms overlap
    const file_ok = blk: {
        const st = std.fs.cwd().statFile(alert_sound) catch break :blk false;
        break :blk st.kind == .file;
    };
    if (alert_sound.len == 0 or !file_ok) {
        print("{s}(alert file not found: {s}){s}\n", .{
            DIM, if (alert_sound.len != 0) alert_sound else "none", NC,
        });
        return;
    }
    const player: []const []const u8 = blk: {
        if (which("mpv") != null)
            break :blk &.{ "mpv", "--no-video", "--volume=70" };
        if (which("paplay") != null)
            break :blk &.{"paplay"};
        if (which("ffplay") != null)
            break :blk &.{ "ffplay", "-nodisp", "-autoexit" };
        if (which("cvlc") != null)
            break :blk &.{ "cvlc", "--play-and-exit", "--no-video", "--volume=70" };
        print("{s}(no audio player found - install mpv / paplay / ffplay){s}\n", .{ DIM, NC });
        return;
    };

    if (use_sink and !sinkIsReady()) setupAudioSink();

    const on_sink = use_sink and sinkIsReady();
    var argv = std.ArrayListUnmanaged([]const u8){};
    for (player) |a| argv.append(alloc, a) catch {};
    argv.append(alloc, alert_sound) catch {};

    var child = std.process.Child.init(argv.items, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (on_sink) {
        var env_map = std.process.getEnvMap(alloc) catch return;
        env_map.put("PULSE_SINK", sink_name) catch {};
        child.env_map = &env_map;
    }
    child.spawn() catch return;
    alert_proc = child;
    if (on_sink) {
        print("{s}-> alert on OBS sink ({s}){s}\n", .{ DIM, sink_name, NC });
    } else {
        print("{s}-> alert on default device (OBS sink unavailable){s}\n", .{ secondary, NC });
    }
}

// ---------------------------------------------------------------------------
// Keyboard input
// ---------------------------------------------------------------------------
var stdin_is_tty = false;
var term_saved: ?posix.termios = null;
var key: []const u8 = "";
var key_read = false;

fn setupTerminal() void {
    stdin_is_tty = posix.isatty(0);
    if (!stdin_is_tty) return;
    const saved = posix.tcgetattr(0) catch return;
    term_saved = saved;
    var t = saved;
    // cbreak like the reference's `read -s`: echo and canonical mode off,
    // ISIG stays on so Ctrl+C still generates SIGINT.
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(0, .FLUSH, t) catch {};
}

fn restoreTerminal() void {
    if (term_saved) |t| {
        posix.tcsetattr(0, .DRAIN, t) catch {};
        term_saved = null;
    }
}

/// Wait until fd 0 is readable (or a signal arrives). true = readable.
fn pollReadable(ms: i64) bool {
    const deadline = nowMs() + ms;
    while (true) {
        checkSignal();
        var left = deadline - nowMs();
        if (left < 0) left = 0;
        var fds = [_]posix.pollfd{
            .{ .fd = 0, .events = posix.POLL.IN, .revents = 0 },
        };
        const rc = posix.poll(&fds, @intCast(left)) catch return false;
        if (rc > 0) return fds[0].revents != 0;
        if (rc == 0) {
            if (nowMs() >= deadline) return false;
            continue;
        }
    }
}

/// One byte with a timeout: 0..255, -1 timeout, -2 EOF.
fn readByteTimeout(ms: i64) i32 {
    if (!pollReadable(ms)) return -1;
    var buf: [1]u8 = undefined;
    const n = posix.read(0, &buf) catch return -1;
    if (n == 0) return -2;
    return buf[0];
}

fn waitKey(timeout_s: f64) void {
    key = "";
    key_read = false;
    if (!stdin_is_tty) {
        const ms: i64 = @intFromFloat(timeout_s * 1000.0);
        sleepMs(ms);
        return;
    }
    const ms: i64 = @intFromFloat(timeout_s * 1000.0);
    const b = readByteTimeout(ms);
    if (b < 0) return;
    key_read = true;
    if (b == 27) {
        const nxt = readByteTimeout(300);
        if (nxt == 't' or nxt == 'T') key = "alt-t";
    } else {
        key = alloc.dupe(u8, &.{@intCast(b)}) catch "";
    }
}

fn discardPendingInput() void {
    if (!stdin_is_tty) return;
    while (true) {
        const b = readByteTimeout(10);
        if (b < 0) return;
    }
}

fn waitForEnter() void {
    if (stdin_is_tty) {
        while (true) {
            const b = readByteTimeout(1000);
            if (b == -1) {
                updateDateDay();
            } else if (b == -2 or b == '\n') {
                return;
            }
        }
    }
    // Not a terminal: bounded wait, 5 s slices.
    var waited: i64 = 0;
    while (waited < non_tty_enter_timeout) : (waited += 5) {
        const slice_end = nowMs() + 5000;
        while (true) {
            const left = slice_end - nowMs();
            if (left <= 0) break;
            if (!pollReadable(left)) break;
            var buf: [4096]u8 = undefined;
            const n = posix.read(0, &buf) catch return;
            if (n == 0) return;   // EOF
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) return;
        }
    }
}

// ---------------------------------------------------------------------------
// Status / progress UI
// ---------------------------------------------------------------------------
const TERM_BAR_WIDTH = 24;
const BOX_INNER = 62;

fn phaseColor(label: []const u8) []const u8 {
    return if (eq(label, "STUDY")) primary else secondary;
}

fn drawStatus(label: []const u8, round_: i64, total_rounds: i64,
              elapsed: i64, total: i64, paused: bool) void {
    var filled: i64 = 0;
    if (total > 0) filled = @divTrunc(elapsed * TERM_BAR_WIDTH, total);
    if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH;
    var tbar_buf: [64]u8 = undefined;
    const bar = makeBar(&tbar_buf, filled, TERM_BAR_WIDTH, '=', ' ', '>');
    const color = phaseColor(label);
    var flag_buf: [256]u8 = undefined;
    var flag_len: usize = 0;
    if (paused) {
        const base = std.fmt.bufPrint(flag_buf[0..], "{s} PAUSED{s}", .{
            primary, NC }) catch "";
        flag_len = base.len;
    }
    if (nowSeconds() < theme_notice_until) {
        // Sequential appends into the same buffer: no aliasing.
        const extra = std.fmt.bufPrint(flag_buf[flag_len..], "  {s}Theme: {s}{s}", .{
            DIM, theme_name, NC }) catch "";
        flag_len += extra.len;
    }
    const flag: []const u8 = flag_buf[0..flag_len];
    print("\r\x1b[K", .{});
    print("{s}{s}{s: <6}{s} [{d}/{d}] {s}[{s}]{s} {d:>3}%  {s}  {s}Pts:{d}{s}{s}", .{
        BOLD,        color,      label,      NC,
        round_,      total_rounds,
        color,       bar,        NC,
        u(pct),      remaining_str,
        primary,     points,     NC,         flag,
    });
}

fn boxRow(color: []const u8, plain: []const u8, styled: []const u8) void {
    var pad: i64 = BOX_INNER - @as(i64, @intCast(plain.len));
    if (pad < 0) pad = 0;
    print("{s}║{s}", .{ color, styled });
    var i: i64 = 0;
    while (i < pad) : (i += 1) print(" ", .{});
    print("{s}║{s}\n", .{ color, NC });
}

fn durationLabel(n: i64) []const u8 {
    if (n == 1) return if (eq(duration_unit, "seconds")) "1 second" else "1 minute";
    return std.fmt.allocPrint(alloc, "{d} {s}", .{ n, duration_unit }) catch "";
}

fn roundsLabel(n: i64) []const u8 {
    return if (n == 1) "1 round" else
        std.fmt.allocPrint(alloc, "{d} rounds", .{n}) catch "";
}

fn phaseHeader(label: []const u8, round_: i64, total: i64, minutes: i64,
               subtitle0: []const u8) void {
    const keep: usize = if (subtitle0.len > BOX_INNER - 4) BOX_INNER - 4 else subtitle0.len;
    const subtitle = subtitle0[0..keep];
    const color = phaseColor(label);
    const bar = ("═" ** BOX_INNER);
    print("\n", .{});
    print("{s}╔{s}╗{s}\n", .{ color, bar, NC });
    const info = std.fmt.allocPrint(alloc, "{s}  ·  Round {d} / {d}  ·  {s}", .{
        label, round_, total, durationLabel(minutes),
    }) catch return;
    const styled = std.fmt.allocPrint(alloc, "  {s}{s}{s}{s}  ·  Round {d} / {d}  ·  {s}", .{
        BOLD, label, NC, color, round_, total, durationLabel(minutes),
    }) catch return;
    boxRow(color, std.fmt.allocPrint(alloc, "  {s}", .{info}) catch return, styled);
    const sub_styled = std.fmt.allocPrint(alloc, "  {s}{s}{s}{s}", .{
        DIM, subtitle, NC, color }) catch return;
    boxRow(color, std.fmt.allocPrint(alloc, "  {s}", .{subtitle}) catch return, sub_styled);
    if (stdin_is_tty) {
        const keys = "  p pause  ·  s skip  ·  q quit  ·  Alt+T theme";
        const keys_styled = std.fmt.allocPrint(alloc, "{s}{s}{s}{s}", .{
            DIM, keys, NC, color }) catch return;
        boxRow(color, keys, keys_styled);
    }
    print("{s}╚{s}╝{s}\n", .{ color, bar, NC });
    print("\n", .{});
}

fn showCompletion(phase: []const u8, round_: i64, total_rounds: i64,
                  next_phase: []const u8, skipped: bool) void {
    const width = 60;
    const line = "=" ** width;
    const title: []const u8 = if (skipped) "PHASE SKIPPED" else if (eq(phase, "STUDY"))
        "STUDY SESSION COMPLETE" else "BREAK COMPLETE";
    const color = phaseColor(phase);
    const pad: usize = @intCast(@divTrunc(width + @as(i64, @intCast(title.len)), 2));
    print("\n", .{});
    print("{s}{s}{s}\n", .{ color, line, NC });
    print("{s}", .{color});
    var i: usize = 0;
    while (i < pad) : (i += 1) print(" ", .{});
    print("{s}{s}\n", .{ title, NC });
    print("{s}{s}{s}\n", .{ color, line, NC });
    print("\n", .{});
    print("  Round:   {s}{d}{s} / {d}\n", .{ BOLD, round_, NC, total_rounds });
    print("  Points:  {s}{d}{s}\n", .{ primary, points, NC });
    print("\n", .{});
    if (eq(next_phase, "None")) {
        print("  Next:    {s}Session complete{s}\n", .{ DIM, NC });
    } else {
        print("  Next:    {s}{s}{s}\n", .{ BOLD, next_phase, NC });
    }
    print("\n", .{});
    print("  {s}Press Enter to continue...{s}", .{ primary, NC });
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------
var phase_label: []const u8 = "";
var phase_subtitle: []const u8 = "";
var phase_next: []const u8 = "";
var phase_total: i64 = 0;
var phase_elapsed: i64 = 0;
var phase_paused = false;
var phase_skipped = false;
var phase_start: i64 = 0;
var phase_paused_total: i64 = 0;
var phase_pause_at: i64 = 0;

fn fmtHms(total: i64) []const u8 {
    return std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        u(@divTrunc(total, 3600)), u(@divTrunc(@mod(total, 3600), 60)),
        u(@mod(total, 60)),
    }) catch "00:00:00";
}

fn phasePrepare(ptype: []const u8, minutes: i64, round_: i64, total_rounds: i64) void {
    if (eq(ptype, "study")) {
        phase_label = "STUDY";
        if (quote_list.items.len > 0) {
            const pick = std.crypto.random.uintLessThan(usize, quote_list.items.len);
            phase_subtitle = quote_list.items[pick];
        } else {
            phase_subtitle = "Stay focused.";
        }
    } else {
        phase_label = "BREAK";
        phase_subtitle = "Relax and recharge.";
    }
    if (eq(ptype, "study")) {
        phase_next = if (round_ < total_rounds)
            std.fmt.allocPrint(alloc, "Break ({s})", .{durationLabel(break_min)}) catch ""
        else
            "None";
    } else {
        phase_next = std.fmt.allocPrint(alloc, "Study ({s})", .{durationLabel(study_min)}) catch "";
    }
    phase_total = minutes * seconds_per_unit;
    phase_elapsed = 0;
    phase_paused = false;
    phase_skipped = false;
    phase_start = nowSeconds();
    phase_paused_total = 0;
    phase_pause_at = 0;

    session_text = std.fmt.allocPrint(alloc, "{s} {d}/{d}", .{
        phase_label, round_, total_rounds }) catch "";
    remaining_str = fmtHms(phase_total);
    pct = 0;
    next_text = if (eq(phase_next, "None")) "Session complete" else phase_next;
    message_text = phase_subtitle;

    logEvent("Start: {s} {d}/{d} ({s})", .{
        phase_label, round_, total_rounds, durationLabel(minutes) });
    phaseHeader(phase_label, round_, total_rounds, minutes, phase_subtitle);
    syncState();
}

fn phaseHandleKey(round_: i64, total_rounds: i64) void {
    if (eq(key, "p") or eq(key, "P") or eq(key, " ")) {
        if (phase_paused) {
            phase_paused_total += nowSeconds() - phase_pause_at;
            phase_paused = false;
            logEvent("Resumed: {s} {d}/{d}", .{ phase_label, round_, total_rounds });
        } else {
            phase_paused = true;
            phase_pause_at = nowSeconds();
            logEvent("Paused: {s} {d}/{d}", .{ phase_label, round_, total_rounds });
        }
    } else if (eq(key, "s") or eq(key, "S")) {
        phase_skipped = true;
        logEvent("Skipped: {s} {d}/{d}", .{ phase_label, round_, total_rounds });
    } else if (eq(key, "q") or eq(key, "Q")) {
        logEvent("Quit requested by user", .{});
        cleanup(0);
    } else if (eq(key, "alt-t")) {
        cycleTheme();
    }
}

fn phaseCount(round_: i64, total_rounds: i64) void {
    while (phase_elapsed < phase_total) {
        var remaining = phase_total - phase_elapsed;
        if (remaining < 0) remaining = 0;
        remaining_str = fmtHms(remaining);
        pct = 0;
        if (phase_total > 0) pct = @divTrunc(phase_elapsed * 100, phase_total);
        if (pct > 100) pct = 100;
        session_text = if (phase_paused)
            std.fmt.allocPrint(alloc, "{s} {d}/{d} (PAUSED)", .{
                phase_label, round_, total_rounds }) catch ""
        else
            std.fmt.allocPrint(alloc, "{s} {d}/{d}", .{
                phase_label, round_, total_rounds }) catch "";

        syncState();
        drawStatus(phase_label, round_, total_rounds, phase_elapsed, phase_total,
            phase_paused);

        waitKey(1.0);
        if (key_read) {
            phaseHandleKey(round_, total_rounds);
            if (phase_skipped) break;
        }
        // CRASH-INJECT-POINT
        if (!phase_paused) {
            phase_elapsed = nowSeconds() - phase_start - phase_paused_total;
        }
    }
}

fn phaseFinish(round_: i64, total_rounds: i64) void {
    if (phase_skipped) {
        session_text = std.fmt.allocPrint(alloc, "{s} {d}/{d} (SKIPPED)", .{
            phase_label, round_, total_rounds }) catch "";
    } else {
        pct = 100;
        points += 1;
    }
    remaining_str = "00:00:00";
    syncState();
    drawStatus(phase_label, round_, total_rounds, phase_elapsed, phase_total, false);
    print("\n", .{});
    logEvent("End: {s} {d}/{d}", .{ phase_label, round_, total_rounds });

    playAlert();

    discardPendingInput();
    showCompletion(phase_label, round_, total_rounds, phase_next, phase_skipped);
    waitForEnter();
    stopAlert();
    print("\n", .{});
}

fn runPhase(ptype: []const u8, minutes: i64, round_: i64, total_rounds: i64) void {
    phasePrepare(ptype, minutes, round_, total_rounds);
    phaseCount(round_, total_rounds);
    phaseFinish(round_, total_rounds);
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------
fn resetStateFiles() void {
    session_text = "stopped";
    remaining_str = "00:00:00";
    pct = 0;
    next_text = "";
    syncState();
}

fn cleanup(code: u8) noreturn {
    if (in_cleanup) {
        // Repeated signals are ignored while shutting down.
        std.process.exit(code);
    }
    in_cleanup = true;
    state_finalized = true;
    stopAlert();
    resetStateFiles();
    logEvent("Protocol stopped manually", .{});
    print("\n", .{});
    print("{s}{s}Interrupted.{s} {s}State files reset to stopped.{s}\n", .{
        secondary, BOLD, NC, DIM, NC });
    restoreTerminal();
    std.process.exit(code);
}

fn onUnexpectedDeath(rc: i64) void {
    if (!state_ready) return;
    if (state_finalized) return;
    state_finalized = true;
    stopAlert();
    resetStateFiles();
    logEvent("Protocol ended unexpectedly (exit {d})", .{rc});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
fn finalizeSession() void {
    session_text = "session complete";
    remaining_str = "00:00:00";
    pct = 100;
    next_text = "";
    syncState();
    state_finalized = true;
    logEvent("Protocol complete - total points: {d}", .{points});
}

fn finalBanner() void {
    const banner_width = 60;
    const title = "ALL SESSIONS COMPLETE";
    const inner = banner_width - 2;
    const pad = @divTrunc(inner - @as(i64, @intCast(title.len)), 2);
    const border = "#" ** banner_width;
    print("\n", .{});
    print("{s}{s}{s}\n", .{ primary, border, NC });
    print("{s}#{s}", .{ primary, NC });
    var i: i64 = 0;
    while (i < pad) : (i += 1) print(" ", .{});
    print("{s}{s}", .{ BOLD, title });
    var j: i64 = 0;
    while (j < inner - pad - @as(i64, @intCast(title.len))) : (j += 1) print(" ", .{});
    print("{s}#{s}\n", .{ NC, primary });
    print("{s}{s}{s}\n", .{ primary, border, NC });
    print("\n", .{});
    print("  {s}Total Rounds:{s}  {s}{d}{s}\n", .{ BOLD, NC, primary, rounds, NC });
    print("  {s}Total Points:{s} {s}{d}{s}\n", .{ BOLD, NC, primary, points, NC });
    print("\n", .{});
    print("{s}{s}Great work!{s} {s}Exiting.{s}\n", .{ primary, BOLD, NC, DIM, NC });
}

pub fn main() u8 {
    start_instant = std.time.timestamp();
    const argv = std.process.argsAlloc(alloc) catch return 1;

    // argv[0] = the invoked program (basename), like every compiled port.
    if (argv.len > 0) {
        const full: []const u8 = argv[0];
        prog = std.fs.path.basename(full);
        const parent = std.fs.path.dirname(full) orelse ".";
        const abs = std.fs.cwd().realpathAlloc(alloc, parent) catch parent;
        dir = abs;
    }

    home = envOr("HOME");
    alert_sound = if (home.len != 0)
        joinPath(home, "Videos/Alarm/n_alarm.mp3") else "";

    // Environment overrides (captured before the defaults are applied).
    env_alert_sound = envOr("ALERT_SOUND");
    env_sink_name = envOr("SINK_NAME");
    env_state_dir = envOr("STATE_DIR");
    env_max_log_bytes = envOr("MAX_LOG_BYTES");
    env_quotes = envOr("QUOTES");
    env_theme = envOr("THEME");

    for (DEFAULT_QUOTES) |q| quote_list.append(alloc, q) catch {};

    parseArgs(argv[1..]);

    if (findConfigFile()) |cfg| loadConfig(cfg);

    // Environment variables beat the config file.
    if (env_alert_sound.len != 0) alert_sound = env_alert_sound;
    if (env_sink_name.len != 0) sink_name = env_sink_name;
    if (env_state_dir.len != 0) state_dir = env_state_dir;
    if (env_max_log_bytes.len != 0) {
        if (parseInt(env_max_log_bytes)) |v| {
            if (v > 0) max_log_bytes = v;
        }
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
    state_ready = true;
    logEvent("Starting new study protocol: {s}, {s} study, {s} break", .{
        roundsLabel(rounds), durationLabel(study_min), durationLabel(break_min) });

    print("{s}Protocol:{s} {s}{s}{s}  {s}|{s}  {s}{s}{s} study  {s}|{s}  " ++
        "{s}{s}{s} break  {s}|{s}  {s}Theme: {s}{s}\n", .{
        secondary, NC, BOLD, roundsLabel(rounds), NC, DIM, NC,
        BOLD, durationLabel(study_min), NC, DIM, NC,
        BOLD, durationLabel(break_min), NC, DIM, NC,
        BOLD, theme_name, NC });
    if (config_loaded.len != 0) {
        print("{s}Config: {s}{s}\n", .{ DIM, config_loaded, NC });
    }
    print("\n", .{});

    var round_: i64 = 1;
    while (round_ <= rounds) : (round_ += 1) {
        runPhase("study", study_min, round_, rounds);
        if (round_ < rounds) {
            runPhase("break", break_min, round_, rounds);
        }
    }

    finalizeSession();
    finalBanner();
    restoreTerminal();
    return 0;
}
