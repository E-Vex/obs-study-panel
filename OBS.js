#!/usr/bin/env node
//
// OBS.js - Study/break timer protocol (JavaScript port of OBS.sh, Node.js)
//
// Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
// progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
// use as Text sources in OBS Studio. OBS.sh is the reference implementation;
// see docs/port-spec.md for the behavior contract and README.md for usage.
//
// Requirements: Node.js 16+, bash (to load the bash-syntax config file).
//
// Usage:   ./OBS.js [options] <rounds> <study_minutes> <break_minutes>
// Example: ./OBS.js 5 50 10            ->  5 rounds, 50 min study, 10 min break
//          ./OBS.js --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
// Stop:    Ctrl+C, or press 'q' while a phase is running
// Theme:   press Alt+T while a phase is running (see --list-themes)
//
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const PROG = path.basename(process.argv[1] || 'OBS.js');
const START_TIME = Math.floor(Date.now() / 1000);

// ---------------------------------------------------------------------------
// Color themes: (name, primary, secondary)
// ---------------------------------------------------------------------------
const THEME_NAMES = ['Purple', 'Ocean', 'Forest', 'Sunset', 'Rose', 'Gold',
  'Mono', 'Ice', 'Ember', 'Neon', 'Cobalt', 'Cherry'];
const THEME_PRIMARY = ['\x1b[1;35m', '\x1b[1;36m', '\x1b[1;32m', '\x1b[1;33m',
  '\x1b[1;95m', '\x1b[1;93m', '\x1b[1;37m', '\x1b[1;96m',
  '\x1b[1;91m', '\x1b[1;92m', '\x1b[1;34m', '\x1b[1;91m'];
const THEME_SECONDARY = ['\x1b[0;35m', '\x1b[0;34m', '\x1b[0;32m', '\x1b[0;31m',
  '\x1b[0;31m', '\x1b[0;33m', '\x1b[0;37m', '\x1b[0;36m',
  '\x1b[0;31m', '\x1b[0;96m', '\x1b[0;36m', '\x1b[0;35m'];

const BOLD = '\x1b[1m';
const DIM = '\x1b[2m';
const NC = '\x1b[0m';

const LOGO = [
  ' /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$',
  '| $$_____/     | $$   | $$| $$_____/| $$  / $$',
  '| $$           | $$   | $$| $$      |  $$/ $$/',
  '| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \\  $$$$/',
  '| $$__/|______/ \\  $$ $$/ | $$__/     >$$  $$',
  '| $$             \\  $$$/  | $$       /$$/\\  $$',
  '| $$$$$$$$        \\  $/   | $$$$$$$$| $$  \\ $$',
  '|________/         \\_/    |________/|__/  |__/',
].join('\n');

const DEFAULT_QUOTE_LIST = [
  'Focused effort beats scattered hours',
  'Every round finished is progress made',
  'Consistency beats intensity',
  'Start now, figure out the rest along the way',
  'A short break now means sharper focus next round',
];

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
  'Friday', 'Saturday'];

// ---------------------------------------------------------------------------
// Mutable program state (mirrors the reference's global variables)
// ---------------------------------------------------------------------------
let PRIMARY = THEME_PRIMARY[0];
let SECONDARY = THEME_SECONDARY[0];
let THEME_NAME = THEME_NAMES[0];
let THEME_INDEX = 0;
let THEME_NOTICE_UNTIL = 0;

// Environment overrides (captured before the defaults are applied)
const ENV_ALERT_SOUND = process.env.ALERT_SOUND || '';
const ENV_SINK_NAME = process.env.SINK_NAME || '';
const ENV_STATE_DIR = process.env.STATE_DIR || '';
const ENV_MAX_LOG_BYTES = process.env.MAX_LOG_BYTES || '';
const ENV_QUOTES = process.env.QUOTES || '';
const ENV_THEME = process.env.THEME || '';

// Built-in defaults
const DIR = path.dirname(fs.realpathSync(__filename));
let ALERT_SOUND = process.env.HOME
  ? path.join(process.env.HOME, 'Videos/Alarm/n_alarm.mp3') : '';
let SINK_NAME = 'OBS_Alert_Sink';
let STATE_DIR = '';
let MAX_LOG_BYTES = '1048576';
let FILE_BAR_WIDTH = 20;
let NON_TTY_ENTER_TIMEOUT = 300;
let ALERT_PID = 0;
let QUOTE_LIST = DEFAULT_QUOTE_LIST.slice();
let POINTS = 0;
let LAST_DATE = '';

// Arguments
let CONFIG_FILE = '';
let DRY_RUN = false;
let USE_ALERT = true;
let USE_SINK = true;
let ROUNDS = 0, STUDY_MIN = 0, BREAK_MIN = 0;
let CLI_THEME = '';
let DURATION_UNIT = 'minutes';
let SECONDS_PER_UNIT = 60;
let CONFIG_THEME = '';
let CONFIG_QUOTES = '';
let CONFIG_LOADED = '';

// State files
let DATE_FILE = '', DAY_FILE = '', SESSION_FILE = '', TIMER_FILE = '',
  LOG_FILE = '', PROGRESS_FILE = '', POINTS_FILE = '', MESSAGE_FILE = '',
  NEXT_FILE = '', OVERLAY_FILE = '', THEME_FILE = '';

let SESSION_TEXT = '';
let REMAINING_STR = '00:00:00';
let PCT = 0;
let NEXT_TEXT = '';
let MESSAGE_TEXT = '';
let LAST_DAY = '';
let STATE_READY = false;
let STATE_FINALIZED = false;
let IN_CLEANUP = false;

// Phase state
let PHASE_LABEL = '';
let PHASE_SUBTITLE = '';
let PHASE_NEXT = '';
let PHASE_TOTAL = 0;
let PHASE_ELAPSED = 0;
let PHASE_PAUSED = false;
let PHASE_SKIPPED = false;
let PHASE_START = 0;
let PHASE_PAUSED_TOTAL = 0;
let PHASE_PAUSE_AT = 0;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function nowSeconds() {
  // Integer wall-clock seconds since program start (bash $SECONDS).
  return Math.floor(Date.now() / 1000 - START_TIME);
}

function pad2(n) { return String(n).padStart(2, '0'); }

function dateStr(d) {
  d = d || new Date();
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function timeStr(d) {
  d = d || new Date();
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

function weekdayName(d) {
  return WEEKDAYS[(d || new Date()).getDay()];
}

function which(cmd) {
  const r = spawnSync('sh', ['-c', 'command -v "$1"', 'sh', cmd],
    { stdio: ['ignore', 'pipe', 'ignore'] });
  return r.status === 0 && String(r.stdout).trim().length > 0;
}

function out(text) { process.stdout.write(text); }
function err(text) { process.stderr.write(text); }

// ---------------------------------------------------------------------------
// Themes
// ---------------------------------------------------------------------------
function setTheme(i) {
  if (i < 0 || i >= THEME_NAMES.length) return false;
  THEME_INDEX = i;
  THEME_NAME = THEME_NAMES[i];
  PRIMARY = THEME_PRIMARY[i];
  SECONDARY = THEME_SECONDARY[i];
  return true;
}

function themeIndexOf(name) {
  if (!name) return -1;
  const want = name.toLowerCase();
  for (let i = 0; i < THEME_NAMES.length; i++) {
    if (THEME_NAMES[i].toLowerCase() === want) return i;
  }
  return -1;
}

function saveTheme() {
  if (!THEME_FILE) return;
  try { fs.writeFileSync(THEME_FILE, THEME_NAME + '\n'); } catch (e) { /* best effort */ }
}

function cycleTheme() {
  setTheme((THEME_INDEX + 1) % THEME_NAMES.length);
  saveTheme();
  THEME_NOTICE_UNTIL = nowSeconds() + 3;
  logEvent(`Theme changed to: ${THEME_NAME}`);
}

function listThemes() {
  for (let i = 0; i < THEME_NAMES.length; i++) {
    out(`  ${THEME_NAMES[i].padEnd(8)} ${THEME_PRIMARY[i]}\u2588\u2588\u2588\u2588${THEME_SECONDARY[i]}\n`);
  }
}

// ---------------------------------------------------------------------------
// Help and argument parsing
// ---------------------------------------------------------------------------
function helpText() {
  return `Usage: ${PROG} [options] <rounds> <study_minutes> <break_minutes>

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
  ${PROG} 5 50 10           # 5 rounds, 50 min study, 10 min break
  ${PROG} --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  ${PROG} --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
`;
}

function printHelp(code, stream) {
  (stream || process.stdout).write(helpText());
  process.exit(code);
}

function usageError() {
  printHelp(1, process.stderr);
}

const NUM_RE = /^[1-9][0-9]{0,3}$/;

function parseArgs(argv) {
  const args = argv.slice();
  let positional = null;
  while (args.length) {
    const a = args[0];
    if (a === '-h' || a === '--help') {
      printHelp(0);
    } else if (a === '-c' || a === '--config') {
      if (args.length < 2) { err(`Error: ${a} needs a file argument\n`); usageError(); }
      CONFIG_FILE = args[1]; args.splice(0, 2);
    } else if (a === '-d' || a === '--dry-run') {
      DRY_RUN = true; args.shift();
    } else if (a === '-n' || a === '--no-alert') {
      USE_ALERT = false; args.shift();
    } else if (a === '-s' || a === '--no-sink') {
      USE_SINK = false; args.shift();
    } else if (a === '-t' || a === '--theme') {
      if (args.length < 2) { err(`Error: ${a} needs a theme name\n`); usageError(); }
      CLI_THEME = args[1]; args.splice(0, 2);
    } else if (a === '--list-themes') {
      listThemes(); process.exit(0);
    } else if (a === '--') {
      args.shift();
      positional = args; break;
    } else if (a.startsWith('-')) {
      err(`Error: unknown option: ${a}\n`); usageError();
    } else {
      positional = args; break;
    }
  }
  positional = positional || [];

  if (positional.length !== 3) usageError();
  const [r, s, b] = positional;
  for (const v of [r, s, b]) {
    if (!NUM_RE.test(v)) usageError();
  }
  ROUNDS = parseInt(r, 10);
  STUDY_MIN = parseInt(s, 10);
  BREAK_MIN = parseInt(b, 10);
  if (ROUNDS > 50) { err('Error: rounds must be <= 50\n'); usageError(); }
  if (STUDY_MIN > 600) { err('Error: study minutes must be <= 600\n'); usageError(); }
  if (BREAK_MIN > 120) { err('Error: break minutes must be <= 120\n'); usageError(); }

  if (DRY_RUN) {
    DURATION_UNIT = 'seconds';
    SECONDS_PER_UNIT = 1;
  }
}

// ---------------------------------------------------------------------------
// Configuration file
// ---------------------------------------------------------------------------
// The config file is bash source code (exactly like the reference). It is
// interpreted by a child bash that first seeds the pre-config default knobs,
// sources the file, and then dumps the resulting values for this program to
// pick up: unit separator 0x1F ('\037') between key and value, record
// separator 0x1E ('\036') between records. A sourced file that calls
// `exit N` terminates the child before the dump is written, which this
// program detects and mirrors.
const CONFIG_DUMP_SH = `
set -u
IFS=$'\\037' read -r -a QUOTE_LIST <<< "\${QUOTES_SEED-}"
unset QUOTES_SEED
source "$1" || true
{
  d() { printf '%s\\037%s\\036' "$1" "\${2-}"; }
  d ALERT_SOUND "\${ALERT_SOUND-}"
  d SINK_NAME "\${SINK_NAME-}"
  d STATE_DIR "\${STATE_DIR-}"
  d MAX_LOG_BYTES "\${MAX_LOG_BYTES-}"
  d FILE_BAR_WIDTH "\${FILE_BAR_WIDTH-}"
  d NON_TTY_ENTER_TIMEOUT "\${NON_TTY_ENTER_TIMEOUT-}"
  d THEME "\${THEME-}"
  d POINTS "\${POINTS-}"
  d LAST_DATE "\${LAST_DATE-}"
  d QUOTES "\${QUOTES-}"
  for q in \${QUOTE_LIST[@]+"\${QUOTE_LIST[@]}"}; do d QUOTE "$q"; done
} > "$2"
`;

function findConfigFile() {
  if (CONFIG_FILE) return CONFIG_FILE;
  if (process.env.OBS_PANEL_CONFIG) return process.env.OBS_PANEL_CONFIG;
  const xdgBase = process.env.XDG_CONFIG_HOME
    || path.join(process.env.HOME || '', '.config');
  const xdg = path.join(xdgBase, 'obs-study-panel', 'config');
  if (fs.existsSync(xdg) && fs.statSync(xdg).isFile()) return xdg;
  const localCfg = path.join(DIR, 'obs-panel.conf');
  if (fs.existsSync(localCfg) && fs.statSync(localCfg).isFile()) return localCfg;
  return null;
}

function quotesToList(raw) {
  QUOTE_LIST = raw.split('\n')
    .map((l) => l.replace(/\r+$/, ''))
    .filter((l) => l.length > 0);
}

function parseIntSafe(v, dflt) {
  const n = parseInt(String(v == null ? '' : v).trim(), 10);
  return Number.isFinite(n) ? n : dflt;
}

function loadConfig(cfgPath) {
  try {
    fs.accessSync(cfgPath, fs.constants.R_OK);
  } catch (e) {
    err(`Error: config file is not readable: ${cfgPath}\n`);
    process.exit(1);
  }
  // Syntax check up front, exactly like the reference.
  if (!which('bash')) {
    err(`Error: bash is required to read the config file: ${cfgPath}\n`);
    process.exit(1);
  }
  const chk = spawnSync('bash', ['-n', cfgPath], { encoding: 'utf8' });
  if (chk.status !== 0) {
    err(`Error: syntax error in config file: ${cfgPath}\n`);
    const lines = String(chk.stderr || '').split('\n').filter((l) => l.trim());
    for (const line of lines.slice(0, 3)) err(line + '\n');
    process.exit(1);
  }

  const dumpPath = path.join(os.tmpdir(),
    `obs-panel-conf-${process.pid}-${Date.now()}`);
  try { fs.writeFileSync(dumpPath, '', { flag: 'w' }); } catch (e) { /* unreachable */ }
  const childEnv = Object.assign({}, process.env);
  // Seed the pre-config defaults, exactly what the reference holds while it
  // sources the file (the real environment's THEME/QUOTES pass through).
  childEnv.ALERT_SOUND = ALERT_SOUND;
  childEnv.SINK_NAME = SINK_NAME;
  childEnv.STATE_DIR = '';
  childEnv.MAX_LOG_BYTES = '1048576';
  childEnv.FILE_BAR_WIDTH = '20';
  childEnv.NON_TTY_ENTER_TIMEOUT = '300';
  childEnv.POINTS = String(POINTS);
  childEnv.LAST_DATE = LAST_DATE;
  childEnv.QUOTES_SEED = QUOTE_LIST.join('\x1f');
  const proc = spawnSync('bash', ['-c', CONFIG_DUMP_SH, 'obs-panel', cfgPath, dumpPath],
    { env: childEnv });
  const rc = proc.status;
  const raw = fs.existsSync(dumpPath)
    ? fs.readFileSync(dumpPath, 'latin1') : '';
  try { fs.unlinkSync(dumpPath); } catch (e) { /* best effort */ }

  if (!raw) {
    // The config called exit N before the dump was written.
    process.exit(rc !== null && rc !== 0 ? rc : 1);
  }

  const values = {};
  const quotes = [];
  for (const record of raw.split('\x1e')) {
    if (!record) continue;
    const i = record.indexOf('\x1f');
    if (i < 0) continue;
    const key = record.slice(0, i);
    const value = record.slice(i + 1);
    if (key === 'QUOTE') quotes.push(value);
    else values[key] = value;
  }

  ALERT_SOUND = values.ALERT_SOUND !== undefined ? values.ALERT_SOUND : ALERT_SOUND;
  SINK_NAME = values.SINK_NAME !== undefined ? values.SINK_NAME : SINK_NAME;
  STATE_DIR = values.STATE_DIR !== undefined ? values.STATE_DIR : '';
  MAX_LOG_BYTES = values.MAX_LOG_BYTES !== undefined ? values.MAX_LOG_BYTES : '1048576';
  FILE_BAR_WIDTH = values.FILE_BAR_WIDTH !== undefined ? values.FILE_BAR_WIDTH : '20';
  NON_TTY_ENTER_TIMEOUT =
    values.NON_TTY_ENTER_TIMEOUT !== undefined
      ? values.NON_TTY_ENTER_TIMEOUT : '300';
  CONFIG_THEME = values.THEME || '';
  POINTS = parseIntSafe(values.POINTS, 0);
  LAST_DATE = values.LAST_DATE || '';
  CONFIG_QUOTES = values.QUOTES || '';
  // Zero QUOTE records means the config emptied the list: the seeded
  // defaults would have been dumped otherwise.
  QUOTE_LIST = quotes;
  CONFIG_LOADED = cfgPath;
}

function applyQuoteSources() {
  if (ENV_QUOTES) quotesToList(ENV_QUOTES);
  else if (CONFIG_QUOTES) quotesToList(CONFIG_QUOTES);
}

function sanityKnobs() {
  if (!/^[0-9]+$/.test(String(MAX_LOG_BYTES)) || parseInt(MAX_LOG_BYTES, 10) <= 0) {
    MAX_LOG_BYTES = 1048576;
  } else {
    MAX_LOG_BYTES = parseInt(MAX_LOG_BYTES, 10);
  }
  if (!/^[0-9]+$/.test(String(FILE_BAR_WIDTH))
    || parseInt(FILE_BAR_WIDTH, 10) <= 0 || parseInt(FILE_BAR_WIDTH, 10) > 200) {
    FILE_BAR_WIDTH = 20;
  } else {
    FILE_BAR_WIDTH = parseInt(FILE_BAR_WIDTH, 10);
  }
  if (!/^[0-9]+$/.test(String(NON_TTY_ENTER_TIMEOUT))
    || parseInt(NON_TTY_ENTER_TIMEOUT, 10) <= 0
    || parseInt(NON_TTY_ENTER_TIMEOUT, 10) > 3600) {
    NON_TTY_ENTER_TIMEOUT = 300;
  } else {
    NON_TTY_ENTER_TIMEOUT = parseInt(NON_TTY_ENTER_TIMEOUT, 10);
  }
}

// ---------------------------------------------------------------------------
// Paths and theme selection
// ---------------------------------------------------------------------------
function setupPaths() {
  STATE_DIR = STATE_DIR || DIR;
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
  } catch (e) {
    err(`Error: cannot create state dir: ${STATE_DIR}\n`);
    process.exit(1);
  }
  DATE_FILE = path.join(STATE_DIR, 'date.txt');
  DAY_FILE = path.join(STATE_DIR, 'day.txt');
  SESSION_FILE = path.join(STATE_DIR, 'session.txt');
  TIMER_FILE = path.join(STATE_DIR, 'timer.txt');
  LOG_FILE = path.join(STATE_DIR, 'log.txt');
  PROGRESS_FILE = path.join(STATE_DIR, 'progress.txt');
  POINTS_FILE = path.join(STATE_DIR, 'points.txt');
  MESSAGE_FILE = path.join(STATE_DIR, 'message.txt');
  NEXT_FILE = path.join(STATE_DIR, 'next.txt');
  OVERLAY_FILE = path.join(STATE_DIR, 'overlay.txt');
  THEME_FILE = path.join(STATE_DIR, 'theme.txt');
}

function selectTheme() {
  let request = CLI_THEME;
  if (!request && ENV_THEME) request = ENV_THEME;
  if (!request && CONFIG_THEME) request = CONFIG_THEME;
  if (!request && fs.existsSync(THEME_FILE) && fs.statSync(THEME_FILE).isFile()) {
    try {
      request = fs.readFileSync(THEME_FILE, 'utf8').split('\n')[0];
    } catch (e) { /* best effort */ }
  }
  if (request) {
    const idx = themeIndexOf(request);
    if (idx < 0) {
      err(`Warning: unknown theme '${request}', using ${THEME_NAME}\n`);
    } else {
      setTheme(idx);
    }
  }
}

// ---------------------------------------------------------------------------
// OBS state files
// ---------------------------------------------------------------------------
function writeState(path_, text) {
  fs.writeFileSync(path_, text + '\n');
}

function updateDateDay() {
  const d = dateStr();
  if (d === LAST_DATE) return;
  LAST_DATE = d;
  LAST_DAY = weekdayName();
  writeState(DATE_FILE, d);
  writeState(DAY_FILE, LAST_DAY);
}

function syncState() {
  updateDateDay();
  publishState();
}

function makeBar(filled, width, fill, empty, head) {
  head = head || '';
  let bar = '';
  for (let i = 0; i < width; i++) {
    if (i < filled) {
      bar += (head && i === filled - 1) ? head : fill;
    } else {
      bar += empty;
    }
  }
  return bar;
}

function fileBar() {
  return makeBar(Math.floor(PCT * FILE_BAR_WIDTH / 100), FILE_BAR_WIDTH, '#', '-');
}

function publishState() {
  const bar = fileBar();
  writeState(SESSION_FILE, SESSION_TEXT);
  writeState(TIMER_FILE, REMAINING_STR);
  writeState(POINTS_FILE, String(POINTS));
  writeState(NEXT_FILE, NEXT_TEXT);
  writeState(MESSAGE_FILE, MESSAGE_TEXT);
  writeState(PROGRESS_FILE, `[${bar}] ${String(PCT).padStart(3, ' ')}%`);
  const overlay = [`${LAST_DATE} ${LAST_DAY}`, SESSION_TEXT, REMAINING_STR,
    `[${bar}] ${String(PCT).padStart(3, ' ')}%`, `Pts: ${POINTS}`,
    `Next: ${NEXT_TEXT}`];
  if (MESSAGE_TEXT) overlay.push(MESSAGE_TEXT);
  fs.writeFileSync(OVERLAY_FILE, overlay.join('\n') + '\n');
}

function rotateLogIfNeeded() {
  try {
    const st = fs.statSync(LOG_FILE);
    if (st.size >= MAX_LOG_BYTES) {
      fs.renameSync(LOG_FILE, `${LOG_FILE}.1`);
      fs.writeFileSync(LOG_FILE, '');
    }
  } catch (e) { /* missing or unreadable log: nothing to rotate */ }
}

function logEvent(msg) {
  rotateLogIfNeeded();
  try {
    const d = new Date();
    fs.appendFileSync(LOG_FILE,
      `[${dateStr(d)} ${timeStr(d)}] ${msg}\n`);
  } catch (e) { /* best effort */ }
}

// ---------------------------------------------------------------------------
// Audio alerts
// ---------------------------------------------------------------------------
function sinkIsReady() {
  if (!which('pactl')) return false;
  const r = spawnSync('pactl', ['list', 'short', 'sinks'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  if (r.status !== 0) return false;
  for (const line of String(r.stdout || '').split('\n')) {
    const fields = line.trim().split(/\s+/);
    if (fields.length > 1 && fields[1] === SINK_NAME) return true;
  }
  return false;
}

function setupAudioSink() {
  if (!USE_SINK) return;
  if (!which('pactl')) return;
  if (sinkIsReady()) return;
  try {
    spawnSync('pactl', ['load-module', 'module-null-sink',
      `sink_name=${SINK_NAME}`,
      `sink_properties=device.description=${SINK_NAME}`],
      { stdio: ['ignore', 'ignore', 'ignore'] });
  } catch (e) { /* best effort */ }
}

function stopAlert() {
  if (ALERT_PID > 0) {
    try { process.kill(ALERT_PID, 'SIGTERM'); } catch (e) { /* already gone */ }
    ALERT_PID = 0;
  }
}

function playAlert() {
  if (!USE_ALERT) return;
  stopAlert();
  if (!ALERT_SOUND || !fs.existsSync(ALERT_SOUND) || !fs.statSync(ALERT_SOUND).isFile()) {
    out(`${DIM}(alert file not found: ${ALERT_SOUND || 'none'})${NC}\n`);
    return;
  }

  let player = null;
  if (which('mpv')) player = ['mpv', '--no-video', '--volume=70'];
  else if (which('paplay')) player = ['paplay'];
  else if (which('ffplay')) player = ['ffplay', '-nodisp', '-autoexit'];
  else if (which('cvlc')) player = ['cvlc', '--play-and-exit', '--no-video', '--volume=70'];
  else {
    out(`${DIM}(no audio player found - install mpv / paplay / ffplay)${NC}\n`);
    return;
  }

  if (USE_SINK && !sinkIsReady()) setupAudioSink();

  try {
    if (USE_SINK && sinkIsReady()) {
      const env = Object.assign({}, process.env, { PULSE_SINK: SINK_NAME });
      ALERT_PID = spawn(player[0], player.slice(1).concat(ALERT_SOUND),
        { env, detached: true, stdio: 'ignore' }).pid;
      out(`${DIM}-> alert on OBS sink (${SINK_NAME})${NC}\n`);
    } else {
      ALERT_PID = spawn(player[0], player.slice(1).concat(ALERT_SOUND),
        { detached: true, stdio: 'ignore' }).pid;
      out(`${SECONDARY}-> alert on default device (OBS sink unavailable)${NC}\n`);
    }
  } catch (e) { /* best effort */ }
}

// ---------------------------------------------------------------------------
// Keyboard input
// ---------------------------------------------------------------------------
const STDIN_IS_TTY = Boolean(process.stdin.isTTY);
let TERM_SAVED = null;
let KEY = '';
let KEY_READ = false;

function setupTerminal() {
  if (!STDIN_IS_TTY) return;
  try {
    const r = spawnSync('sh', ['-c', 'stty -g < /dev/tty'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    if (r.status === 0) TERM_SAVED = String(r.stdout).trim();
  } catch (e) { /* best effort */ }
  try {
    process.stdin.setRawMode(true);
    // Node's raw mode switches the tty to cfmakeraw, which also disables
    // ISIG - Ctrl+C would no longer generate SIGINT. The reference keeps
    // ISIG (bash read -s), so switch the signal chars back on.
    try {
      spawnSync('stty', ['isig'], { stdio: ['inherit', 'ignore', 'ignore'] });
    } catch (e) { /* best effort */ }
  } catch (e) { /* not a real tty after all */ }
}

function restoreTerminal() {
  if (!STDIN_IS_TTY) return;
  try {
    if (TERM_SAVED) {
      spawnSync('sh', ['-c', `stty ${TERM_SAVED} < /dev/tty`],
        { stdio: ['ignore', 'ignore', 'ignore'] });
    } else {
      process.stdin.setRawMode(false);
    }
  } catch (e) { /* best effort */ }
  TERM_SAVED = null;
}

// A single sequential queue of pending input bytes. The strictly
// sequential waiters attach a temporary listener only while they are
// actually waiting, so chunks are never double-buffered and no input is
// consumed outside of a wait.
const inputQueue = [];
let inputEof = false;

try {
  process.stdin.on('error', () => { inputEof = true; });
} catch (e) { /* best effort */ }

// Wait for one input byte with a timeout (seconds, may be fractional).
// Resolves: number (byte) | 'timeout' | 'eof'.
function waitByte(timeout) {
  if (inputQueue.length > 0) return Promise.resolve(inputQueue.shift());
  if (inputEof) return Promise.resolve('eof');
  return new Promise((resolve) => {
    let settled = false;
    const finish = (v) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      process.stdin.removeListener('data', onData);
      process.stdin.removeListener('end', onEnd);
      resolve(v);
    };
    const timer = setTimeout(() => finish('timeout'), timeout * 1000);
    function onData(chunk) {
      for (let i = chunk.length - 1; i >= 0; i--) inputQueue.unshift(chunk[i]);
      finish(inputQueue.shift());
    }
    function onEnd() {
      inputEof = true;
      finish('eof');
    }
    process.stdin.on('data', onData);
    process.stdin.on('end', onEnd);
  });
}

async function waitKey(timeout) {
  KEY = '';
  KEY_READ = false;
  if (!STDIN_IS_TTY) {
    await new Promise((r) => setTimeout(r, timeout * 1000));
    return;
  }
  const b = await waitByte(timeout);
  if (b === 'timeout' || b === 'eof') return;
  KEY_READ = true;
  if (b === 0x1b) {
    KEY = '';
    const nxt = await waitByte(0.3);
    if (nxt === 0x74 || nxt === 0x54) KEY = 'alt-t'; // 't' / 'T'
  } else {
    KEY = String.fromCharCode(b);
  }
}

async function discardPendingInput() {
  if (!STDIN_IS_TTY) return;
  for (;;) {
    const b = await waitByte(0.01);
    if (b === 'timeout' || b === 'eof') return;
  }
}

async function waitForEnter() {
  if (STDIN_IS_TTY) {
    for (;;) {
      const b = await waitByte(1);
      if (b === 'timeout') { updateDateDay(); continue; }
      // Enter, Ctrl+D (EOF) or the EOF condition all continue.
      if (b === 'eof' || b === 0x0a || b === 0x04) return;
    }
  }
  let waited = 0;
  while (waited < NON_TTY_ENTER_TIMEOUT) {
    const sliceEnd = Date.now() + 5000;
    for (;;) {
      const remaining = sliceEnd - Date.now();
      if (remaining <= 0) { waited += 5; break; }
      const b = await waitByte(remaining / 1000);
      if (b === 'eof') return;
      if (b === 'timeout') { waited += 5; break; }
      if (b === 0x0a) return; // complete line
      // partial line: keep consuming within this slice
    }
  }
}

// ---------------------------------------------------------------------------
// Status / progress UI
// ---------------------------------------------------------------------------
const TERM_BAR_WIDTH = 24;
const BOX_INNER = 62;

function phaseColor(label) {
  return label === 'STUDY' ? PRIMARY : SECONDARY;
}

function drawStatus(label, round, totalRounds, elapsed, total, paused) {
  let filled = 0;
  if (total > 0) filled = Math.floor(elapsed * TERM_BAR_WIDTH / total);
  if (filled > TERM_BAR_WIDTH) filled = TERM_BAR_WIDTH;
  const bar = makeBar(filled, TERM_BAR_WIDTH, '=', ' ', '>');
  const color = phaseColor(label);
  let flag = '';
  if (paused) flag = `${PRIMARY} PAUSED${NC}`;
  if (nowSeconds() < THEME_NOTICE_UNTIL) flag += `  ${DIM}Theme: ${THEME_NAME}${NC}`;
  out('\r\x1b[K');
  out(`${BOLD}${color}${label.padEnd(6)}${NC} [${round}/${totalRounds}] ` +
    `${color}[${bar}]${NC} ${String(PCT).padStart(3, ' ')}%  ${REMAINING_STR}  ` +
    `${PRIMARY}Pts:${POINTS}${NC}${flag}`);
}

function boxRow(color, plain, styled) {
  let pad = BOX_INNER - plain.length;
  if (pad < 0) pad = 0;
  out(`${color}\u2551${styled}${' '.repeat(pad)}${color}\u2551${NC}\n`);
}

function durationLabel(n) {
  if (n === 1) return DURATION_UNIT === 'seconds' ? '1 second' : '1 minute';
  return `${n} ${DURATION_UNIT}`;
}

function roundsLabel(n) {
  return n === 1 ? '1 round' : `${n} rounds`;
}

function phaseHeader(label, round, total, minutes, subtitle) {
  subtitle = subtitle.slice(0, BOX_INNER - 4);
  const color = phaseColor(label);
  const bar = '\u2550'.repeat(BOX_INNER);
  const info = `${label}  \u00b7  Round ${round} / ${total}  \u00b7  ${durationLabel(minutes)}`;
  out('\n');
  out(`${color}\u2554${bar}\u2557${NC}\n`);
  boxRow(color, `  ${info}`,
    `  ${BOLD}${label}${NC}${color}  \u00b7  Round ${round} / ${total}  \u00b7  ${durationLabel(minutes)}`);
  boxRow(color, `  ${subtitle}`, `  ${DIM}${subtitle}${NC}${color}`);
  if (STDIN_IS_TTY) {
    const keys = '  p pause  \u00b7  s skip  \u00b7  q quit  \u00b7  Alt+T theme';
    boxRow(color, keys, `${DIM}${keys}${NC}${color}`);
  }
  out(`${color}\u255a${bar}\u255d${NC}\n`);
  out('\n');
}

function showCompletion(phase, round, totalRounds, nextPhase, skipped) {
  const width = 60;
  const line = '='.repeat(width);
  let title;
  if (skipped === 1) title = 'PHASE SKIPPED';
  else if (phase === 'STUDY') title = 'STUDY SESSION COMPLETE';
  else title = 'BREAK COMPLETE';
  const color = phaseColor(phase);
  out('\n');
  out(`${color}${line}${NC}\n`);
  out(`${color}${' '.repeat(Math.floor((width + title.length) / 2))}${title}${NC}\n`);
  out(`${color}${line}${NC}\n`);
  out('\n');
  out(`  Round:   ${BOLD}${round}${NC} / ${totalRounds}\n`);
  out(`  Points:  ${PRIMARY}${POINTS}${NC}\n`);
  out('\n');
  if (nextPhase === 'None') out(`  Next:    ${DIM}Session complete${NC}\n`);
  else out(`  Next:    ${BOLD}${nextPhase}${NC}\n`);
  out('\n');
  out(`  ${PRIMARY}Press Enter to continue...${NC}`);
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------
function fmtHms(total) {
  return `${pad2(Math.floor(total / 3600))}:${pad2(Math.floor(total % 3600 / 60))}:${pad2(total % 60)}`;
}

function phasePrepare(ptype, minutes, round, totalRounds) {
  if (ptype === 'study') {
    PHASE_LABEL = 'STUDY';
    PHASE_SUBTITLE = QUOTE_LIST.length > 0
      ? QUOTE_LIST[Math.floor(Math.random() * QUOTE_LIST.length)] : 'Stay focused.';
  } else {
    PHASE_LABEL = 'BREAK';
    PHASE_SUBTITLE = 'Relax and recharge.';
  }

  if (ptype === 'study') {
    PHASE_NEXT = round < totalRounds
      ? `Break (${durationLabel(BREAK_MIN)})` : 'None';
  } else {
    PHASE_NEXT = `Study (${durationLabel(STUDY_MIN)})`;
  }

  PHASE_TOTAL = minutes * SECONDS_PER_UNIT;
  PHASE_ELAPSED = 0;
  PHASE_PAUSED = false;
  PHASE_SKIPPED = false;
  PHASE_START = nowSeconds();
  PHASE_PAUSED_TOTAL = 0;
  PHASE_PAUSE_AT = 0;

  SESSION_TEXT = `${PHASE_LABEL} ${round}/${totalRounds}`;
  REMAINING_STR = fmtHms(PHASE_TOTAL);
  PCT = 0;
  NEXT_TEXT = PHASE_NEXT === 'None' ? 'Session complete' : PHASE_NEXT;
  MESSAGE_TEXT = PHASE_SUBTITLE;

  logEvent(`Start: ${PHASE_LABEL} ${round}/${totalRounds} (${durationLabel(minutes)})`);
  phaseHeader(PHASE_LABEL, round, totalRounds, minutes, PHASE_SUBTITLE);
  syncState();
}

function phaseHandleKey(round, totalRounds) {
  if (KEY === 'p' || KEY === 'P' || KEY === ' ') {
    if (PHASE_PAUSED) {
      PHASE_PAUSED_TOTAL += nowSeconds() - PHASE_PAUSE_AT;
      PHASE_PAUSED = false;
      logEvent(`Resumed: ${PHASE_LABEL} ${round}/${totalRounds}`);
    } else {
      PHASE_PAUSED = true;
      PHASE_PAUSE_AT = nowSeconds();
      logEvent(`Paused: ${PHASE_LABEL} ${round}/${totalRounds}`);
    }
  } else if (KEY === 's' || KEY === 'S') {
    PHASE_SKIPPED = true;
    logEvent(`Skipped: ${PHASE_LABEL} ${round}/${totalRounds}`);
  } else if (KEY === 'q' || KEY === 'Q') {
    logEvent('Quit requested by user');
    cleanup(0);
  } else if (KEY === 'alt-t') {
    cycleTheme();
  }
}

async function phaseCount(round, totalRounds) {
  while (PHASE_ELAPSED < PHASE_TOTAL) {
    let remaining = PHASE_TOTAL - PHASE_ELAPSED;
    if (remaining < 0) remaining = 0;
    REMAINING_STR = fmtHms(remaining);
    PCT = PHASE_TOTAL > 0 ? Math.floor(PHASE_ELAPSED * 100 / PHASE_TOTAL) : 0;
    if (PCT > 100) PCT = 100;
    SESSION_TEXT = `${PHASE_LABEL} ${round}/${totalRounds}`;
    if (PHASE_PAUSED) SESSION_TEXT += ' (PAUSED)';

    syncState();
    drawStatus(PHASE_LABEL, round, totalRounds, PHASE_ELAPSED, PHASE_TOTAL,
      PHASE_PAUSED ? 1 : 0);

    await waitKey(1);
    if (KEY_READ) {
      phaseHandleKey(round, totalRounds);
      if (PHASE_SKIPPED) break;
    }
    // CRASH-INJECT-POINT
    if (!PHASE_PAUSED) {
      PHASE_ELAPSED = nowSeconds() - PHASE_START - PHASE_PAUSED_TOTAL;
    }
  }
}

async function phaseFinish(round, totalRounds) {
  if (PHASE_SKIPPED) {
    SESSION_TEXT = `${PHASE_LABEL} ${round}/${totalRounds} (SKIPPED)`;
  } else {
    PCT = 100;
    POINTS += 1;
  }
  REMAINING_STR = '00:00:00';
  syncState();
  drawStatus(PHASE_LABEL, round, totalRounds, PHASE_ELAPSED, PHASE_TOTAL, 0);
  out('\n');
  logEvent(`End: ${PHASE_LABEL} ${round}/${totalRounds}`);

  playAlert();

  await discardPendingInput();
  showCompletion(PHASE_LABEL, round, totalRounds, PHASE_NEXT, PHASE_SKIPPED ? 1 : 0);
  await waitForEnter();
  stopAlert();
  out('\n');
}

async function runPhase(ptype, minutes, round, totalRounds) {
  phasePrepare(ptype, minutes, round, totalRounds);
  await phaseCount(round, totalRounds);
  await phaseFinish(round, totalRounds);
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------
function resetStateFiles() {
  SESSION_TEXT = 'stopped';
  REMAINING_STR = '00:00:00';
  PCT = 0;
  NEXT_TEXT = '';
  syncState();
}

function cleanup(code) {
  if (IN_CLEANUP) return;
  IN_CLEANUP = true;
  STATE_FINALIZED = true;
  stopAlert();
  try { resetStateFiles(); } catch (e) { /* best effort */ }
  try { logEvent('Protocol stopped manually'); } catch (e) { /* best effort */ }
  try {
    out('\n');
    out(`${SECONDARY}${BOLD}Interrupted.${NC} ${DIM}State files reset to stopped.${NC}\n`);
  } catch (e) { /* best effort */ }
  restoreTerminal();
  process.exit(code);
}

function onUnexpectedDeath(rc) {
  if (!STATE_READY) return;
  if (STATE_FINALIZED) return;
  STATE_FINALIZED = true;
  stopAlert();
  try { resetStateFiles(); } catch (e) { /* best effort */ }
  try { logEvent(`Protocol ended unexpectedly (exit ${rc})`); } catch (e) { /* best effort */ }
}

function finalizeSession() {
  SESSION_TEXT = 'session complete';
  REMAINING_STR = '00:00:00';
  PCT = 100;
  NEXT_TEXT = '';
  syncState();
  STATE_FINALIZED = true;
  logEvent(`Protocol complete - total points: ${POINTS}`);
}

function finalBanner() {
  const bannerWidth = 60;
  const title = 'ALL SESSIONS COMPLETE';
  const inner = bannerWidth - 2;
  const pad = Math.floor((inner - title.length) / 2);
  const border = '#'.repeat(bannerWidth);
  out('\n');
  out(`${PRIMARY}${border}${NC}\n`);
  out(`${PRIMARY}#${NC}${' '.repeat(pad)}${BOLD}${title}` +
    `${' '.repeat(inner - pad - title.length)}${NC}#${PRIMARY}\n`);
  out(`${PRIMARY}${border}${NC}\n`);
  out('\n');
  out(`  ${BOLD}Total Rounds:${NC}  ${PRIMARY}${ROUNDS}${NC}\n`);
  out(`  ${BOLD}Total Points:${NC} ${PRIMARY}${POINTS}${NC}\n`);
  out('\n');
  out(`${PRIMARY}${BOLD}Great work!${NC} ${DIM}Exiting.${NC}\n`);
}

function printLogo() {
  out(`${PRIMARY}\n`);
  out(`${LOGO}\n`);
  out(`${NC}\n`);
  out(`${PRIMARY}${BOLD}     Study / Break Timer Protocol${NC}\n`);
  out(`${DIM}\u2500\u2500 live state written to date \u00b7 day \u00b7 session \u00b7 timer \u00b7 log${NC}\n`);
  out('\n');
}

// Signal handling: conventional exit codes 128 + signal number.
process.on('SIGINT', () => cleanup(130));
process.on('SIGTERM', () => cleanup(143));
process.on('SIGHUP', () => cleanup(129));

// The EXIT-trap equivalent: runs on process.exit and on normal exit, and
// on fatal errors via the handlers below. Must not change the exit code.
process.on('exit', (code) => {
  onUnexpectedDeath(code);
  restoreTerminal();
});

// An uncaught error is the "unexpected death" path: reset the state files,
// log, and keep the conventional exit code of a fatal Node error (1).
process.on('uncaughtException', (e) => {
  try { err(`${e && e.stack ? e.stack : e}\n`); } catch (e2) { /* ignore */ }
  onUnexpectedDeath(1);
  process.exit(1);
});

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  parseArgs(process.argv.slice(2));

  const cfg = findConfigFile();
  if (cfg) loadConfig(cfg);

  // Environment variables beat the config file.
  if (ENV_ALERT_SOUND) ALERT_SOUND = ENV_ALERT_SOUND;
  if (ENV_SINK_NAME) SINK_NAME = ENV_SINK_NAME;
  if (ENV_STATE_DIR) STATE_DIR = ENV_STATE_DIR;
  if (ENV_MAX_LOG_BYTES) MAX_LOG_BYTES = ENV_MAX_LOG_BYTES;

  applyQuoteSources();
  sanityKnobs();

  setupPaths();
  selectTheme();
  setupTerminal();

  printLogo();
  setupAudioSink();
  updateDateDay();
  // From here on the state files may be written (and have to be reset if
  // the program dies unexpectedly).
  STATE_READY = true;
  logEvent(`Starting new study protocol: ${roundsLabel(ROUNDS)}, ` +
    `${durationLabel(STUDY_MIN)} study, ${durationLabel(BREAK_MIN)} break`);

  out(`${SECONDARY}Protocol:${NC} ${BOLD}${roundsLabel(ROUNDS)}${NC}  ${DIM}|${NC}  ` +
    `${BOLD}${durationLabel(STUDY_MIN)}${NC} study  ${DIM}|${NC}  ` +
    `${BOLD}${durationLabel(BREAK_MIN)}${NC} break  ${DIM}|${NC}  ` +
    `${BOLD}Theme: ${THEME_NAME}${NC}\n`);
  if (CONFIG_LOADED) out(`${DIM}Config: ${CONFIG_LOADED}${NC}\n`);
  out('\n');

  for (let round = 1; round <= ROUNDS; round++) {
    await runPhase('study', STUDY_MIN, round, ROUNDS);
    if (round < ROUNDS) await runPhase('break', BREAK_MIN, round, ROUNDS);
  }

  finalizeSession();
  finalBanner();
}

main().then(() => { process.exit(0); }).catch((e) => {
  try { err(`${e && e.stack ? e.stack : e}\n`); } catch (e2) { /* ignore */ }
  onUnexpectedDeath(1);
  process.exit(1);
});
