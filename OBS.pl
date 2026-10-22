#!/usr/bin/env perl
#
# OBS.pl - Study/break timer protocol (Perl port of OBS.sh)
#
# Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
# progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
# use as Text sources in OBS Studio. OBS.sh is the reference implementation;
# see docs/port-spec.md for the behavior contract and README.md for usage.
#
# Requirements: Perl 5.10+ (core modules only: POSIX, IO::Select, Time::HiRes),
# bash (to load the bash-syntax config file).
#
# Usage:   ./OBS.pl [options] <rounds> <study_minutes> <break_minutes>
# Example: ./OBS.pl 5 50 10            ->  5 rounds, 50 min study, 10 min break
#          ./OBS.pl --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
# Stop:    Ctrl+C, or press 'q' while a phase is running
# Theme:   press Alt+T while a phase is running (see --list-themes)
#
use strict;
use warnings;
use POSIX qw(strftime _exit);
use IO::Select;
use Time::HiRes qw(sleep time);
use Cwd qw(abs_path);
use File::Path qw(make_path);

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

my $PROG = (defined $0 && $0 ne '') ? ($0 =~ m{([^/]*)$} ? $1 : $0) : 'OBS.pl';
my $START_TIME = time();

# ---------------------------------------------------------------------------
# Color themes: (name, primary, secondary)
# ---------------------------------------------------------------------------
my @THEME_NAMES  = qw(Purple Ocean Forest Sunset Rose Gold
                      Mono Ice Ember Neon Cobalt Cherry);
my @THEME_PRIMARY = ("\e[1;35m","\e[1;36m","\e[1;32m","\e[1;33m",
                     "\e[1;95m","\e[1;93m","\e[1;37m","\e[1;96m",
                     "\e[1;91m","\e[1;92m","\e[1;34m","\e[1;91m");
my @THEME_SECONDARY = ("\e[0;35m","\e[0;34m","\e[0;32m","\e[0;31m",
                       "\e[0;31m","\e[0;33m","\e[0;37m","\e[0;36m",
                       "\e[0;31m","\e[0;96m","\e[0;36m","\e[0;35m");

my $BOLD = "\e[1m";
my $DIM  = "\e[2m";
my $NC   = "\e[0m";

my $LOGO = <<'EOT';
 /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
| $$_____/     | $$   | $$| $$_____/| $$  / $$
| $$           | $$   | $$| $$      |  $$/ $$/
| $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
| $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
| $$             \  $$$/  | $$       /$$/\  $$
| $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
|________/         \_/    |________/|__/  |__/
EOT
chomp $LOGO;

my @DEFAULT_QUOTE_LIST = (
    'Focused effort beats scattered hours',
    'Every round finished is progress made',
    'Consistency beats intensity',
    'Start now, figure out the rest along the way',
    'A short break now means sharper focus next round',
);

# ---------------------------------------------------------------------------
# Mutable program state (mirrors the reference's global variables)
# ---------------------------------------------------------------------------
my ($PRIMARY, $SECONDARY, $THEME_NAME, $THEME_INDEX, $THEME_NOTICE_UNTIL);
$PRIMARY = $THEME_PRIMARY[0]; $SECONDARY = $THEME_SECONDARY[0];
$THEME_NAME = $THEME_NAMES[0]; $THEME_INDEX = 0; $THEME_NOTICE_UNTIL = 0;

# Environment overrides (captured before the defaults are applied)
my $ENV_ALERT_SOUND   = $ENV{ALERT_SOUND} // '';
my $ENV_SINK_NAME     = $ENV{SINK_NAME} // '';
my $ENV_STATE_DIR     = $ENV{STATE_DIR} // '';
my $ENV_MAX_LOG_BYTES = $ENV{MAX_LOG_BYTES} // '';
my $ENV_QUOTES        = $ENV{QUOTES} // '';
my $ENV_THEME         = $ENV{THEME} // '';

# Built-in defaults
my $DIR = ($0 =~ m{^(.*)/[^/]*$}) ? abs_path($1) : abs_path('.');
my $ALERT_SOUND = exists $ENV{HOME} ? "$ENV{HOME}/Videos/Alarm/n_alarm.mp3" : '';
my $SINK_NAME = 'OBS_Alert_Sink';
my $STATE_DIR = '';
my $MAX_LOG_BYTES = '1048576';
my $FILE_BAR_WIDTH = 20;
my $NON_TTY_ENTER_TIMEOUT = 300;
my $ALERT_PID = 0;
my @QUOTE_LIST = @DEFAULT_QUOTE_LIST;
my $POINTS = 0;
my $LAST_DATE = '';

# Arguments
my $CONFIG_FILE = '';
my $DRY_RUN = 0;
my $USE_ALERT = 1;
my $USE_SINK = 1;
my ($ROUNDS, $STUDY_MIN, $BREAK_MIN) = (0, 0, 0);
my $CLI_THEME = '';
my $DURATION_UNIT = 'minutes';
my $SECONDS_PER_UNIT = 60;
my $CONFIG_THEME = '';
my $CONFIG_QUOTES = '';
my $CONFIG_LOADED = '';

# State files
my ($DATE_FILE, $DAY_FILE, $SESSION_FILE, $TIMER_FILE, $LOG_FILE,
    $PROGRESS_FILE, $POINTS_FILE, $MESSAGE_FILE, $NEXT_FILE,
    $OVERLAY_FILE, $THEME_FILE) = ('') x 11;

my $SESSION_TEXT = '';
my $REMAINING_STR = '00:00:00';
my $PCT = 0;
my $NEXT_TEXT = '';
my $MESSAGE_TEXT = '';
my $LAST_DAY = '';
my $STATE_READY = 0;
my $STATE_FINALIZED = 0;
my $IN_CLEANUP = 0;

# Phase state
my ($PHASE_LABEL, $PHASE_SUBTITLE, $PHASE_NEXT) = ('', '', '');
my ($PHASE_TOTAL, $PHASE_ELAPSED, $PHASE_PAUSED, $PHASE_SKIPPED) = (0, 0, 0, 0);
my ($PHASE_START, $PHASE_PAUSED_TOTAL, $PHASE_PAUSE_AT) = (0, 0, 0);

# Keyboard
my $STDIN_IS_TTY = 0;
my $TERM_SAVED = '';
my $KEY = '';
my $KEY_READ = 0;
my $PENDING_EXIT;      # set by cleanup(); the wait loops exit on it
my $IN_SIGNAL = 0;

sub now_seconds {
    return int(time() - $START_TIME);
}

# Exit with the code cleanup() was asked for. Exiting from *normal* context
# keeps the code even with END blocks present (see language-notes.md).
sub check_pending_exit {
    return unless defined $PENDING_EXIT;
    my $c = $PENDING_EXIT;
    $PENDING_EXIT = undef;
    # Raw syscall exit: perl 5.40 swallows exit() in signal-contaminated
    # contexts. Cleanup already ran (files reset, terminal restored, output
    # flushed), so the END block has nothing left to do here.
    _exit $c;
}

sub out { print STDOUT @_; }
sub err_m { print STDERR @_; }
$| = 1;   # unbuffered stdout, like bash's printf writes

# ---------------------------------------------------------------------------
# Themes
# ---------------------------------------------------------------------------
sub set_theme {
    my ($i) = @_;
    return 0 if $i < 0 || $i >= scalar @THEME_NAMES;
    $THEME_INDEX = $i;
    $THEME_NAME = $THEME_NAMES[$i];
    $PRIMARY = $THEME_PRIMARY[$i];
    $SECONDARY = $THEME_SECONDARY[$i];
    return 1;
}

sub theme_index {
    my ($want) = @_;
    return -1 unless defined $want && $want ne '';
    $want = lc $want;
    for my $i (0 .. $#THEME_NAMES) {
        return $i if lc($THEME_NAMES[$i]) eq $want;
    }
    return -1;
}

sub save_theme {
    return unless $THEME_FILE;
    open my $fh, '>', $THEME_FILE or return;
    print $fh "$THEME_NAME\n";
    close $fh;
}

sub cycle_theme {
    set_theme(($THEME_INDEX + 1) % scalar @THEME_NAMES);
    save_theme();
    $THEME_NOTICE_UNTIL = now_seconds() + 3;
    log_event("Theme changed to: $THEME_NAME");
}

sub list_themes {
    for my $i (0 .. $#THEME_NAMES) {
        out(sprintf("  %-8s %s%s%s\n",
            $THEME_NAMES[$i], $THEME_PRIMARY[$i],
            "\x{2588}\x{2588}\x{2588}\x{2588}", $THEME_SECONDARY[$i]));
    }
}

# ---------------------------------------------------------------------------
# Help and argument parsing
# ---------------------------------------------------------------------------
sub help_text {
    return <<"EOT";
Usage: $PROG [options] <rounds> <study_minutes> <break_minutes>

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
  $PROG 5 50 10           # 5 rounds, 50 min study, 10 min break
  $PROG --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
  $PROG --theme Ocean 5 50 10

Keys (while a phase is running):
  p / space   pause and resume the current phase
  s           skip the rest of the current phase
  q           quit the session
  Alt+T       switch to the next color theme

Environment overrides:
  ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

Config file (first one that exists):
  --config FILE | \$OBS_PANEL_CONFIG | \$XDG_CONFIG_HOME/obs-study-panel/config
EOT
}

sub print_help {
    my ($code, $to_stderr) = @_;
    if ($to_stderr) { err_m(help_text()); }
    else            { out(help_text()); }
    exit $code;
}

sub usage_error { print_help(1, 1); }

sub parse_args {
    my @args = @_;
    my @pos;
    while (@args) {
        my $a = $args[0];
        if ($a eq '-h' || $a eq '--help') {
            print_help(0, 0);
        } elsif ($a eq '-c' || $a eq '--config') {
            if (@args < 2) { err_m("Error: $a needs a file argument\n"); usage_error(); }
            $CONFIG_FILE = $args[1]; splice @args, 0, 2;
        } elsif ($a eq '-d' || $a eq '--dry-run') {
            $DRY_RUN = 1; shift @args;
        } elsif ($a eq '-n' || $a eq '--no-alert') {
            $USE_ALERT = 0; shift @args;
        } elsif ($a eq '-s' || $a eq '--no-sink') {
            $USE_SINK = 0; shift @args;
        } elsif ($a eq '-t' || $a eq '--theme') {
            if (@args < 2) { err_m("Error: $a needs a theme name\n"); usage_error(); }
            $CLI_THEME = $args[1]; splice @args, 0, 2;
        } elsif ($a eq '--list-themes') {
            list_themes(); exit 0;
        } elsif ($a eq '--') {
            shift @args; push @pos, @args; last;
        } elsif ($a =~ /^-/) {
            err_m("Error: unknown option: $a\n"); usage_error();
        } else {
            push @pos, @args; last;
        }
    }
    if (@pos != 3) { usage_error(); }
    for my $v (@pos) {
        usage_error() unless $v =~ /^[1-9][0-9]{0,3}$/;
    }
    ($ROUNDS, $STUDY_MIN, $BREAK_MIN) = map { int } @pos;
    if ($ROUNDS > 50)    { err_m("Error: rounds must be <= 50\n"); usage_error(); }
    if ($STUDY_MIN > 600){ err_m("Error: study minutes must be <= 600\n"); usage_error(); }
    if ($BREAK_MIN > 120){ err_m("Error: break minutes must be <= 120\n"); usage_error(); }

    if ($DRY_RUN) {
        $DURATION_UNIT = 'seconds';
        $SECONDS_PER_UNIT = 1;
    }
}

# ---------------------------------------------------------------------------
# Configuration file
# ---------------------------------------------------------------------------
# The config file is bash source code (exactly like the reference). It is
# interpreted by a child bash that first seeds the pre-config default knobs,
# sources the file, and then dumps the resulting values: unit separator
# 0x1F between key and value, record separator 0x1E between records. A
# sourced file that calls `exit N` terminates the child before the dump is
# written, which this program detects and mirrors.
my $CONFIG_DUMP_SH = <<'EOSH';
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
EOSH

sub find_config_file {
    return $CONFIG_FILE if $CONFIG_FILE ne '';
    return $ENV{OBS_PANEL_CONFIG} if defined $ENV{OBS_PANEL_CONFIG} && $ENV{OBS_PANEL_CONFIG} ne '';
    my $xdg_base = (defined $ENV{XDG_CONFIG_HOME} && $ENV{XDG_CONFIG_HOME} ne '')
        ? $ENV{XDG_CONFIG_HOME} : ((defined $ENV{HOME} ? $ENV{HOME} : '') . '/.config');
    my $xdg = "$xdg_base/obs-study-panel/config";
    return $xdg if -f $xdg;
    my $local_cfg = "$DIR/obs-panel.conf";
    return $local_cfg if -f $local_cfg;
    return '';
}

sub quotes_to_list {
    my ($raw) = @_;
    @QUOTE_LIST = ();
    for my $line (split /\n/, $raw) {
        $line =~ s/\r+$//;
        push @QUOTE_LIST, $line if $line ne '';
    }
}

sub parse_int_safe {
    my ($v, $dflt) = @_;
    $v = '' unless defined $v;
    return $v =~ /^\s*([+-]?\d+)\s*$/ ? $1 + 0 : $dflt;
}

sub load_config {
    my ($path) = @_;
    if (!-r $path) {
        err_m("Error: config file is not readable: $path\n");
        exit 1;
    }
    # Syntax check up front, exactly like the reference.
    my $rc = system('bash', '-n', $path);
    if ($rc != 0) {
        err_m("Error: syntax error in config file: $path\n");
        my $err = `bash -n "$path" 2>&1`;
        my @lines = grep { /\S/ } split /\n/, $err;
        err_m("$_\n") for @lines[0 .. ($#lines > 2 ? 2 : $#lines)];
        exit 1;
    }

    my $dump_path = "/tmp/obs-panel-conf-$$-" . int(rand(1_000_000));
    open my $dfh, '>', $dump_path; close $dfh;
    local %ENV = %ENV;
    # Seed the pre-config defaults, exactly what the reference holds while
    # it sources the file (the real environment's THEME/QUOTES pass through).
    $ENV{ALERT_SOUND} = $ALERT_SOUND;
    $ENV{SINK_NAME} = $SINK_NAME;
    $ENV{STATE_DIR} = '';
    $ENV{MAX_LOG_BYTES} = '1048576';
    $ENV{FILE_BAR_WIDTH} = '20';
    $ENV{NON_TTY_ENTER_TIMEOUT} = '300';
    $ENV{POINTS} = "$POINTS";
    $ENV{LAST_DATE} = $LAST_DATE;
    $ENV{QUOTES_SEED} = join("\x1f", @QUOTE_LIST);
    my $c_rc = system('bash', '-c', $CONFIG_DUMP_SH, 'obs-panel', $path, $dump_path);
    my $c_code = $c_rc >> 8;
    my $raw = '';
    my $rfh;
    if (open $rfh, '<', $dump_path) {
        local $/;
        $raw = <$rfh> // '';
        close $rfh;
    }
    unlink $dump_path;

    if ($raw eq '') {
        # The config called exit N before the dump was written.
        exit($c_code != 0 ? $c_code : 1);
    }

    my %values;
    my @quotes;
    for my $record (split /\x1e/, $raw) {
        next if $record eq '';
        my ($key, $value) = split /\x1f/, $record, 2;
        $value = '' unless defined $value;
        if ($key eq 'QUOTE') { push @quotes, $value; }
        else { $values{$key} = $value; }
    }

    $ALERT_SOUND = exists $values{ALERT_SOUND} ? $values{ALERT_SOUND} : $ALERT_SOUND;
    $SINK_NAME   = exists $values{SINK_NAME} ? $values{SINK_NAME} : $SINK_NAME;
    $STATE_DIR   = exists $values{STATE_DIR} ? $values{STATE_DIR} : '';
    $MAX_LOG_BYTES = exists $values{MAX_LOG_BYTES} ? $values{MAX_LOG_BYTES} : '1048576';
    $FILE_BAR_WIDTH = exists $values{FILE_BAR_WIDTH} ? $values{FILE_BAR_WIDTH} : '20';
    $NON_TTY_ENTER_TIMEOUT =
        exists $values{NON_TTY_ENTER_TIMEOUT} ? $values{NON_TTY_ENTER_TIMEOUT} : '300';
    $CONFIG_THEME = $values{THEME} // '';
    $POINTS = parse_int_safe($values{POINTS}, 0);
    $LAST_DATE = $values{LAST_DATE} // '';
    $CONFIG_QUOTES = $values{QUOTES} // '';
    # Zero QUOTE records means the config emptied the list: the seeded
    # defaults would have been dumped otherwise.
    @QUOTE_LIST = @quotes;
    $CONFIG_LOADED = $path;
}

sub apply_quote_sources {
    if ($ENV_QUOTES ne '')        { quotes_to_list($ENV_QUOTES); }
    elsif ($CONFIG_QUOTES ne '')   { quotes_to_list($CONFIG_QUOTES); }
}

sub sanity_knobs {
    if ($MAX_LOG_BYTES !~ /^\d+$/ || $MAX_LOG_BYTES <= 0) {
        $MAX_LOG_BYTES = 1048576;
    } else {
        $MAX_LOG_BYTES = $MAX_LOG_BYTES + 0;
    }
    if ($FILE_BAR_WIDTH !~ /^\d+$/ || $FILE_BAR_WIDTH <= 0 || $FILE_BAR_WIDTH > 200) {
        $FILE_BAR_WIDTH = 20;
    } else {
        $FILE_BAR_WIDTH = $FILE_BAR_WIDTH + 0;
    }
    if ($NON_TTY_ENTER_TIMEOUT !~ /^\d+$/
        || $NON_TTY_ENTER_TIMEOUT <= 0 || $NON_TTY_ENTER_TIMEOUT > 3600) {
        $NON_TTY_ENTER_TIMEOUT = 300;
    } else {
        $NON_TTY_ENTER_TIMEOUT = $NON_TTY_ENTER_TIMEOUT + 0;
    }
}

# ---------------------------------------------------------------------------
# Paths and theme selection
# ---------------------------------------------------------------------------
sub setup_paths {
    $STATE_DIR = $DIR if $STATE_DIR eq '';
    unless (-d $STATE_DIR) {
        eval { make_path($STATE_DIR); 1 } or do {
            err_m("Error: cannot create state dir: $STATE_DIR\n");
            exit 1;
        };
    }
    $DATE_FILE     = "$STATE_DIR/date.txt";
    $DAY_FILE      = "$STATE_DIR/day.txt";
    $SESSION_FILE  = "$STATE_DIR/session.txt";
    $TIMER_FILE    = "$STATE_DIR/timer.txt";
    $LOG_FILE      = "$STATE_DIR/log.txt";
    $PROGRESS_FILE = "$STATE_DIR/progress.txt";
    $POINTS_FILE   = "$STATE_DIR/points.txt";
    $MESSAGE_FILE   = "$STATE_DIR/message.txt";
    $NEXT_FILE     = "$STATE_DIR/next.txt";
    $OVERLAY_FILE  = "$STATE_DIR/overlay.txt";
    $THEME_FILE    = "$STATE_DIR/theme.txt";
}

sub select_theme {
    my $request = $CLI_THEME;
    $request = $ENV_THEME if $request eq '' && $ENV_THEME ne '';
    $request = $CONFIG_THEME if $request eq '' && $CONFIG_THEME ne '';
    if ($request eq '' && -f $THEME_FILE) {
        open my $fh, '<', $THEME_FILE;
        if ($fh) { $request = <$fh> // ''; close $fh; chomp $request; }
    }
    if ($request ne '') {
        my $idx = theme_index($request);
        if ($idx < 0) {
            err_m("Warning: unknown theme '$request', using $THEME_NAME\n");
        } else {
            set_theme($idx);
        }
    }
}

# ---------------------------------------------------------------------------
# OBS state files
# ---------------------------------------------------------------------------
sub write_state {
    my ($path, $text) = @_;
    open my $fh, '>', $path or return;
    print $fh "$text\n";
    close $fh;
}

sub update_date_day {
    my $d = strftime('%Y-%m-%d', localtime);
    return if $d eq $LAST_DATE;
    $LAST_DATE = $d;
    $LAST_DAY = strftime('%A', localtime);
    write_state($DATE_FILE, $d);
    write_state($DAY_FILE, $LAST_DAY);
}

sub sync_state {
    update_date_day();
    publish_state();
}

sub make_bar {
    my ($filled, $width, $fill, $empty, $head) = @_;
    $head = '' unless defined $head;
    my $bar = '';
    for my $i (0 .. $width - 1) {
        if ($i < $filled) {
            $bar .= ($head ne '' && $i == $filled - 1) ? $head : $fill;
        } else {
            $bar .= $empty;
        }
    }
    return $bar;
}

sub publish_state {
    my $filled = int($PCT * $FILE_BAR_WIDTH / 100);
    my $bar = make_bar($filled, $FILE_BAR_WIDTH, '#', '-');
    my $pct_s = sprintf('%3d%%', $PCT);
    write_state($SESSION_FILE, $SESSION_TEXT);
    write_state($TIMER_FILE, $REMAINING_STR);
    write_state($POINTS_FILE, $POINTS);
    write_state($NEXT_FILE, $NEXT_TEXT);
    write_state($MESSAGE_FILE, $MESSAGE_TEXT);
    write_state($PROGRESS_FILE, "[$bar] $pct_s");
    my @overlay = ("$LAST_DATE $LAST_DAY", $SESSION_TEXT, $REMAINING_STR,
                   "[$bar] $pct_s", "Pts: $POINTS", "Next: $NEXT_TEXT");
    push @overlay, $MESSAGE_TEXT if $MESSAGE_TEXT ne '';
    open my $fh, '>', $OVERLAY_FILE or return;
    print $fh join("\n", @overlay), "\n";
    close $fh;
}

sub rotate_log_if_needed {
    my $size;
    if (-f $LOG_FILE) {
        $size = -s $LOG_FILE;
        if (defined $size && $size >= $MAX_LOG_BYTES) {
            return unless rename($LOG_FILE, "$LOG_FILE.1");
            open my $fh, '>', $LOG_FILE; close $fh;
        }
    }
}

sub log_event {
    my ($msg) = @_;
    rotate_log_if_needed();
    open my $fh, '>>', $LOG_FILE or return;
    print $fh '[', strftime('%Y-%m-%d %H:%M:%S', localtime), "] $msg\n";
    close $fh;
}

# ---------------------------------------------------------------------------
# Audio alerts
# ---------------------------------------------------------------------------
sub which {
    my ($cmd) = @_;
    return system("command -v \Q$cmd\E >/dev/null 2>&1") == 0 ? 1 : 0;
}

sub sink_is_ready {
    return 0 unless which('pactl');
    open my $fh, '-|', 'pactl', 'list', 'short', 'sinks';
    return 0 unless $fh;
    while (my $line = <$fh>) {
        my @f = split ' ', $line;
        if (@f > 1 && $f[1] eq $SINK_NAME) { close $fh; return 1; }
    }
    close $fh;
    return 0;
}

sub setup_audio_sink {
    return unless $USE_SINK;
    return unless which('pactl');
    return if sink_is_ready();
    system("pactl load-module module-null-sink sink_name=\Q$SINK_NAME\E sink_properties=device.description=\Q$SINK_NAME\E >/dev/null 2>&1");
}

sub stop_alert {
    if ($ALERT_PID > 0) {
        kill 'TERM', $ALERT_PID;
        $ALERT_PID = 0;
    }
}

sub play_alert {
    return unless $USE_ALERT;
    stop_alert();
    if ($ALERT_SOUND eq '' || !-f $ALERT_SOUND) {
        my $shown = $ALERT_SOUND ne '' ? $ALERT_SOUND : 'none';
        out("$DIM(alert file not found: $shown)$NC\n");
        return;
    }

    my @player;
    if    (which('mpv'))    { @player = qw(mpv --no-video --volume=70); }
    elsif (which('paplay')) { @player = qw(paplay); }
    elsif (which('ffplay')) { @player = qw(ffplay -nodisp -autoexit); }
    elsif (which('cvlc'))   { @player = qw(cvlc --play-and-exit --no-video --volume=70); }
    else {
        out("$DIM(no audio player found - install mpv / paplay / ffplay)$NC\n");
        return;
    }

    setup_audio_sink() if $USE_SINK && !sink_is_ready();

    my $pid = fork();
    if (!defined $pid) { return; }
    if ($pid == 0) {
        # child: detach, silence output, route through the sink when ready.
        # Guards: never run the END hook from the player child.
        $STATE_READY = 0;
        $STATE_FINALIZED = 1;
        if ($USE_SINK && sink_is_ready()) {
            $ENV{PULSE_SINK} = $SINK_NAME;
        }
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec @player, $ALERT_SOUND;
        exit 1;
    }
    $ALERT_PID = $pid;
    if ($USE_SINK && sink_is_ready()) {
        out("$DIM-> alert on OBS sink ($SINK_NAME)$NC\n");
    } else {
        out("$SECONDARY-> alert on default device (OBS sink unavailable)$NC\n");
    }
}

# ---------------------------------------------------------------------------
# Keyboard input
# ---------------------------------------------------------------------------
sub setup_terminal {
    $STDIN_IS_TTY = -t STDIN ? 1 : 0;
    return unless $STDIN_IS_TTY;
    # Save settings (stty -g), then switch to no-echo character mode.
    my $saved = `stty -g < /dev/tty 2>/dev/null`;
    chomp $saved;
    $TERM_SAVED = $saved;
    system("stty -icanon -echo < /dev/tty 2>/dev/null");
}

sub restore_terminal {
    return unless $STDIN_IS_TTY;
    if ($TERM_SAVED ne '') {
        system("stty $TERM_SAVED < /dev/tty 2>/dev/null");
    } else {
        system("stty sane < /dev/tty 2>/dev/null");
    }
}

# One byte with a timeout (seconds, may be fractional).
# Returns: byte string | undef on timeout | '' on EOF.
sub read_byte_timeout {
    my ($timeout) = @_;
    my $sel = IO::Select->new(\*STDIN);
    my @ready = $sel->can_read($timeout);
    return undef unless @ready;
    my $buf;
    my $n = sysread STDIN, $buf, 1;
    return '' if !defined $n || $n == 0;   # EOF
    return $buf;
}

sub wait_key {
    my ($timeout) = @_;
    $KEY = '';
    $KEY_READ = 0;
    unless ($STDIN_IS_TTY) {
        sleep $timeout;
        check_pending_exit();
        return;
    }
    my $b = read_byte_timeout($timeout);
    check_pending_exit();
    return if !defined $b || $b eq '';
    $KEY_READ = 1;
    if ($b eq "\x1b") {
        $KEY = '';
        my $nxt = read_byte_timeout(0.3);
        $KEY = 'alt-t' if defined $nxt && ($nxt eq 't' || $nxt eq 'T');
    } else {
        $KEY = $b;
    }
}

sub discard_pending_input {
    return unless $STDIN_IS_TTY;
    while (1) {
        my $b = read_byte_timeout(0.01);
        last if !defined $b || $b eq '';
    }
}

sub wait_for_enter {
    if ($STDIN_IS_TTY) {
        while (1) {
            my $b = read_byte_timeout(1);
            check_pending_exit();
            if (!defined $b) { update_date_day(); next; }
            return if $b eq '' || $b eq "\n";
        }
    }
    my $waited = 0;
    while ($waited < $NON_TTY_ENTER_TIMEOUT) {
        my $slice_end = time() + 5;
        while (1) {
            my $remaining = $slice_end - time();
            if ($remaining <= 0) { $waited += 5; last; }
            my $b = read_byte_timeout($remaining);
            check_pending_exit();
            return if defined $b && $b eq '';       # EOF
            if (!defined $b) { $waited += 5; last; } # slice timeout
            return if $b eq "\n";                    # complete line
            # partial line: keep consuming within this slice
        }
    }
}

# ---------------------------------------------------------------------------
# Status / progress UI
# ---------------------------------------------------------------------------
my $TERM_BAR_WIDTH = 24;
my $BOX_INNER = 62;

sub phase_color {
    my ($label) = @_;
    return $label eq 'STUDY' ? $PRIMARY : $SECONDARY;
}

sub draw_status {
    my ($label, $round, $total_rounds, $elapsed, $total, $paused) = @_;
    my $filled = 0;
    $filled = int($elapsed * $TERM_BAR_WIDTH / $total) if $total > 0;
    $filled = $TERM_BAR_WIDTH if $filled > $TERM_BAR_WIDTH;
    my $bar = make_bar($filled, $TERM_BAR_WIDTH, '=', ' ', '>');
    my $color = phase_color($label);
    my $flag = '';
    $flag = "$PRIMARY PAUSED$NC" if $paused;
    $flag .= "  $DIM" . "Theme: $THEME_NAME$NC" if now_seconds() < $THEME_NOTICE_UNTIL;
    print "\r\x1b[K";
    out(sprintf("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
        $BOLD, $color, $label, $NC, $round, $total_rounds,
        $color, $bar, $NC, $PCT, $REMAINING_STR, $PRIMARY, $POINTS, $NC, $flag));
}

sub box_row {
    my ($color, $plain, $styled) = @_;
    my $pad = $BOX_INNER - length $plain;
    $pad = 0 if $pad < 0;
    out("$color\x{2551}$styled" . (' ' x $pad) . "$color\x{2551}$NC\n");
}

sub duration_label {
    my ($n) = @_;
    if ($n == 1) {
        return $DURATION_UNIT eq 'seconds' ? '1 second' : '1 minute';
    }
    return "$n $DURATION_UNIT";
}

sub rounds_label {
    my ($n) = @_;
    return $n == 1 ? '1 round' : "$n rounds";
}

sub phase_header {
    my ($label, $round, $total, $minutes, $subtitle) = @_;
    $subtitle = substr($subtitle, 0, $BOX_INNER - 4) if length($subtitle) > $BOX_INNER - 4;
    my $color = phase_color($label);
    my $bar = "\x{2550}" x $BOX_INNER;
    my $info = "$label  \x{b7}  Round $round / $total  \x{b7}  " . duration_label($minutes);
    out("\n");
    out("$color\x{2554}$bar\x{2557}$NC\n");
    box_row($color, "  $info",
        "  $BOLD$label$NC$color  \x{b7}  Round $round / $total  \x{b7}  " . duration_label($minutes));
    box_row($color, "  $subtitle", "  $DIM$subtitle$NC$color");
    if ($STDIN_IS_TTY) {
        my $keys = "  p pause  \x{b7}  s skip  \x{b7}  q quit  \x{b7}  Alt+T theme";
        box_row($color, $keys, "$DIM$keys$NC$color");
    }
    out("$color\x{255a}$bar\x{255d}$NC\n");
    out("\n");
}

sub show_completion {
    my ($phase, $round, $total_rounds, $next_phase, $skipped) = @_;
    my $width = 60;
    my $line = '=' x $width;
    my $title;
    if ($skipped)       { $title = 'PHASE SKIPPED'; }
    elsif ($phase eq 'STUDY') { $title = 'STUDY SESSION COMPLETE'; }
    else                { $title = 'BREAK COMPLETE'; }
    my $color = phase_color($phase);
    out("\n");
    out("$color$line$NC\n");
    out($color . (' ' x int(($width + length $title) / 2)) . "$title$NC\n");
    out("$color$line$NC\n");
    out("\n");
    out("  Round:   $BOLD$round$NC / $total_rounds\n");
    out("  Points:  $PRIMARY$POINTS$NC\n");
    out("\n");
    if ($next_phase eq 'None') {
        out("  Next:    $DIM" . "Session complete$NC\n");
    } else {
        out("  Next:    $BOLD$next_phase$NC\n");
    }
    out("\n");
    out("  $PRIMARY" . "Press Enter to continue...$NC");
}

# ---------------------------------------------------------------------------
# Phase runner
# ---------------------------------------------------------------------------
sub fmt_hms {
    my ($total) = @_;
    return sprintf('%02d:%02d:%02d',
        int($total / 3600), int($total % 3600 / 60), $total % 60);
}

sub phase_prepare {
    my ($ptype, $minutes, $round, $total_rounds) = @_;
    if ($ptype eq 'study') {
        $PHASE_LABEL = 'STUDY';
        $PHASE_SUBTITLE = @QUOTE_LIST
            ? $QUOTE_LIST[int(rand(scalar @QUOTE_LIST))] : 'Stay focused.';
    } else {
        $PHASE_LABEL = 'BREAK';
        $PHASE_SUBTITLE = 'Relax and recharge.';
    }

    if ($ptype eq 'study') {
        $PHASE_NEXT = $round < $total_rounds
            ? 'Break (' . duration_label($BREAK_MIN) . ')' : 'None';
    } else {
        $PHASE_NEXT = 'Study (' . duration_label($STUDY_MIN) . ')';
    }

    $PHASE_TOTAL = $minutes * $SECONDS_PER_UNIT;
    $PHASE_ELAPSED = 0;
    $PHASE_PAUSED = 0;
    $PHASE_SKIPPED = 0;
    $PHASE_START = now_seconds();
    $PHASE_PAUSED_TOTAL = 0;
    $PHASE_PAUSE_AT = 0;

    $SESSION_TEXT = "$PHASE_LABEL $round/$total_rounds";
    $REMAINING_STR = fmt_hms($PHASE_TOTAL);
    $PCT = 0;
    $NEXT_TEXT = $PHASE_NEXT eq 'None' ? 'Session complete' : $PHASE_NEXT;
    $MESSAGE_TEXT = $PHASE_SUBTITLE;

    log_event("Start: $PHASE_LABEL $round/$total_rounds (" . duration_label($minutes) . ")");
    phase_header($PHASE_LABEL, $round, $total_rounds, $minutes, $PHASE_SUBTITLE);
    sync_state();
}

sub phase_handle_key {
    my ($round, $total_rounds) = @_;
    if ($KEY eq 'p' || $KEY eq 'P' || $KEY eq ' ') {
        if ($PHASE_PAUSED) {
            $PHASE_PAUSED_TOTAL += now_seconds() - $PHASE_PAUSE_AT;
            $PHASE_PAUSED = 0;
            log_event("Resumed: $PHASE_LABEL $round/$total_rounds");
        } else {
            $PHASE_PAUSED = 1;
            $PHASE_PAUSE_AT = now_seconds();
            log_event("Paused: $PHASE_LABEL $round/$total_rounds");
        }
    } elsif ($KEY eq 's' || $KEY eq 'S') {
        $PHASE_SKIPPED = 1;
        log_event("Skipped: $PHASE_LABEL $round/$total_rounds");
    } elsif ($KEY eq 'q' || $KEY eq 'Q') {
        log_event("Quit requested by user");
        cleanup(0);
    } elsif ($KEY eq 'alt-t') {
        cycle_theme();
    }
}

sub phase_count {
    my ($round, $total_rounds) = @_;
    while ($PHASE_ELAPSED < $PHASE_TOTAL) {
        check_pending_exit();
        my $remaining = $PHASE_TOTAL - $PHASE_ELAPSED;
        $remaining = 0 if $remaining < 0;
        $REMAINING_STR = fmt_hms($remaining);
        $PCT = $PHASE_TOTAL > 0 ? int($PHASE_ELAPSED * 100 / $PHASE_TOTAL) : 0;
        $PCT = 100 if $PCT > 100;
        $SESSION_TEXT = "$PHASE_LABEL $round/$total_rounds";
        $SESSION_TEXT .= ' (PAUSED)' if $PHASE_PAUSED;

        sync_state();
        draw_status($PHASE_LABEL, $round, $total_rounds,
                    $PHASE_ELAPSED, $PHASE_TOTAL, $PHASE_PAUSED);

        wait_key(1);
        if ($KEY_READ) {
            phase_handle_key($round, $total_rounds);
            last if $PHASE_SKIPPED;
        }
        # CRASH-INJECT-POINT
        if (!$PHASE_PAUSED) {
            $PHASE_ELAPSED = now_seconds() - $PHASE_START - $PHASE_PAUSED_TOTAL;
        }
    }
}

sub phase_finish {
    my ($round, $total_rounds) = @_;
    if ($PHASE_SKIPPED) {
        $SESSION_TEXT = "$PHASE_LABEL $round/$total_rounds (SKIPPED)";
    } else {
        $PCT = 100;
        $POINTS += 1;
    }
    $REMAINING_STR = '00:00:00';
    sync_state();
    draw_status($PHASE_LABEL, $round, $total_rounds,
                $PHASE_ELAPSED, $PHASE_TOTAL, 0);
    out("\n");
    log_event("End: $PHASE_LABEL $round/$total_rounds");

    play_alert();

    discard_pending_input();
    show_completion($PHASE_LABEL, $round, $total_rounds,
                    $PHASE_NEXT, $PHASE_SKIPPED);
    wait_for_enter();
    stop_alert();
    out("\n");
}

sub run_phase {
    my ($ptype, $minutes, $round, $total_rounds) = @_;
    phase_prepare($ptype, $minutes, $round, $total_rounds);
    phase_count($round, $total_rounds);
    phase_finish($round, $total_rounds);
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
sub reset_state_files {
    $SESSION_TEXT = 'stopped';
    $REMAINING_STR = '00:00:00';
    $PCT = 0;
    $NEXT_TEXT = '';
    sync_state();
}

sub cleanup {
    my ($code) = @_;
    return if $IN_CLEANUP;
    $IN_CLEANUP = 1;
    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = 'IGNORE';
    $STATE_FINALIZED = 1;
    stop_alert();
    eval { reset_state_files(); };
    eval { log_event('Protocol stopped manually'); };
    eval {
        out("\n");
        out("$SECONDARY$BOLD" . "Interrupted.$NC $DIM" . "State files reset to stopped.$NC\n");
    };
    restore_terminal();
    if ($IN_SIGNAL) {
        # Exit from the interrupted (normal) context instead of from inside
        # the signal handler: on Perl 5.40+ exit() inside a handler loses
        # its exit code when END blocks exist.
        $PENDING_EXIT = $code;
        return;
    }
    exit $code;
}

sub on_unexpected_death {
    my ($rc) = @_;
    return unless $STATE_READY;
    return if $STATE_FINALIZED;
    $STATE_FINALIZED = 1;
    stop_alert();
    eval { reset_state_files(); };
    eval { log_event("Protocol ended unexpectedly (exit $rc)"); };
}

# The EXIT-trap equivalent: resets the state files after an unexpected
# death (die / exit N before the session finalized) and restores the
# terminal. On Perl 5.40+ $? is localized inside END blocks, so the
# process exit code is preserved without any extra work; on older perls
# the system() call in restore_terminal could clobber it, so $? is
# saved and restored explicitly.
END {
    my $saved = $?;
    my $rc = $saved & 127 ? $saved : ($saved == 0 ? 0 : $saved >> 8);
    on_unexpected_death($rc);
    restore_terminal();
    local $? = 0;                 # silence void-context warnings only
    $? = $saved if $] < 5.040;    # older perls: put the exit code back
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
sub finalize_session {
    $SESSION_TEXT = 'session complete';
    $REMAINING_STR = '00:00:00';
    $PCT = 100;
    $NEXT_TEXT = '';
    sync_state();
    $STATE_FINALIZED = 1;
    log_event("Protocol complete - total points: $POINTS");
}

sub final_banner {
    my $banner_width = 60;
    my $title = 'ALL SESSIONS COMPLETE';
    my $inner = $banner_width - 2;
    my $pad = int(($inner - length $title) / 2);
    my $border = '#' x $banner_width;
    out("\n");
    out("$PRIMARY$border$NC\n");
    out("$PRIMARY#$NC" . (' ' x $pad) . "$BOLD$title"
        . (' ' x ($inner - $pad - length $title)) . "$NC#$PRIMARY\n");
    out("$PRIMARY$border$NC\n");
    out("\n");
    out("  $BOLD" . "Total Rounds:$NC  $PRIMARY$ROUNDS$NC\n");
    out("  $BOLD" . "Total Points:$NC $PRIMARY$POINTS$NC\n");
    out("\n");
    out("$PRIMARY$BOLD" . "Great work!$NC $DIM" . "Exiting.$NC\n");
}

sub print_logo {
    out("$PRIMARY\n");
    out("$LOGO\n");
    out("$NC\n");
    out("$PRIMARY$BOLD" . "     Study / Break Timer Protocol$NC\n");
    out("$DIM" . "\x{2500}\x{2500} live state written to date \x{b7} day \x{b7} session \x{b7} timer \x{b7} log$NC\n");
    out("\n");
}

# Signal handling: conventional exit codes 128 + signal number. The work
# happens inside cleanup(); the process exit is deferred to the interrupted
# wait loop so the exit code survives (Perl 5.40 + END quirk, see above).
$SIG{INT}  = sub { $IN_SIGNAL = 1; cleanup(130); $IN_SIGNAL = 0 };
$SIG{TERM} = sub { $IN_SIGNAL = 1; cleanup(143); $IN_SIGNAL = 0 };
$SIG{HUP}  = sub { $IN_SIGNAL = 1; cleanup(129); $IN_SIGNAL = 0 };

parse_args(@ARGV);

my $cfg = find_config_file();
load_config($cfg) if $cfg ne '';

# Environment variables beat the config file.
$ALERT_SOUND   = $ENV_ALERT_SOUND   if $ENV_ALERT_SOUND ne '';
$SINK_NAME     = $ENV_SINK_NAME     if $ENV_SINK_NAME ne '';
$STATE_DIR     = $ENV_STATE_DIR     if $ENV_STATE_DIR ne '';
$MAX_LOG_BYTES = $ENV_MAX_LOG_BYTES if $ENV_MAX_LOG_BYTES ne '';

apply_quote_sources();
sanity_knobs();

setup_paths();
select_theme();
setup_terminal();

print_logo();
setup_audio_sink();
update_date_day();
# From here on the state files may be written (and have to be reset if the
# program dies unexpectedly).
$STATE_READY = 1;
log_event('Starting new study protocol: ' . rounds_label($ROUNDS)
    . ', ' . duration_label($STUDY_MIN) . ' study, '
    . duration_label($BREAK_MIN) . ' break');

out("$SECONDARY" . "Protocol:$NC $BOLD" . rounds_label($ROUNDS)
    . "$NC  $DIM|$NC  $BOLD" . duration_label($STUDY_MIN)
    . "$NC study  $DIM|$NC  $BOLD" . duration_label($BREAK_MIN)
    . "$NC break  $DIM|$NC  $BOLD" . "Theme: $THEME_NAME$NC\n");
out("$DIM" . "Config: $CONFIG_LOADED$NC\n") if $CONFIG_LOADED ne '';
out("\n");

for my $round (1 .. $ROUNDS) {
    run_phase('study', $STUDY_MIN, $round, $ROUNDS);
    run_phase('break', $BREAK_MIN, $round, $ROUNDS) if $round < $ROUNDS;
}

finalize_session();
final_banner();
exit 0;
