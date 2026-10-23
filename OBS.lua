#!/usr/bin/env luajit
--
-- OBS.lua - Study/break timer protocol (Lua port of OBS.sh, LuaJIT)
--
-- Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
-- progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
-- use as Text sources in OBS Studio. OBS.sh is the reference implementation;
-- see docs/port-spec.md for the behavior contract and README.md for usage.
--
-- Requirements: LuaJIT 2.0+ (the FFI is used for termios, poll, signals,
-- fork/exec and strftime), bash (to load the bash-syntax config file).
--
-- Usage:   luajit OBS.lua [options] <rounds> <study_minutes> <break_minutes>
-- Example: luajit OBS.lua 5 50 10            ->  5 rounds, 50 min study, 10 min break
--          luajit OBS.lua --dry-run 3 5 2    ->  3 rounds, 5 s study, 5 s break
-- Stop:    Ctrl+C, or press 'q' while a phase is running
-- Theme:   press Alt+T while a phase is running (see --list-themes)
--
local ffi = require("ffi")
local bbit = require("bit")
local band, rshift, bor, bnot = bbit.band, bbit.rshift, bbit.bor, bbit.bnot

-- ---------------------------------------------------------------------------
-- POSIX surface via FFI (glibc on Linux)
-- ---------------------------------------------------------------------------
ffi.cdef[[
typedef long time_t;
typedef long suseconds_t;
typedef int pid_t;
typedef unsigned long size_t;
typedef long ssize_t;

struct tm {
  int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year;
  int tm_wday, tm_yday, tm_isdst;
  long tm_gmtoff;
  const char *tm_zone;
};
struct timespec { time_t tv_sec; long tv_nsec; };
struct pollfd { int fd; short events; short revents; };

time_t time(time_t *t);
struct tm *localtime_r(const time_t *timep, struct tm *result);
size_t strftime(char *s, size_t max, const char *format, const struct tm *tm);

int isatty(int fd);
int pipe(int pipefd[2]);
int dup2(int oldfd, int newfd);
int open(const char *pathname, int flags, ...);
int close(int fd);
ssize_t read(int fd, void *buf, size_t count);
pid_t fork(void);
int execvp(const char *file, char *const argv[]);
pid_t waitpid(pid_t pid, int *status, int options);
int setenv(const char *name, const char *value, int overwrite);
int kill(pid_t pid, int sig);
int poll(struct pollfd *fds, unsigned int nfds, int timeout);
int nanosleep(const struct timespec *req, struct timespec *rem);
int clock_gettime(int clk_id, struct timespec *tp);
char *getcwd(char *buf, size_t size);
void _exit(int status);
int mkdir(const char *pathname, unsigned int mode);
int access(const char *pathname, int mode);
int *__errno_location(void);

typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
struct termios {
  tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
  cc_t c_line;
  cc_t c_cc[32];
  tcflag_t c_ispeed, c_ospeed;
};
int tcgetattr(int fd, struct termios *termios_p);
int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);

struct stat {
  unsigned long st_dev, st_ino, st_nlink;
  unsigned int st_mode, st_uid, st_gid, __pad0;
  unsigned long st_rdev;
  long __pad1, st_size;
  int st_blksize, __pad2;
  long st_blocks;
  long st_atim[2], st_mtim[2], st_ctim[2];
  int __unused[2];
};
int stat(const char *pathname, struct stat *statbuf);

typedef void (*sighandler_t)(int);
struct sigaction {
  sighandler_t sa_handler;
  char sa_mask[128];
  int sa_flags;
  void (*sa_restorer)(void);
};
int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact);
]]

local C = ffi.C
local function errno() return C.__errno_location()[0] end

local EINTR, EEXIST = 4, 17
local POLLIN = 0x001
local O_RDWR = 2
local S_IFMT, S_IFREG, S_IFDIR = 0xF000, 0x8000, 0x4000
local SIG_INT, SIG_HUP, SIG_TERM = 2, 1, 15
local VMIN, VTIME = 6, 5
local ISIG, ICANON, ECHO = 1, 2, 8
local TCSADRAIN, TCSAFLUSH = 1, 2

local START_TIME = tonumber(C.time(nil))

-- ---------------------------------------------------------------------------
-- Signals: the FFI callback only stores the exit code into a cdata int (a
-- plain machine store, safe in signal context). The interrupted poll loop
-- sees the flag and performs the cleanup, like the Perl port defers the exit
-- to the interrupted wait.
-- ---------------------------------------------------------------------------
local SIG_FLAG = ffi.new("int[1]", 0)
local SIG_TO_CODE = { [2] = 130, [15] = 143, [1] = 129 }

local function on_signal(sig)
  SIG_FLAG[0] = SIG_TO_CODE[sig] or (128 + sig)
end

local SIG_CB = nil  -- keeps the FFI callback alive for the whole process

local function install_signal_handlers()
  local sa = ffi.new("struct sigaction")
  ffi.fill(sa, ffi.sizeof(sa), 0)
  SIG_CB = ffi.cast("sighandler_t", on_signal)
  sa.sa_handler = SIG_CB
  sa.sa_flags = 0                 -- no SA_RESTART: poll() must wake up
  for _, sig in ipairs({ SIG_INT, SIG_TERM, SIG_HUP }) do
    C.sigaction(sig, sa, nil)
  end
end

-- Exit code requested by a signal, or nil.
local function pending_signal_code()
  local code = SIG_FLAG[0]
  return code ~= 0 and code or nil
end

-- ---------------------------------------------------------------------------
-- Small utilities
-- ---------------------------------------------------------------------------
local function now_seconds()
  return tonumber(C.time(nil)) - START_TIME
end

local function now_ms()
  local ts = ffi.new("struct timespec[1]")
  C.clock_gettime(1, ts)  -- CLOCK_MONOTONIC
  return tonumber(ts[0].tv_sec) * 1000 + math.floor(tonumber(ts[0].tv_nsec) / 1000000)
end

-- Sleep for `ms` milliseconds; wakes up on signals.
local function sleep_ms(ms)
  local req = ffi.new("struct timespec[1]")
  local deadline = now_ms() + ms
  while true do
    local left = deadline - now_ms()
    if left <= 0 then return end
    req[0].tv_sec = math.floor(left / 1000)
    req[0].tv_nsec = (left % 1000) * 1000000
    if C.nanosleep(req, nil) == 0 then return end
    if errno() == EINTR then
      local code = pending_signal_code()
      if code then cleanup_signal(code) end
    else
      return
    end
  end
end

-- Wait until fd is readable. Returns true (readable) or false (timeout).
local function poll_readable(fd, ms)
  local pfd = ffi.new("struct pollfd[1]")
  pfd[0].fd = fd
  pfd[0].events = POLLIN
  local deadline = now_ms() + ms
  while true do
    local left = deadline - now_ms()
    if left < 0 then left = 0 end
    local rc = C.poll(pfd, 1, left)
    if rc > 0 then return pfd[0].revents ~= 0 end
    if rc == 0 then return false end
    if errno() == EINTR then
      local code = pending_signal_code()
      if code then cleanup_signal(code) end
    else
      return false
    end
  end
end

local function cstrs(strs)
  -- Build a NULL-terminated char* array; keep the cdata alive so the
  -- underlying Lua strings cannot be collected before exec().
  local keep = {}
  local arr = ffi.new("char*[?]", #strs + 1)
  for i, s in ipairs(strs) do
    local ca = ffi.cast("char*", s)
    keep[i] = ca
    arr[i - 1] = ca
  end
  arr[#strs] = nil
  return arr, keep
end

-- Fork + exec without any redirection; returns the pid (0 = child branch).
local function raw_spawn(argv, env_extra)
  local pid = C.fork()
  if pid == 0 then
    if env_extra then
      for k, v in pairs(env_extra) do C.setenv(k, v, 1) end
    end
    local arr, _keep = cstrs(argv)
    C.execvp(argv[1], arr)
    C._exit(127)
  end
  return tonumber(pid)
end

-- Run a command and capture one of its streams. Returns text, exit code.
local function capture(argv, which_fd)
  local fds = ffi.new("int[2]")
  if C.pipe(fds) ~= 0 then return "", -1 end
  local pid = C.fork()
  if pid == 0 then
    C.dup2(fds[1], which_fd)
    C.close(fds[0])
    C.close(fds[1])
    local devnull = C.open("/dev/null", O_RDWR)
    if devnull >= 0 then
      if which_fd ~= 1 then C.dup2(devnull, 1) end
      if which_fd ~= 2 then C.dup2(devnull, 2) end
    end
    local arr, _keep = cstrs(argv)
    C.execvp(argv[1], arr)
    C._exit(127)
  end
  C.close(fds[1])
  local chunks = {}
  local buf = ffi.new("char[4096]")
  while true do
    local n = C.read(fds[0], buf, 4096)
    if n <= 0 then break end
    chunks[#chunks + 1] = ffi.string(buf, n)
  end
  C.close(fds[0])
  local status = ffi.new("int[1]")
  C.waitpid(pid, status, 0)
  local st = status[0]
  local code
  if band(st, 0x7f) == 0 then code = rshift(st, 8) else code = 128 + band(st, 0x7f) end
  return table.concat(chunks), code
end

local function wait_pid(pid)
  local status = ffi.new("int[1]")
  C.waitpid(pid, status, 0)
  local st = status[0]
  if band(st, 0x7f) == 0 then return rshift(st, 8) end
  return 128 + band(st, 0x7f)
end

-- command -v: search PATH for an executable file.
local function which(name)
  local path = os.getenv("PATH") or ""
  if path == "" then return nil end
  for dir in path:gmatch("[^:]+") do
    if dir:sub(-1) == "/" then dir = dir:sub(1, -2) end
    if dir ~= "" and C.access(dir .. "/" .. name, 1) == 0 then
      return dir .. "/" .. name
    end
  end
  return nil
end

local function file_exists(path)
  local st = ffi.new("struct stat[1]")
  return C.stat(path, st) == 0
end

local function is_regular_file(path)
  local st = ffi.new("struct stat[1]")
  if C.stat(path, st) ~= 0 then return false end
  return band(st[0].st_mode, S_IFMT) == S_IFREG
end

local function is_dir(path)
  local st = ffi.new("struct stat[1]")
  if C.stat(path, st) ~= 0 then return false end
  return band(st[0].st_mode, S_IFMT) == S_IFDIR
end

-- mkdir -p
local function mkdirs(path)
  if path:sub(-1) == "/" and #path > 1 then path = path:sub(1, -2) end
  if path == "" or path == "/" then return true end
  local cur = (path:sub(1, 1) == "/") and "/" or ""
  for seg in path:gmatch("[^/]+") do
    cur = (cur == "" or cur == "/") and (cur .. seg) or (cur .. "/" .. seg)
    if C.mkdir(cur, 493) ~= 0 then -- 0755
      if errno() ~= EEXIST or not is_dir(cur) then return false end
    end
  end
  return true
end

local function file_size(path)
  local st = ffi.new("struct stat[1]")
  if C.stat(path, st) ~= 0 then return nil end
  return tonumber(st[0].st_size)
end

-- localtime_str(fmt): format the current local time with strftime.
local function localtime_str(fmt)
  local t = ffi.new("time_t[1]")
  t[0] = C.time(nil)
  local tm = ffi.new("struct tm[1]")
  C.localtime_r(t, tm)
  local buf = ffi.new("char[256]")
  local n = C.strftime(buf, 256, fmt, tm)
  if n == 0 then return "" end
  return ffi.string(buf, n)
end

-- ---------------------------------------------------------------------------
-- Color themes: (name, primary, secondary)
-- ---------------------------------------------------------------------------
local THEME_NAMES = { "Purple", "Ocean", "Forest", "Sunset", "Rose", "Gold",
                      "Mono", "Ice", "Ember", "Neon", "Cobalt", "Cherry" }
local THEME_PRIMARY = { "\27[1;35m", "\27[1;36m", "\27[1;32m", "\27[1;33m",
                        "\27[1;95m", "\27[1;93m", "\27[1;37m", "\27[1;96m",
                        "\27[1;91m", "\27[1;92m", "\27[1;34m", "\27[1;91m" }
local THEME_SECONDARY = { "\27[0;35m", "\27[0;34m", "\27[0;32m", "\27[0;31m",
                          "\27[0;31m", "\27[0;33m", "\27[0;37m", "\27[0;36m",
                          "\27[0;31m", "\27[0;96m", "\27[0;36m", "\27[0;35m" }

local PRIMARY = THEME_PRIMARY[1]
local SECONDARY = THEME_SECONDARY[1]
local THEME_NAME = THEME_NAMES[1]
local THEME_INDEX = 0
local THEME_NOTICE_UNTIL = 0

local BOLD = "\27[1m"
local DIM = "\27[2m"
local NC = "\27[0m"

local LOGO = [[ /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/]]

local DEFAULT_QUOTE_LIST = {
  "Focused effort beats scattered hours",
  "Every round finished is progress made",
  "Consistency beats intensity",
  "Start now, figure out the rest along the way",
  "A short break now means sharper focus next round",
}

-- ---------------------------------------------------------------------------
-- Theme handling
-- ---------------------------------------------------------------------------
local log_event           -- forward declaration (defined with the state files)

local THEME_FILE = nil   -- set in setup_paths

local function set_theme(i)
  if i < 1 or i > #THEME_NAMES then return false end
  THEME_INDEX = i - 1
  THEME_NAME = THEME_NAMES[i]
  PRIMARY = THEME_PRIMARY[i]
  SECONDARY = THEME_SECONDARY[i]
  return true
end

local function theme_index(name)
  if not name or name == "" then return nil end
  local want = name:lower()
  for i, t in ipairs(THEME_NAMES) do
    if t:lower() == want then return i end
  end
  return nil
end

local function save_theme()
  if THEME_FILE then
    local fh = io.open(THEME_FILE, "w")
    if fh then fh:write(THEME_NAME .. "\n"); fh:close() end
  end
end

local function cycle_theme()
  -- THEME_INDEX is 0-based, set_theme takes a 1-based index.
  set_theme((THEME_INDEX + 1) % #THEME_NAMES + 1)
  save_theme()
  THEME_NOTICE_UNTIL = now_seconds() + 3
  log_event("Theme changed to: " .. THEME_NAME)
end

local function list_themes()
  for i = 1, #THEME_NAMES do
    io.write(string.format("  %-8s %s%s%s\n", THEME_NAMES[i],
      THEME_PRIMARY[i], "████", THEME_SECONDARY[i]))
  end
end

-- ---------------------------------------------------------------------------
-- Environment overrides (captured before the defaults are applied)
-- ---------------------------------------------------------------------------
local ENV_ALERT_SOUND = os.getenv("ALERT_SOUND") or ""
local ENV_SINK_NAME = os.getenv("SINK_NAME") or ""
local ENV_STATE_DIR = os.getenv("STATE_DIR") or ""
local ENV_MAX_LOG_BYTES = os.getenv("MAX_LOG_BYTES") or ""
local ENV_QUOTES = os.getenv("QUOTES") or ""
local ENV_THEME = os.getenv("THEME") or ""

-- ---------------------------------------------------------------------------
-- Built-in defaults
-- ---------------------------------------------------------------------------
local HOME = os.getenv("HOME") or ""
local ALERT_SOUND = (HOME ~= "") and (HOME .. "/Videos/Alarm/n_alarm.mp3") or ""
local SINK_NAME = "OBS_Alert_Sink"
local STATE_DIR = ""                 -- empty -> the directory of this script
local MAX_LOG_BYTES = 1048576        -- rotate log.txt once it grows past this
local ALERT_PID = 0
local FILE_BAR_WIDTH = 20            -- width of the bar in progress.txt
local NON_TTY_ENTER_TIMEOUT = 300    -- bounded wait for Enter on a pipe

-- Resolve the script directory to an absolute path (the reference uses
-- $(cd "$(dirname ...)" && pwd)); it is the default STATE_DIR and the
-- obs-panel.conf lookup location.
local function script_dir()
  local d = (arg and arg[0] or "?")
  local prefix = d:match("^(.*)/[^/]*$")
  if not prefix or prefix == "" then prefix = "." end
  -- resolve to absolute (like the reference's $(cd ... && pwd))
  if prefix:sub(1, 1) ~= "/" then
    local buf = ffi.new("char[4096]")
    local cwd = C.getcwd(buf, 4096)
    prefix = (cwd ~= nil) and (ffi.string(buf) .. "/" .. prefix) or prefix
  end
  -- lexically normalize
  local parts = {}
  for seg in prefix:gmatch("[^/]+") do
    if seg == ".." then parts[#parts] = nil
    elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  return "/" .. table.concat(parts, "/")
end
DIR = script_dir()

local QUOTE_LIST = {}
for _, q in ipairs(DEFAULT_QUOTE_LIST) do QUOTE_LIST[#QUOTE_LIST + 1] = q end

local POINTS = 0
local LAST_DATE = ""

-- ---------------------------------------------------------------------------
-- Argument parsing & validation
-- ---------------------------------------------------------------------------
local PROG = (arg and arg[0] or "OBS.lua"):match("[^/]*$")

local CONFIG_FILE = ""
local DRY_RUN = false
local USE_ALERT = true
local USE_SINK = true
local ROUNDS, STUDY_MIN, BREAK_MIN = 0, 0, 0
local CLI_THEME = ""
local DURATION_UNIT = "minutes"
local SECONDS_PER_UNIT = 60
local CONFIG_THEME = ""
local CONFIG_QUOTES = ""
local CONFIG_LOADED = ""

local function help_text()
  return ([[Usage: %s [options] <rounds> <study_minutes> <break_minutes>

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
]]):format(PROG, PROG, PROG, PROG)
end

local function print_help(code, stream)
  (stream or io.stdout):write(help_text())
  ;(stream or io.stdout):flush()
  os.exit(code)
end

local function usage_error()
  print_help(1, io.stderr)
end

local function out(msg) io.stdout:write(msg .. "\n") end
local function err(msg) io.stderr:write(msg .. "\n") end

local function usage_if_bad_number(val)
  -- ^[1-9][0-9]{0,3}$: 1-4 digits, first 1-9, no leading zero.
  if #val >= 1 and #val <= 4 and val:find("^[1-9]%d*$") then return end
  usage_error()
end

local function parse_args(argv)
  local args = {}
  for _, a in ipairs(argv) do args[#args + 1] = a end
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-h" or a == "--help" then
      print_help(0, io.stdout)
    elseif a == "-c" or a == "--config" then
      if i >= #args then
        err("Error: " .. a .. " needs a file argument")
        usage_error()
      end
      CONFIG_FILE = args[i + 1]
      i = i + 2
    elseif a == "-d" or a == "--dry-run" then
      DRY_RUN = true
      i = i + 1
    elseif a == "-n" or a == "--no-alert" then
      USE_ALERT = false
      i = i + 1
    elseif a == "-s" or a == "--no-sink" then
      USE_SINK = false
      i = i + 1
    elseif a == "-t" or a == "--theme" then
      if i >= #args then
        err("Error: " .. a .. " needs a theme name")
        usage_error()
      end
      CLI_THEME = args[i + 1]
      i = i + 2
    elseif a == "--list-themes" then
      list_themes()
      io.stdout:flush()
      os.exit(0)
    elseif a == "--" then
      for j = i + 1, #args do positional[#positional + 1] = args[j] end
      break
    elseif a:sub(1, 1) == "-" then
      err("Error: unknown option: " .. a)
      usage_error()
    else
      -- First non-option: everything that remains is positional.
      for j = i, #args do positional[#positional + 1] = args[j] end
      break
    end
  end

  if #positional ~= 3 then usage_error() end
  usage_if_bad_number(positional[1])
  usage_if_bad_number(positional[2])
  usage_if_bad_number(positional[3])
  ROUNDS = tonumber(positional[1])
  STUDY_MIN = tonumber(positional[2])
  BREAK_MIN = tonumber(positional[3])
  if ROUNDS > 50 then
    err("Error: rounds must be <= 50")
    usage_error()
  end
  if STUDY_MIN > 600 then
    err("Error: study minutes must be <= 600")
    usage_error()
  end
  if BREAK_MIN > 120 then
    err("Error: break minutes must be <= 120")
    usage_error()
  end

  if DRY_RUN then
    DURATION_UNIT = "seconds"
    SECONDS_PER_UNIT = 1
  end
end

-- ---------------------------------------------------------------------------
-- Configuration file (bash syntax, loaded by a child bash)
-- ---------------------------------------------------------------------------
local CONFIG_DUMP_SH = [[
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
]]

local function find_config_file()
  if CONFIG_FILE ~= "" then return CONFIG_FILE end
  local env_cfg = os.getenv("OBS_PANEL_CONFIG")
  if env_cfg and env_cfg ~= "" then return env_cfg end
  local xdg = os.getenv("XDG_CONFIG_HOME") or ((HOME ~= "") and (HOME .. "/.config") or "/.config")
  local xdg_cfg = xdg .. "/obs-study-panel/config"
  if file_exists(xdg_cfg) then return xdg_cfg end
  local local_cfg = DIR .. "/obs-panel.conf"
  if file_exists(local_cfg) then return local_cfg end
  return nil
end

local function quotes_to_list(raw)
  local list = {}
  for line in raw:gmatch("([^\n]*)\n?") do
    line = line:gsub("\r$", "")
    if line ~= "" then list[#list + 1] = line end
  end
  -- gmatch with trailing pattern leaves an empty final match out; handle a
  -- string without trailing newline too (the last line is still yielded).
  return list
end

local function parse_int(value, default)
  if type(value) ~= "string" and type(value) ~= "number" then return default end
  local s = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
  if s:find("^[+-]?%d+$") then return tonumber(s) end
  return default
end

local function load_config(path)
  if C.access(path, 4) ~= 0 then
    err("Error: config file is not readable: " .. path)
    os.exit(1)
  end
  if not which("bash") then
    err("Error: bash is required to read the config file: " .. path)
    os.exit(1)
  end
  -- Syntax gate: bash -n, first 3 lines of its stderr.
  local bash_err, rc = capture({ "bash", "-n", path }, 2)
  if rc ~= 0 then
    err("Error: syntax error in config file: " .. path)
    local printed = 0
    for line in bash_err:gmatch("[^\n]+") do
      if line ~= "" and printed < 3 then err(line); printed = printed + 1 end
    end
    os.exit(1)
  end

  -- Seed the pre-config defaults, exactly what the reference holds while it
  -- sources the file (the real environment's THEME/QUOTES pass through).
  local dump_path = os.tmpname()
  os.remove(dump_path)  -- the child's `> "$2"` creates it
  local env_extra = {
    ALERT_SOUND = ALERT_SOUND,
    SINK_NAME = SINK_NAME,
    STATE_DIR = "",
    MAX_LOG_BYTES = "1048576",
    FILE_BAR_WIDTH = "20",
    NON_TTY_ENTER_TIMEOUT = "300",
    POINTS = tostring(POINTS),
    LAST_DATE = LAST_DATE,
    QUOTES_SEED = table.concat(QUOTE_LIST, "\31"),
  }
  local pid = raw_spawn({ "bash", "-c", CONFIG_DUMP_SH, "obs-panel", path, dump_path }, env_extra)
  local child_rc = 0
  if pid > 0 then
    child_rc = wait_pid(pid)
  else
    os.remove(dump_path)
    err("Error: cannot run bash for the config file: " .. path)
    os.exit(1)
  end

  local fh = io.open(dump_path, "rb")
  local raw = fh and fh:read("*a") or nil
  if fh then fh:close() end
  os.remove(dump_path)

  if not raw or raw == "" then
    -- The config called exit N before the dump was written.
    os.exit(child_rc ~= 0 and child_rc or 1)
  end

  local values = {}
  local quotes = {}
  local start = 1
  while true do
    local s, e = raw:find("\30", start, true)
    local rec = (s and raw:sub(start, s - 1)) or raw:sub(start)
    if rec ~= "" then
      local mid = rec:find("\31", 1, true)
      if mid then
        local key = rec:sub(1, mid - 1)
        local value = rec:sub(mid + 1)
        if key == "QUOTE" then quotes[#quotes + 1] = value
        else values[key] = value end
      end
    end
    if not s then break end
    start = e + 1
  end

  ALERT_SOUND = values.ALERT_SOUND or ALERT_SOUND
  SINK_NAME = values.SINK_NAME or SINK_NAME
  STATE_DIR = values.STATE_DIR or ""
  MAX_LOG_BYTES = values.MAX_LOG_BYTES or "1048576"
  FILE_BAR_WIDTH = values.FILE_BAR_WIDTH or "20"
  NON_TTY_ENTER_TIMEOUT = values.NON_TTY_ENTER_TIMEOUT or "300"
  CONFIG_THEME = values.THEME or ""
  POINTS = parse_int(values.POINTS, 0)
  LAST_DATE = values.LAST_DATE or ""
  CONFIG_QUOTES = values.QUOTES or ""
  -- Zero QUOTE records means the config emptied the list.
  QUOTE_LIST = quotes
  CONFIG_LOADED = path
end

local function apply_quote_sources()
  if ENV_QUOTES ~= "" then
    QUOTE_LIST = quotes_to_list(ENV_QUOTES)
  elseif CONFIG_QUOTES ~= "" then
    QUOTE_LIST = quotes_to_list(CONFIG_QUOTES)
  end
end

local function sanity_knobs()
  local v = tostring(MAX_LOG_BYTES)
  if v:find("^%s*%d+%s*$") and tonumber(v) > 0 then
    MAX_LOG_BYTES = tonumber(v)
  else
    MAX_LOG_BYTES = 1048576
  end
  v = tostring(FILE_BAR_WIDTH)
  if v:find("^%s*%d+%s*$") and tonumber(v) > 0 and tonumber(v) <= 200 then
    FILE_BAR_WIDTH = tonumber(v)
  else
    FILE_BAR_WIDTH = 20
  end
  v = tostring(NON_TTY_ENTER_TIMEOUT)
  if v:find("^%s*%d+%s*$") and tonumber(v) > 0 and tonumber(v) <= 3600 then
    NON_TTY_ENTER_TIMEOUT = tonumber(v)
  else
    NON_TTY_ENTER_TIMEOUT = 300
  end
end

-- ---------------------------------------------------------------------------
-- Paths and runtime state
-- ---------------------------------------------------------------------------
local DATE_FILE, DAY_FILE, SESSION_FILE, TIMER_FILE, LOG_FILE
local PROGRESS_FILE, POINTS_FILE, MESSAGE_FILE, NEXT_FILE
local OVERLAY_FILE

local SESSION_TEXT = ""
local REMAINING_STR = "00:00:00"
local PCT = 0
local NEXT_TEXT = ""
local MESSAGE_TEXT = ""
local LAST_DAY = ""
local STATE_READY = false
local STATE_FINALIZED = false
local IN_CLEANUP = false

local function setup_paths()
  if STATE_DIR == "" then STATE_DIR = DIR end
  if not mkdirs(STATE_DIR) then
    err("Error: cannot create state dir: " .. STATE_DIR)
    os.exit(1)
  end
  local function p(name) return STATE_DIR .. "/" .. name end
  DATE_FILE = p("date.txt")
  DAY_FILE = p("day.txt")
  SESSION_FILE = p("session.txt")
  TIMER_FILE = p("timer.txt")
  LOG_FILE = p("log.txt")
  PROGRESS_FILE = p("progress.txt")
  POINTS_FILE = p("points.txt")
  MESSAGE_FILE = p("message.txt")
  NEXT_FILE = p("next.txt")
  OVERLAY_FILE = p("overlay.txt")
  THEME_FILE = p("theme.txt")
end

local function select_theme()
  local request = CLI_THEME
  if request == "" and ENV_THEME ~= "" then request = ENV_THEME end
  if request == "" and CONFIG_THEME ~= "" then request = CONFIG_THEME end
  if request == "" and THEME_FILE and is_regular_file(THEME_FILE) then
    local fh = io.open(THEME_FILE, "r")
    if fh then
      local line = fh:read("*l")
      fh:close()
      if line then request = line:gsub("\n$", "") end
    end
  end
  if request ~= "" then
    local idx = theme_index(request)
    if not idx then
      err("Warning: unknown theme '" .. request .. "', using " .. THEME_NAME)
    else
      set_theme(idx)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Startup logo
-- ---------------------------------------------------------------------------
local function print_logo()
  out(PRIMARY)
  out(LOGO)
  out(NC)
  out(PRIMARY .. BOLD .. "     Study / Break Timer Protocol" .. NC)
  out(DIM .. "── live state written to date · day · session · timer · log" .. NC)
  out("")
end

-- ---------------------------------------------------------------------------
-- OBS state files
-- ---------------------------------------------------------------------------
local function write_file(path, text)
  local fh = io.open(path, "w")
  if fh then fh:write(text .. "\n"); fh:close() end
end

local function update_date_day()
  local d = localtime_str("%Y-%m-%d")
  if d == LAST_DATE then return end
  LAST_DATE = d
  LAST_DAY = localtime_str("%A")
  write_file(DATE_FILE, d)
  write_file(DAY_FILE, LAST_DAY)
end

local function sync_state()
  update_date_day()
  publish_state()
end

local function make_bar(filled, width, fill, empty, head)
  local chars = {}
  for i = 0, width - 1 do
    if i < filled then
      if head and head ~= "" and i == filled - 1 then
        chars[#chars + 1] = head
      else
        chars[#chars + 1] = fill
      end
    else
      chars[#chars + 1] = empty
    end
  end
  return table.concat(chars)
end

local function file_bar()
  return make_bar(math.floor(PCT * FILE_BAR_WIDTH / 100), FILE_BAR_WIDTH, "#", "-")
end

publish_state = function()
  local bar = file_bar()
  write_file(SESSION_FILE, SESSION_TEXT)
  write_file(TIMER_FILE, REMAINING_STR)
  write_file(POINTS_FILE, tostring(POINTS))
  write_file(NEXT_FILE, NEXT_TEXT)
  write_file(MESSAGE_FILE, MESSAGE_TEXT)
  local pct_str = string.format("[%s] %3d%%", bar, PCT)
  write_file(PROGRESS_FILE, pct_str)
  local overlay = {
    LAST_DATE .. "  " .. LAST_DAY,
    SESSION_TEXT,
    REMAINING_STR,
    pct_str,
    "Pts: " .. POINTS,
    "Next: " .. NEXT_TEXT,
  }
  if MESSAGE_TEXT ~= "" then overlay[#overlay + 1] = MESSAGE_TEXT end
  local fh = io.open(OVERLAY_FILE, "w")
  if fh then
    fh:write(table.concat(overlay, "\n") .. "\n")
    fh:close()
  end
end

local function rotate_log_if_needed()
  local size = file_size(LOG_FILE)
  if not size then return end
  if size < MAX_LOG_BYTES then return end
  os.remove(LOG_FILE .. ".1")
  if not os.rename(LOG_FILE, LOG_FILE .. ".1") then return end
  local fh = io.open(LOG_FILE, "w")
  if fh then fh:close() end
end

log_event = function(msg)
  rotate_log_if_needed()
  local fh = io.open(LOG_FILE, "a")
  if fh then
    fh:write(string.format("[%s] %s\n", localtime_str("%Y-%m-%d %H:%M:%S"), msg))
    fh:close()
  end
end

-- ---------------------------------------------------------------------------
-- Audio alerts
-- ---------------------------------------------------------------------------
local function sink_is_ready()
  if not which("pactl") then return false end
  local text, rc = capture({ "pactl", "list", "short", "sinks" }, 1)
  if rc ~= 0 then return false end
  for line in text:gmatch("[^\n]+") do
    local fields = {}
    for tok in line:gmatch("%S+") do fields[#fields + 1] = tok end
    if fields[2] == SINK_NAME then return true end
  end
  return false
end

local function setup_audio_sink()
  if not USE_SINK then return end
  if not which("pactl") then return end
  if sink_is_ready() then return end
  local pid = raw_spawn({ "pactl", "load-module", "module-null-sink",
    "sink_name=" .. SINK_NAME,
    "sink_properties=device.description=" .. SINK_NAME })
  if pid > 0 then
    local status = ffi.new("int[1]")
    C.waitpid(pid, status, 0)
  end
end

local function stop_alert()
  if ALERT_PID > 0 then
    C.kill(ALERT_PID, SIG_TERM)
    local status = ffi.new("int[1]")
    C.waitpid(ALERT_PID, status, 1)  -- WNOHANG: best-effort reap
    ALERT_PID = 0
  end
end

local function play_alert()
  if not USE_ALERT then return end
  stop_alert()   -- never let two alarms overlap
  if ALERT_SOUND == "" or not is_regular_file(ALERT_SOUND) then
    out(DIM .. "(alert file not found: " .. (ALERT_SOUND ~= "" and ALERT_SOUND or "none") .. ")" .. NC)
    return
  end

  local player
  if which("mpv") then player = { "mpv", "--no-video", "--volume=70" }
  elseif which("paplay") then player = { "paplay" }
  elseif which("ffplay") then player = { "ffplay", "-nodisp", "-autoexit" }
  elseif which("cvlc") then player = { "cvlc", "--play-and-exit", "--no-video", "--volume=70" }
  else
    out(DIM .. "(no audio player found - install mpv / paplay / ffplay)" .. NC)
    return
  end

  if USE_SINK and not sink_is_ready() then
    setup_audio_sink()
  end

  local argv = {}
  for _, a in ipairs(player) do argv[#argv + 1] = a end
  argv[#argv + 1] = ALERT_SOUND
  if USE_SINK and sink_is_ready() then
    local pid = raw_spawn(argv, { PULSE_SINK = SINK_NAME })
    if pid > 0 then
      ALERT_PID = pid
      out(DIM .. "-> alert on OBS sink (" .. SINK_NAME .. ")" .. NC)
      return
    end
  end
  local pid = raw_spawn(argv)
  if pid > 0 then
    ALERT_PID = pid
    out(SECONDARY .. "-> alert on default device (OBS sink unavailable)" .. NC)
  end
end

-- ---------------------------------------------------------------------------
-- Keyboard input
-- ---------------------------------------------------------------------------
local STDIN_IS_TTY = false
local TERM_SAVED = nil
local KEY = ""
local KEY_READ = false

local function setup_terminal()
  STDIN_IS_TTY = C.isatty(0) == 1
  if STDIN_IS_TTY then
    local saved = ffi.new("struct termios[1]")
    if C.tcgetattr(0, saved) == 0 then
      TERM_SAVED = saved
      local mode = ffi.new("struct termios[1]")
      ffi.copy(mode, saved, ffi.sizeof(mode))
      -- cbreak like the reference's `read -s`: echo and canonical mode off,
      -- ISIG stays on so Ctrl+C still generates SIGINT.
      local clear = band(bnot(bor(ICANON, ECHO)), 0xFFFFFFFF)
      mode[0].c_lflag = band(mode[0].c_lflag, clear)
      mode[0].c_cc[VMIN] = 1
      mode[0].c_cc[VTIME] = 0
      C.tcsetattr(0, TCSAFLUSH, mode)
    end
  end
end

local function restore_terminal()
  if TERM_SAVED then
    C.tcsetattr(0, TCSADRAIN, TERM_SAVED)
    TERM_SAVED = nil
  end
end

-- One byte with a timeout. Returns "byte" (1-char string), nil (timeout)
-- or "" (EOF).
local function read_byte_timeout(timeout_ms)
  if not poll_readable(0, timeout_ms) then return nil end
  local buf = ffi.new("char[1]")
  local n = C.read(0, buf, 1)
  if n <= 0 then return "" end
  return ffi.string(buf, 1)
end

local function wait_key(timeout_s)
  KEY = ""
  KEY_READ = false
  if not STDIN_IS_TTY then
    sleep_ms(math.floor(timeout_s * 1000))
    return
  end
  local b = read_byte_timeout(math.floor(timeout_s * 1000))
  if not b or b == "" then return end
  KEY_READ = true
  if b == "\27" then
    KEY = ""
    local nxt = read_byte_timeout(300)
    if nxt == "t" or nxt == "T" then KEY = "alt-t" end
  else
    KEY = b
  end
end

local function discard_pending_input()
  if not STDIN_IS_TTY then return end
  while true do
    local b = read_byte_timeout(10)
    if not b or b == "" then return end
  end
end

local function wait_for_enter()
  if STDIN_IS_TTY then
    while true do
      local b = read_byte_timeout(1000)
      if b == nil then
        update_date_day()
      elseif b == "" or b == "\n" then
        return
      end
    end
  end
  -- Not a terminal: bounded wait, 5 s slices.
  local waited = 0
  while waited < NON_TTY_ENTER_TIMEOUT do
    local slice_end = now_ms() + 5000
    while true do
      local left = slice_end - now_ms()
      if left <= 0 then waited = waited + 5; break end
      if not poll_readable(0, left) then waited = waited + 5; break end
      local buf = ffi.new("char[4096]")
      local n = C.read(0, buf, 4096)
      if n <= 0 then return end   -- EOF
      if ffi.string(buf, n):find("\n", 1, true) then return end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Status / progress UI
-- ---------------------------------------------------------------------------
local TERM_BAR_WIDTH = 24
local BOX_INNER = 62

local function phase_color(label)
  if label == "STUDY" then return PRIMARY else return SECONDARY end
end

local function draw_status(label, round_, total_rounds, elapsed, total, paused)
  local filled = 0
  if total > 0 then filled = math.floor(elapsed * TERM_BAR_WIDTH / total) end
  if filled > TERM_BAR_WIDTH then filled = TERM_BAR_WIDTH end
  local bar = make_bar(filled, TERM_BAR_WIDTH, "=", " ", ">")
  local color = phase_color(label)
  local flag = ""
  if paused ~= 0 then flag = PRIMARY .. " PAUSED" .. NC end
  if now_seconds() < THEME_NOTICE_UNTIL then
    flag = flag .. "  " .. DIM .. "Theme: " .. THEME_NAME .. NC
  end
  io.stdout:write("\r\033[K")
  io.stdout:write(string.format(
    "%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
    BOLD, color, label, NC,
    round_, total_rounds,
    color, bar, NC,
    PCT, REMAINING_STR,
    PRIMARY, POINTS, NC, flag))
  io.stdout:flush()
end

local function box_row(color, plain, styled)
  local pad = BOX_INNER - #plain
  if pad < 0 then pad = 0 end
  out(color .. "║" .. styled .. string.rep(" ", pad) .. color .. "║" .. NC)
end

local function duration_label(n)
  if n == 1 then
    if DURATION_UNIT == "seconds" then return "1 second" end
    return "1 minute"
  end
  return n .. " " .. DURATION_UNIT
end

local function rounds_label(n)
  if n == 1 then return "1 round" end
  return n .. " rounds"
end

local function phase_header(label, round_, total, minutes, subtitle)
  subtitle = subtitle:sub(1, BOX_INNER - 4)
  local color = phase_color(label)
  local bar = string.rep("═", BOX_INNER)
  local info = label .. "  ·  Round " .. round_ .. " / " .. total
    .. "  ·  " .. duration_label(minutes)
  out("")
  out(color .. "╔" .. bar .. "╗" .. NC)
  box_row(color, "  " .. info,
    "  " .. BOLD .. label .. NC .. color .. "  ·  Round " .. round_ .. " / "
    .. total .. "  ·  " .. duration_label(minutes))
  box_row(color, "  " .. subtitle, "  " .. DIM .. subtitle .. NC .. color)
  if STDIN_IS_TTY then
    local keys = "  p pause  ·  s skip  ·  q quit  ·  Alt+T theme"
    box_row(color, keys, DIM .. keys .. NC .. color)
  end
  out(color .. "╚" .. bar .. "╝" .. NC)
  out("")
end

local function show_completion(phase, round_, total_rounds, next_phase, skipped)
  local width = 60
  local line = string.rep("=", width)
  local title
  if skipped == 1 then
    title = "PHASE SKIPPED"
  elseif phase == "STUDY" then
    title = "STUDY SESSION COMPLETE"
  else
    title = "BREAK COMPLETE"
  end
  local color = phase_color(phase)
  out("")
  out(color .. line .. NC)
  out(color .. string.rep(" ", math.floor((width + #title) / 2)) .. title .. NC)
  out(color .. line .. NC)
  out("")
  out("  Round:   " .. BOLD .. round_ .. NC .. " / " .. total_rounds)
  out("  Points:  " .. PRIMARY .. POINTS .. NC)
  out("")
  if next_phase == "None" then
    out("  Next:    " .. DIM .. "Session complete" .. NC)
  else
    out("  Next:    " .. BOLD .. next_phase .. NC)
  end
  out("")
  io.stdout:write("  " .. PRIMARY .. "Press Enter to continue..." .. NC)
  io.stdout:flush()
end

-- ---------------------------------------------------------------------------
-- Phase runner
-- ---------------------------------------------------------------------------
local PHASE_LABEL = ""
local PHASE_SUBTITLE = ""
local PHASE_NEXT = ""
local PHASE_TOTAL = 0
local PHASE_ELAPSED = 0
local PHASE_PAUSED = false
local PHASE_SKIPPED = false
local PHASE_START = 0
local PHASE_PAUSED_TOTAL = 0
local PHASE_PAUSE_AT = 0

local function fmt_hms(total)
  return string.format("%02d:%02d:%02d",
    math.floor(total / 3600), math.floor(total % 3600 / 60), total % 60)
end

local function phase_prepare(ptype, minutes, round_, total_rounds)
  if ptype == "study" then
    PHASE_LABEL = "STUDY"
    if #QUOTE_LIST > 0 then
      PHASE_SUBTITLE = QUOTE_LIST[math.random(#QUOTE_LIST)]
    else
      PHASE_SUBTITLE = "Stay focused."
    end
  else
    PHASE_LABEL = "BREAK"
    PHASE_SUBTITLE = "Relax and recharge."
  end

  if ptype == "study" then
    if round_ < total_rounds then
      PHASE_NEXT = "Break (" .. duration_label(BREAK_MIN) .. ")"
    else
      PHASE_NEXT = "None"
    end
  else
    PHASE_NEXT = "Study (" .. duration_label(STUDY_MIN) .. ")"
  end

  PHASE_TOTAL = minutes * SECONDS_PER_UNIT
  PHASE_ELAPSED = 0
  PHASE_PAUSED = false
  PHASE_SKIPPED = false
  PHASE_START = now_seconds()
  PHASE_PAUSED_TOTAL = 0
  PHASE_PAUSE_AT = 0

  SESSION_TEXT = PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds
  REMAINING_STR = fmt_hms(PHASE_TOTAL)
  PCT = 0
  NEXT_TEXT = PHASE_NEXT
  if NEXT_TEXT == "None" then NEXT_TEXT = "Session complete" end
  MESSAGE_TEXT = PHASE_SUBTITLE

  log_event("Start: " .. PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds
    .. " (" .. duration_label(minutes) .. ")")
  phase_header(PHASE_LABEL, round_, total_rounds, minutes, PHASE_SUBTITLE)
  sync_state()
end

local function phase_handle_key(round_, total_rounds)
  if KEY == "p" or KEY == "P" or KEY == " " then
    if PHASE_PAUSED then
      PHASE_PAUSED_TOTAL = PHASE_PAUSED_TOTAL + now_seconds() - PHASE_PAUSE_AT
      PHASE_PAUSED = false
      log_event("Resumed: " .. PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds)
    else
      PHASE_PAUSED = true
      PHASE_PAUSE_AT = now_seconds()
      log_event("Paused: " .. PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds)
    end
  elseif KEY == "s" or KEY == "S" then
    PHASE_SKIPPED = true
    log_event("Skipped: " .. PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds)
  elseif KEY == "q" or KEY == "Q" then
    log_event("Quit requested by user")
    cleanup(0)
  elseif KEY == "alt-t" then
    cycle_theme()
  end
end

local function phase_count(round_, total_rounds)
  while PHASE_ELAPSED < PHASE_TOTAL do
    local remaining = PHASE_TOTAL - PHASE_ELAPSED
    if remaining < 0 then remaining = 0 end
    REMAINING_STR = fmt_hms(remaining)
    PCT = 0
    if PHASE_TOTAL > 0 then PCT = math.floor(PHASE_ELAPSED * 100 / PHASE_TOTAL) end
    if PCT > 100 then PCT = 100 end
    SESSION_TEXT = PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds
    if PHASE_PAUSED then SESSION_TEXT = SESSION_TEXT .. " (PAUSED)" end

    sync_state()
    draw_status(PHASE_LABEL, round_, total_rounds, PHASE_ELAPSED, PHASE_TOTAL,
      PHASE_PAUSED and 1 or 0)

    wait_key(1)
    if KEY_READ then
      phase_handle_key(round_, total_rounds)
      if PHASE_SKIPPED then break end
    end
    -- CRASH-INJECT-POINT
    if not PHASE_PAUSED then
      PHASE_ELAPSED = now_seconds() - PHASE_START - PHASE_PAUSED_TOTAL
    end
  end
end

local function phase_finish(round_, total_rounds)
  if PHASE_SKIPPED then
    SESSION_TEXT = PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds .. " (SKIPPED)"
  else
    PCT = 100
    POINTS = POINTS + 1
  end
  REMAINING_STR = "00:00:00"
  sync_state()
  draw_status(PHASE_LABEL, round_, total_rounds, PHASE_ELAPSED, PHASE_TOTAL, 0)
  out("")
  log_event("End: " .. PHASE_LABEL .. " " .. round_ .. "/" .. total_rounds)

  play_alert()

  discard_pending_input()
  show_completion(PHASE_LABEL, round_, total_rounds, PHASE_NEXT,
    PHASE_SKIPPED and 1 or 0)
  wait_for_enter()
  stop_alert()
  out("")
end

local function run_phase(ptype, minutes, round_, total_rounds)
  phase_prepare(ptype, minutes, round_, total_rounds)
  phase_count(round_, total_rounds)
  phase_finish(round_, total_rounds)
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
local function reset_state_files()
  SESSION_TEXT = "stopped"
  REMAINING_STR = "00:00:00"
  PCT = 0
  NEXT_TEXT = ""
  sync_state()
end

function cleanup(code)
  if IN_CLEANUP then return end
  IN_CLEANUP = true
  STATE_FINALIZED = true
  stop_alert()
  pcall(reset_state_files)
  pcall(function() log_event("Protocol stopped manually") end)
  pcall(function()
    io.stdout:write("\n")
    io.stdout:write(SECONDARY .. BOLD .. "Interrupted." .. NC .. " "
      .. DIM .. "State files reset to stopped." .. NC .. "\n")
    io.stdout:flush()
  end)
  restore_terminal()
  os.exit(code)
end

-- Signal-initiated cleanup: called from the interrupted wait loops.
function cleanup_signal(code)
  cleanup(code)
end

local function on_unexpected_death(rc)
  if not STATE_READY then return end
  if STATE_FINALIZED then return end
  STATE_FINALIZED = true
  stop_alert()
  pcall(reset_state_files)
  pcall(function() log_event("Protocol ended unexpectedly (exit " .. rc .. ")") end)
end

-- A crash injected by the test suite: raises through pcall like an error.
function crash_exit(code)
  error({ crash = code }, 0)
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------
local function finalize_session()
  SESSION_TEXT = "session complete"
  REMAINING_STR = "00:00:00"
  PCT = 100
  NEXT_TEXT = ""
  sync_state()
  STATE_FINALIZED = true
  log_event("Protocol complete - total points: " .. POINTS)
end

local function final_banner()
  local banner_width = 60
  local title = "ALL SESSIONS COMPLETE"
  local inner = banner_width - 2
  local pad = math.floor((inner - #title) / 2)
  local border = string.rep("#", banner_width)
  out("")
  out(PRIMARY .. border .. NC)
  out(PRIMARY .. "#" .. NC .. string.rep(" ", pad) .. BOLD .. title
    .. string.rep(" ", inner - pad - #title) .. NC .. "#" .. PRIMARY)
  out(PRIMARY .. border .. NC)
  out("")
  out("  " .. BOLD .. "Total Rounds:" .. NC .. "  " .. PRIMARY .. ROUNDS .. NC)
  out("  " .. BOLD .. "Total Points:" .. NC .. " " .. PRIMARY .. POINTS .. NC)
  out("")
  out(PRIMARY .. BOLD .. "Great work!" .. NC .. " " .. DIM .. "Exiting." .. NC)
end

local function main()
  local argv = {}
  for i = 1, #arg do argv[i] = arg[i] end
  math.randomseed(os.time())
  parse_args(argv)

  local cfg = find_config_file()
  if cfg then load_config(cfg) end

  -- Environment variables beat the config file.
  if ENV_ALERT_SOUND ~= "" then ALERT_SOUND = ENV_ALERT_SOUND end
  if ENV_SINK_NAME ~= "" then SINK_NAME = ENV_SINK_NAME end
  if ENV_STATE_DIR ~= "" then STATE_DIR = ENV_STATE_DIR end
  if ENV_MAX_LOG_BYTES ~= "" then MAX_LOG_BYTES = ENV_MAX_LOG_BYTES end

  apply_quote_sources()
  sanity_knobs()

  setup_paths()
  select_theme()

  install_signal_handlers()

  io.stdout:setvbuf("no")
  io.stderr:setvbuf("no")

  setup_terminal()
  print_logo()
  setup_audio_sink()
  update_date_day()
  STATE_READY = true
  log_event("Starting new study protocol: " .. rounds_label(ROUNDS) .. ", "
    .. duration_label(STUDY_MIN) .. " study, "
    .. duration_label(BREAK_MIN) .. " break")

  out(SECONDARY .. "Protocol:" .. NC .. " " .. BOLD .. rounds_label(ROUNDS) .. NC
    .. "  " .. DIM .. "|" .. NC .. "  " .. BOLD .. duration_label(STUDY_MIN)
    .. NC .. " study  " .. DIM .. "|" .. NC .. "  " .. BOLD
    .. duration_label(BREAK_MIN) .. NC .. " break  " .. DIM .. "|" .. NC .. "  "
    .. BOLD .. "Theme: " .. THEME_NAME .. NC)
  if CONFIG_LOADED ~= "" then
    out(DIM .. "Config: " .. CONFIG_LOADED .. NC)
  end
  out("")

  for round_ = 1, ROUNDS do
    run_phase("study", STUDY_MIN, round_, ROUNDS)
    if round_ < ROUNDS then
      run_phase("break", BREAK_MIN, round_, ROUNDS)
    end
  end

  finalize_session()
  final_banner()
  restore_terminal()
  os.exit(0)
end

local ok, err_obj = pcall(main)
if not ok then
  -- An error object (crash) carries its exit code; anything else is a bug.
  if type(err_obj) == "table" and type(err_obj.crash) == "number" then
    on_unexpected_death(err_obj.crash)
    restore_terminal()
    os.exit(err_obj.crash)
  end
  on_unexpected_death(1)
  restore_terminal()
  io.stderr:write("OBS.lua: internal error: "
    .. tostring(err_obj and err_obj.message or err_obj) .. "\n")
  os.exit(1)
end
