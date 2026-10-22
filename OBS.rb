#!/usr/bin/env ruby
#
# OBS.rb - Study/break timer protocol (Ruby port of OBS.sh)
#
# Writes live state to text files (date.txt, day.txt, session.txt, timer.txt,
# progress.txt, points.txt, message.txt, next.txt, overlay.txt, log.txt) for
# use as Text sources in OBS Studio. OBS.sh is the reference implementation;
# see docs/port-spec.md for the behavior contract and README.md for usage.
#
# Requirements: Ruby 3.0+ (standard library only), bash (to load the
# bash-syntax config file).
#
# Usage:   ./OBS.rb [options] <rounds> <study_minutes> <break_minutes>
# Example: ./OBS.rb 5 50 10            ->  5 rounds, 50 min study, 10 min break
#          ./OBS.rb --dry-run 3 5 2    ->  3 rounds, 5 s study, 2 s break
# Stop:    Ctrl+C, or press 'q' while a phase is running
# Theme:   press Alt+T while a phase is running (see --list-themes)
#

require 'English'

# ---------------------------------------------------------------------------
# Color themes
# ---------------------------------------------------------------------------
THEME_NAMES  = %w[Purple Ocean Forest Sunset Rose Gold
                 Mono Ice Ember Neon Cobalt Cherry].freeze
THEME_PRIMARY = ["\e[1;35m", "\e[1;36m", "\e[1;32m", "\e[1;33m", "\e[1;95m", "\e[1;93m", "\e[1;37m", "\e[1;96m", "\e[1;91m", "\e[1;92m", "\e[1;34m", "\e[1;91m"].freeze
THEME_SECONDARY = ["\e[0;35m", "\e[0;34m", "\e[0;32m", "\e[0;31m", "\e[0;31m", "\e[0;33m", "\e[0;37m", "\e[0;36m", "\e[0;31m", "\e[0;96m", "\e[0;36m", "\e[0;35m"].freeze

BOLD = "\e[1m"
DIM  = "\e[2m"
NC   = "\e[0m"

LOGO = <<~'EOT'
   /$$$$$$$$      /$$    /$$ /$$$$$$$$ /$$   /$$
  | $$_____/     | $$   | $$| $$_____/| $$  / $$
  | $$           | $$   | $$| $$      |  $$/ $$/
  | $$$$$ /$$$$$$|  $$ / $$/| $$$$$    \  $$$$/
  | $$__/|______/ \  $$ $$/ | $$__/     >$$  $$
  | $$             \  $$$/  | $$       /$$/\  $$
  | $$$$$$$$        \  $/   | $$$$$$$$| $$  \ $$
  |________/         \_/    |________/|__/  |__/
EOT

DEFAULT_QUOTE_LIST = [
  'Focused effort beats scattered hours',
  'Every round finished is progress made',
  'Consistency beats intensity',
  'Start now, figure out the rest along the way',
  'A short break now means sharper focus next round',
].freeze

TERM_BAR_WIDTH = 24
BOX_INNER = 62
START_TIME = Time.now

# ---------------------------------------------------------------------------
# Mutable program state (mirrors the reference's global variables)
# ---------------------------------------------------------------------------
$primary = THEME_PRIMARY[0]
$secondary = THEME_SECONDARY[0]
$theme_name = THEME_NAMES[0]
$theme_index = 0
$theme_notice_until = 0

$env_alert_sound   = ENV['ALERT_SOUND'].to_s
$env_sink_name     = ENV['SINK_NAME'].to_s
$env_state_dir     = ENV['STATE_DIR'].to_s
$env_max_log_bytes = ENV['MAX_LOG_BYTES'].to_s
$env_quotes        = ENV['QUOTES'].to_s
$env_theme         = ENV['THEME'].to_s

$dir = File.expand_path(File.dirname(__FILE__))
$alert_sound = ENV['HOME'] ? File.join(ENV['HOME'], 'Videos/Alarm/n_alarm.mp3') : ''
$sink_name = 'OBS_Alert_Sink'
$state_dir = ''
$max_log_bytes = 1_048_576
$file_bar_width = 20
$non_tty_enter_timeout = 300
$alert_pid = 0
$quote_list = DEFAULT_QUOTE_LIST.dup
$points = 0
$last_date = ''

$config_file = ''
$dry_run = false
$use_alert = true
$use_sink = true
$rounds = 0
$study_min = 0
$break_min = 0
$cli_theme = ''
$duration_unit = 'minutes'
$seconds_per_unit = 60
$config_theme = ''
$config_quotes = ''
$config_loaded = ''

$date_file = nil
$day_file = nil
$session_file = nil
$timer_file = nil
$log_file = nil
$progress_file = nil
$points_file = nil
$message_file = nil
$next_file = nil
$overlay_file = nil
$theme_file = nil

$session_text = ''
$remaining_str = '00:00:00'
$pct = 0
$next_text = ''
$message_text = ''
$last_day = ''
$state_ready = false
$state_finalized = false
$in_cleanup = false

$phase_label = ''
$phase_subtitle = ''
$phase_next = ''
$phase_total = 0
$phase_elapsed = 0
$phase_paused = false
$phase_skipped = false
$phase_start = 0
$phase_paused_total = 0
$phase_pause_at = 0

$stdin_is_tty = false
$saved_term = nil
$key = ''
$key_read = false

$pending_exit = nil

$prog = File.basename($PROGRAM_NAME)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def now_seconds
  (Time.now - START_TIME).to_i
end

def set_theme(i)
  return false if i.negative? || i >= THEME_NAMES.length

  $theme_index = i
  $theme_name = THEME_NAMES[i]
  $primary = THEME_PRIMARY[i]
  $secondary = THEME_SECONDARY[i]
  true
end

def theme_index(want)
  return -1 if want.nil? || want.empty?

  w = want.downcase
  THEME_NAMES.each_with_index do |name, i|
    return i if name.downcase == w
  end
  -1
end

def save_theme
  return unless $theme_file

  begin
    File.write($theme_file, "#{$theme_name}\n")
  rescue StandardError
    # best effort
  end
end

def cycle_theme
  set_theme(($theme_index + 1) % THEME_NAMES.length)
  save_theme
  $theme_notice_until = now_seconds + 3
  log_event("Theme changed to: #{$theme_name}")
end

def print_theme_list
  THEME_NAMES.each_index do |i|
    printf("  %-8s %s%s%s%s\n", THEME_NAMES[i], THEME_PRIMARY[i],
           "\u{2588}\u{2588}\u{2588}\u{2588}", THEME_SECONDARY[i], '')
  end
end

def fmt_hms(total)
  format('%02d:%02d:%02d', total / 3600, (total % 3600) / 60, total % 60)
end

def make_bar(filled, width, fill, empty, head = '')
  bar = +''
  width.times do |i|
    if i < filled
      bar << (head.empty? || i != filled - 1 ? fill : head)
    else
      bar << empty
    end
  end
  bar
end

def which(cmd)
  path = ENV['PATH'].to_s
  return nil if path.empty?

  path.split(File::PATH_SEPARATOR).each do |dir|
    next if dir.empty?

    candidate = File.join(dir, cmd)
    return candidate if File.executable?(candidate)
  end
  nil
end

# ---------------------------------------------------------------------------
# Help and argument parsing
# ---------------------------------------------------------------------------
def help_text
  <<~EOT
    Usage: #{$prog} [options] <rounds> <study_minutes> <break_minutes>

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
      #{$prog} 5 50 10           # 5 rounds, 50 min study, 10 min break
      #{$prog} --dry-run 3 5 2   # 3 rounds, 5 s study, 2 s break
      #{$prog} --theme Ocean 5 50 10

    Keys (while a phase is running):
      p / space   pause and resume the current phase
      s           skip the rest of the current phase
      q           quit the session
      Alt+T       switch to the next color theme

    Environment overrides:
      ALERT_SOUND, SINK_NAME, QUOTES, STATE_DIR, MAX_LOG_BYTES, THEME

    Config file (first one that exists):
      --config FILE | $OBS_PANEL_CONFIG | $XDG_CONFIG_HOME/obs-study-panel/config
  EOT
end

def print_help(code, to_stderr)
  text = help_text
  if to_stderr
    $stderr.write(text)
  else
    $stdout.write(text)
  end
  exit code
end

def usage_error
  print_help(1, true)
end

def valid_number(s)
  !s.to_s.empty? && s.length <= 4 && s =~ /^[1-9][0-9]{0,3}$/
end

def parse_args(argv)
  rest = argv.dup
  pos = []
  until rest.empty?
    a = rest.first
    case a
    when '-h', '--help'
      print_help(0, false)
    when '-c', '--config'
      if rest.length < 2
        $stderr.puts "Error: #{a} needs a file argument"
        usage_error
      end
      rest.shift
      $config_file = rest.shift
    when '-d', '--dry-run'
      $dry_run = true
      rest.shift
    when '-n', '--no-alert'
      $use_alert = false
      rest.shift
    when '-s', '--no-sink'
      $use_sink = false
      rest.shift
    when '-t', '--theme'
      if rest.length < 2
        $stderr.puts "Error: #{a} needs a theme name"
        usage_error
      end
      rest.shift
      $cli_theme = rest.shift
    when '--list-themes'
      print_theme_list
      exit 0
    when '--'
      rest.shift
      pos.concat(rest)
      rest.clear
    when /^-/
      $stderr.puts "Error: unknown option: #{a}"
      usage_error
    else
      pos.concat(rest)
      rest.clear
    end
  end
  usage_error if pos.length != 3
  pos.each do |v|
    usage_error unless valid_number(v)
  end
  $rounds = pos[0].to_i
  $study_min = pos[1].to_i
  $break_min = pos[2].to_i
  if $rounds > 50
    $stderr.puts 'Error: rounds must be <= 50'
    usage_error
  end
  if $study_min > 600
    $stderr.puts 'Error: study minutes must be <= 600'
    usage_error
  end
  if $break_min > 120
    $stderr.puts 'Error: break minutes must be <= 120'
    usage_error
  end
  return unless $dry_run

  $duration_unit = 'seconds'
  $seconds_per_unit = 1
end

# ---------------------------------------------------------------------------
# Configuration file
# ---------------------------------------------------------------------------
# The config file is bash source code (exactly like the reference). It is
# interpreted by a child bash that first seeds the pre-config default knobs,
# sources the file, and then dumps the resulting values: unit separator
# 0x1F between key and value, record separator 0x1E between records. A
# sourced file that calls `exit N` terminates the child before the dump is
# written, which this program detects and mirrors.
CONFIG_DUMP_SH = <<~'SH'
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
SH

def find_config_file
  return $config_file unless $config_file.empty?
  return ENV['OBS_PANEL_CONFIG'] if ENV['OBS_PANEL_CONFIG'] &&
                                     !ENV['OBS_PANEL_CONFIG'].empty?

  xdg_base = if ENV['XDG_CONFIG_HOME'] && !ENV['XDG_CONFIG_HOME'].empty?
               ENV['XDG_CONFIG_HOME']
             else
               File.join(ENV['HOME'].to_s, '.config')
             end
  xdg = File.join(xdg_base, 'obs-study-panel', 'config')
  return xdg if File.file?(xdg)

  local = File.join($dir, 'obs-panel.conf')
  return local if File.file?(local)

  nil
end

def quotes_to_list(raw)
  $quote_list = raw.split("\n").map { |l| l.gsub(/\r+$/, '') }
                   .reject(&:empty?)
end

def load_config(path)
  unless File.readable?(path)
    $stderr.puts "Error: config file is not readable: #{path}"
    exit 1
  end
  # Syntax check up front, exactly like the reference.
  err = `bash -n #{path} 2>&1`
  if $CHILD_STATUS.exitstatus != 0
    $stderr.puts "Error: syntax error in config file: #{path}"
    err.lines.map(&:chomp).reject { |l| l.strip.empty? }.first(3).each do |l|
      $stderr.puts l
    end
    exit 1
  end

  dump_path = "/tmp/obs-panel-conf-#{Process.pid}"
  child_env = {
    'ALERT_SOUND' => $alert_sound,
    'SINK_NAME' => $sink_name,
    'STATE_DIR' => '',
    'MAX_LOG_BYTES' => '1048576',
    'FILE_BAR_WIDTH' => '20',
    'NON_TTY_ENTER_TIMEOUT' => '300',
    'POINTS' => $points.to_s,
    'LAST_DATE' => $last_date,
    'QUOTES_SEED' => $quote_list.join("\x1f")
  }
  pid = spawn(child_env, 'bash', '-c', CONFIG_DUMP_SH, 'obs-panel',
              path, dump_path)
  _, status = Process.waitpid2(pid)
  c_code = status.exitstatus || 1

  raw = File.exist?(dump_path) ? File.read(dump_path, mode: 'rb') : ''
  File.delete(dump_path) if File.exist?(dump_path)

  if raw.empty?
    # The config called exit N before the dump was written.
    exit(c_code.zero? ? 1 : c_code)
  end

  values = {}
  quotes = []
  raw.force_encoding(Encoding::BINARY).split("\x1e", -1).each do |record|
    next if record.empty?

    i = record.index("\x1f")
    next if i.nil?

    key = record[0, i]
    value = record[(i + 1)..]
    if key == 'QUOTE'
      quotes << value.force_encoding(Encoding::UTF_8)
    else
      values[key] = value.force_encoding(Encoding::UTF_8)
    end
  end

  $alert_sound = values['ALERT_SOUND'] if values.key?('ALERT_SOUND')
  $sink_name = values['SINK_NAME'] if values.key?('SINK_NAME')
  $state_dir = values.key?('STATE_DIR') ? values['STATE_DIR'] : ''
  $max_log_bytes = if values.key?('MAX_LOG_BYTES') &&
                      values['MAX_LOG_BYTES'] =~ /^\d+$/ &&
                      values['MAX_LOG_BYTES'].to_i.positive?
                     values['MAX_LOG_BYTES'].to_i
                   else
                     1_048_576
                   end
  $file_bar_width = if values.key?('FILE_BAR_WIDTH') &&
                       values['FILE_BAR_WIDTH'] =~ /^\d+$/
                      w = values['FILE_BAR_WIDTH'].to_i
                      w.positive? && w <= 200 ? w : 20
                    else
                      20
                    end
  $non_tty_enter_timeout = if values.key?('NON_TTY_ENTER_TIMEOUT') &&
                              values['NON_TTY_ENTER_TIMEOUT'] =~ /^\d+$/
                             t = values['NON_TTY_ENTER_TIMEOUT'].to_i
                             t.positive? && t <= 3600 ? t : 300
                           else
                             300
                           end
  $config_theme = values.key?('THEME') ? values['THEME'] : ''
  $points = if values.key?('POINTS') && values['POINTS'] =~ /^\d+$/
              values['POINTS'].to_i
            else
              0
            end
  $last_date = values.key?('LAST_DATE') ? values['LAST_DATE'] : ''
  $config_quotes = values.key?('QUOTES') ? values['QUOTES'] : ''
  $quote_list = quotes
  $config_loaded = path
end

def apply_quote_sources
  quotes_to_list($env_quotes) unless $env_quotes.empty?
  quotes_to_list($config_quotes) if $env_quotes.empty? && !$config_quotes.empty?
end

# ---------------------------------------------------------------------------
# Paths and theme selection
# ---------------------------------------------------------------------------
def setup_paths
  $state_dir = $dir if $state_dir.empty?
  begin
    require 'fileutils'
    FileUtils.mkdir_p($state_dir)
  rescue StandardError
    $stderr.puts "Error: cannot create state dir: #{$state_dir}"
    exit 1
  end
  join = ->(n) { File.join($state_dir, n) }
  $date_file = join.call('date.txt')
  $day_file = join.call('day.txt')
  $session_file = join.call('session.txt')
  $timer_file = join.call('timer.txt')
  $log_file = join.call('log.txt')
  $progress_file = join.call('progress.txt')
  $points_file = join.call('points.txt')
  $message_file = join.call('message.txt')
  $next_file = join.call('next.txt')
  $overlay_file = join.call('overlay.txt')
  $theme_file = join.call('theme.txt')
end

def select_theme
  request = $cli_theme
  request = $env_theme if request.empty? && !$env_theme.empty?
  request = $config_theme if request.empty? && !$config_theme.empty?
  if request.empty? && $theme_file && File.file?($theme_file)
    request = File.foreach($theme_file).first.to_s.chomp
  end
  return if request.empty?

  idx = theme_index(request)
  if idx.negative?
    $stderr.puts "Warning: unknown theme '#{request}', using #{$theme_name}"
  else
    set_theme(idx)
  end
end

# ---------------------------------------------------------------------------
# OBS state files
# ---------------------------------------------------------------------------
def write_state(path, text)
  File.write(path, "#{text}\n")
rescue StandardError
  # best effort
end

def update_date_day
  d = Time.now.strftime('%Y-%m-%d')
  return if d == $last_date

  $last_date = d
  $last_day = Time.now.strftime('%A')
  write_state($date_file, d)
  write_state($day_file, $last_day)
end

def sync_state
  update_date_day
  publish_state
end

def publish_state
  filled = $pct * $file_bar_width / 100
  bar = make_bar(filled, $file_bar_width, '#', '-')
  pct_s = format('%3d%%', $pct)

  write_state($session_file, $session_text)
  write_state($timer_file, $remaining_str)
  write_state($points_file, $points.to_s)
  write_state($next_file, $next_text)
  write_state($message_file, $message_text)
  write_state($progress_file, "[#{bar}] #{pct_s}")

  overlay = +"#{$last_date} #{$last_day}\n"
  overlay << "#{$session_text}\n"
  overlay << "#{$remaining_str}\n"
  overlay << "[#{bar}] #{pct_s}\n"
  overlay << "Pts: #{$points}\n"
  overlay << "Next: #{$next_text}\n"
  overlay << "#{$message_text}\n" unless $message_text.empty?
  File.write($overlay_file, overlay)
rescue StandardError
  # best effort
end

def rotate_log_if_needed
  return unless File.file?($log_file) && File.size($log_file) >= $max_log_bytes

  File.rename($log_file, "#{$log_file}.1")
  File.write($log_file, '')
rescue StandardError
  # best effort
end

def log_event(msg)
  rotate_log_if_needed
  File.open($log_file, 'a') do |fh|
    fh.puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}"
  end
rescue StandardError
  # best effort
end

# ---------------------------------------------------------------------------
# Audio alerts
# ---------------------------------------------------------------------------
def sink_is_ready
  return false unless which('pactl')

  out = IO.popen(['pactl', 'list', 'short', 'sinks'], err: '/dev/null') do |io|
    io.read
  end
  out.each_line do |line|
    fields = line.strip.split(/\s+/)
    return true if fields.length > 1 && fields[1] == $sink_name
  end
  false
rescue StandardError
  false
end

def setup_audio_sink
  return unless $use_sink
  return unless which('pactl')
  return if sink_is_ready

  system('pactl', 'load-module', 'module-null-sink',
         "sink_name=#{$sink_name}",
         "sink_properties=device.description=#{$sink_name}",
         out: '/dev/null', err: '/dev/null')
end

def stop_alert
  return unless $alert_pid.positive?

  begin
    Process.kill('TERM', $alert_pid)
  rescue StandardError
    # already gone
  end
  $alert_pid = 0
end

def play_alert
  return unless $use_alert

  stop_alert
  if $alert_sound.empty? || !File.file?($alert_sound)
    puts "#{DIM}(alert file not found: #{$alert_sound.empty? ? 'none' : $alert_sound})#{NC}"
    return
  end

  player = if which('mpv')
             ['mpv', '--no-video', '--volume=70']
           elsif which('paplay')
             ['paplay']
           elsif which('ffplay')
             ['ffplay', '-nodisp', '-autoexit']
           elsif which('cvlc')
             ['cvlc', '--play-and-exit', '--no-video', '--volume=70']
           else
             puts "#{DIM}(no audio player found - install mpv / paplay / ffplay)#{NC}"
             return
           end

  setup_audio_sink if $use_sink && !sink_is_ready

  env = if $use_sink && sink_is_ready
         { 'PULSE_SINK' => $sink_name }
       else
         {}
       end
  pid = spawn(env, *player, $alert_sound, out: '/dev/null', err: '/dev/null')
  $alert_pid = pid
  puts "#{DIM}-> alert on OBS sink (#{$sink_name})#{NC}" if $use_sink && sink_is_ready
  puts "#{$secondary}-> alert on default device (OBS sink unavailable)#{NC}" unless $use_sink && sink_is_ready
rescue StandardError
  # best effort
end

# ---------------------------------------------------------------------------
# Keyboard input
# ---------------------------------------------------------------------------
def setup_terminal
  $stdin_is_tty = $stdin.isatty
  return unless $stdin_is_tty

  $saved_term = `stty -g < /dev/tty 2>/dev/null`.strip
  system('stty -icanon -echo < /dev/tty 2>/dev/null')
end

def restore_terminal
  return unless $stdin_is_tty

  if $saved_term && !$saved_term.empty?
    system("stty #{$saved_term} < /dev/tty 2>/dev/null")
  else
    system('stty sane < /dev/tty 2>/dev/null')
  end
  $saved_term = nil
end

# One byte with a timeout (seconds, may be fractional).
# Returns the byte string, nil on timeout, '' on EOF.
def read_byte_timeout(timeout)
  ready, = IO.select([$stdin], nil, nil, timeout)
  return nil unless ready

  begin
    $stdin.read(1) || ''
  rescue StandardError
    ''
  end
end

def wait_key(timeout)
  $key = ''
  $key_read = false
  unless $stdin_is_tty
    sleep(timeout)
    check_pending_exit
    return
  end
  b = read_byte_timeout(timeout)
  check_pending_exit
  return if b.nil? || b.empty?

  $key_read = true
  if b == "\e"
    nxt = read_byte_timeout(0.3)
    $key = 'alt-t' if nxt == 't' || nxt == 'T'
  else
    $key = b
  end
end

def discard_pending_input
  return unless $stdin_is_tty

  loop do
    b = read_byte_timeout(0.01)
    break if b.nil? || b.empty?
  end
end

def wait_for_enter
  if $stdin_is_tty
    loop do
      b = read_byte_timeout(1)
      if b.nil?
        update_date_day
        next
      end
      return if b.empty? || b == "\n"
    end
  end
  waited = 0
  while waited < $non_tty_enter_timeout
    slice_end = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      remaining = slice_end - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if remaining <= 0
        waited += 5
        break
      end
      b = read_byte_timeout(remaining)
      return if b == '' # EOF
      if b.nil?
        waited += 5
        break
      end
      return if b == "\n"
    end
  end
end

# ---------------------------------------------------------------------------
# Status / progress UI
# ---------------------------------------------------------------------------
def phase_color(label)
  label == 'STUDY' ? $primary : $secondary
end

def duration_label(n)
  if n == 1
    $duration_unit == 'seconds' ? '1 second' : '1 minute'
  else
    "#{n} #{$duration_unit}"
  end
end

def rounds_label(n)
  n == 1 ? '1 round' : "#{n} rounds"
end

def draw_status(label, round, total_rounds, elapsed, total, paused)
  filled = total.positive? ? elapsed * TERM_BAR_WIDTH / total : 0
  filled = TERM_BAR_WIDTH if filled > TERM_BAR_WIDTH
  bar = make_bar(filled, TERM_BAR_WIDTH, '=', ' ', '>')
  color = phase_color(label)
  flag = +''
  flag << "#{$primary} PAUSED#{NC}" if paused
  flag << "  #{DIM}Theme: #{$theme_name}#{NC}" if now_seconds < $theme_notice_until
  print "\r\e[K"
  printf("%s%s%-6s%s [%d/%d] %s[%s]%s %3d%%  %s  %sPts:%d%s%s",
         BOLD, color, label, NC, round, total_rounds,
         color, bar, NC, $pct, $remaining_str,
         $primary, $points, NC, flag)
  $stdout.flush
end

def box_row(color, plain, styled)
  pad = BOX_INNER - plain.length
  pad = 0 if pad.negative?
  puts "#{color}\u2551#{styled}#{' ' * pad}#{color}\u2551#{NC}"
end

def phase_header(label, round, total, minutes, subtitle)
  subtitle = subtitle[0, BOX_INNER - 4]
  color = phase_color(label)
  bar = "\u2550" * BOX_INNER
  dur = duration_label(minutes)
  info = "#{label}  \u00b7  Round #{round} / #{total}  \u00b7  #{dur}"
  puts
  puts "#{color}\u2554#{bar}\u2557#{NC}"
  box_row(color, "  #{info}",
          "  #{BOLD}#{label}#{NC}#{color}  \u00b7  Round #{round} / #{total}  \u00b7  #{dur}")
  box_row(color, "  #{subtitle}", "  #{DIM}#{subtitle}#{NC}#{color}")
  if $stdin_is_tty
    keys = "  p pause  \u00b7  s skip  \u00b7  q quit  \u00b7  Alt+T theme"
    box_row(color, keys, "#{DIM}#{keys}#{NC}#{color}")
  end
  puts "#{color}\u255a#{bar}\u255d#{NC}"
  puts
end

def show_completion(phase, round, total_rounds, next_phase, skipped)
  width = 60
  line = '=' * width
  title = if skipped == 1
            'PHASE SKIPPED'
          elsif phase == 'STUDY'
            'STUDY SESSION COMPLETE'
          else
            'BREAK COMPLETE'
          end
  color = phase_color(phase)
  puts
  puts "#{color}#{line}#{NC}"
  puts "#{color}#{' ' * ((width + title.length) / 2)}#{title}#{NC}"
  puts "#{color}#{line}#{NC}"
  puts
  puts "  Round:   #{BOLD}#{round}#{NC} / #{total_rounds}"
  puts "  Points:  #{$primary}#{$points}#{NC}"
  puts
  if next_phase == 'None'
    puts "  Next:    #{DIM}Session complete#{NC}"
  else
    puts "  Next:    #{BOLD}#{next_phase}#{NC}"
  end
  puts
  print "  #{$primary}Press Enter to continue...#{NC}"
  $stdout.flush
end

# ---------------------------------------------------------------------------
# Phase runner
# ---------------------------------------------------------------------------
def phase_prepare(ptype, minutes, round, total_rounds)
  if ptype == 'study'
    $phase_label = 'STUDY'
    $phase_subtitle = if $quote_list.empty?
                        'Stay focused.'
                      else
                        $quote_list[rand($quote_list.length)]
                      end
  else
    $phase_label = 'BREAK'
    $phase_subtitle = 'Relax and recharge.'
  end

  if ptype == 'study'
    $phase_next = if round < total_rounds
                    "Break (#{duration_label($break_min)})"
                  else
                    'None'
                  end
  else
    $phase_next = "Study (#{duration_label($study_min)})"
  end

  $phase_total = minutes * $seconds_per_unit
  $phase_elapsed = 0
  $phase_paused = false
  $phase_skipped = false
  $phase_start = now_seconds
  $phase_paused_total = 0
  $phase_pause_at = 0

  $session_text = "#{$phase_label} #{round}/#{total_rounds}"
  $remaining_str = fmt_hms($phase_total)
  $pct = 0
  $next_text = $phase_next == 'None' ? 'Session complete' : $phase_next
  $message_text = $phase_subtitle

  log_event("Start: #{$phase_label} #{round}/#{total_rounds} (#{duration_label(minutes)})")
  phase_header($phase_label, round, total_rounds, minutes, $phase_subtitle)
  sync_state
end

def phase_handle_key(round, total_rounds)
  case $key
  when 'p', 'P', ' '
    if $phase_paused
      $phase_paused_total += now_seconds - $phase_pause_at
      $phase_paused = false
      log_event("Resumed: #{$phase_label} #{round}/#{total_rounds}")
    else
      $phase_paused = true
      $phase_pause_at = now_seconds
      log_event("Paused: #{$phase_label} #{round}/#{total_rounds}")
    end
  when 's', 'S'
    $phase_skipped = true
    log_event("Skipped: #{$phase_label} #{round}/#{total_rounds}")
  when 'q', 'Q'
    log_event('Quit requested by user')
    cleanup(0)
  when 'alt-t'
    cycle_theme
  end
end

def phase_count(round, total_rounds)
  while $phase_elapsed < $phase_total
    remaining = $phase_total - $phase_elapsed
    remaining = 0 if remaining.negative?
    $remaining_str = fmt_hms(remaining)
    $pct = $phase_total.positive? ? $phase_elapsed * 100 / $phase_total : 0
    $pct = 100 if $pct > 100
    $session_text = "#{$phase_label} #{round}/#{total_rounds}"
    $session_text += ' (PAUSED)' if $phase_paused

    sync_state
    draw_status($phase_label, round, total_rounds, $phase_elapsed,
                $phase_total, $phase_paused ? 1 : 0)

    wait_key(1)
    if $key_read
      phase_handle_key(round, total_rounds)
      break if $phase_skipped
    end
    # CRASH-INJECT-POINT
    unless $phase_paused
      $phase_elapsed = now_seconds - $phase_start - $phase_paused_total
    end
  end
end

def phase_finish(round, total_rounds)
  if $phase_skipped
    $session_text = "#{$phase_label} #{round}/#{total_rounds} (SKIPPED)"
  else
    $pct = 100
    $points += 1
  end
  $remaining_str = '00:00:00'
  sync_state
  draw_status($phase_label, round, total_rounds, $phase_elapsed,
              $phase_total, 0)
  puts
  log_event("End: #{$phase_label} #{round}/#{total_rounds}")

  play_alert

  discard_pending_input
  show_completion($phase_label, round, total_rounds, $phase_next,
                  $phase_skipped ? 1 : 0)
  wait_for_enter
  stop_alert
  puts
end

def run_phase(ptype, minutes, round, total_rounds)
  phase_prepare(ptype, minutes, round, total_rounds)
  phase_count(round, total_rounds)
  phase_finish(round, total_rounds)
end

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
def reset_state_files
  $session_text = 'stopped'
  $remaining_str = '00:00:00'
  $pct = 0
  $next_text = ''
  sync_state
end

def cleanup(code)
  return if $in_cleanup

  $in_cleanup = true
  Signal.trap('INT', 'IGNORE')
  Signal.trap('TERM', 'IGNORE')
  Signal.trap('HUP', 'IGNORE')
  $state_finalized = true
  stop_alert
  begin
    reset_state_files
    log_event('Protocol stopped manually')
    puts
    puts "#{$secondary}#{BOLD}Interrupted.#{NC} #{DIM}State files reset to stopped.#{NC}"
  rescue StandardError
    # best effort
  end
  restore_terminal
  exit code
end

# Exit with the code cleanup() was asked for, from normal (non-trap) context.
def check_pending_exit
  return if $pending_exit.nil?

  code = $pending_exit
  $pending_exit = nil
  Process.exit!(code)
end

def on_unexpected_death(rc)
  return unless $state_ready
  return if $state_finalized

  $state_finalized = true
  stop_alert
  begin
    reset_state_files
    log_event("Protocol ended unexpectedly (exit #{rc})")
  rescue StandardError
    # best effort
  end
end

# The EXIT-trap equivalent: runs on normal exit, on exit N and on raise;
# it must not change the exit code.
at_exit do
  rc = $ERROR_INFO.is_a?(SystemExit) ? $ERROR_INFO.status : 1
  on_unexpected_death(rc)
  restore_terminal
end

# Signal handling: conventional exit codes 128 + signal number. The work
# happens in cleanup(); the exit itself is deferred to the interrupted wait
# loop (Process.exit! preserves the code from any context).
Signal.trap('INT')  { cleanup_deferred(130) }
Signal.trap('TERM') { cleanup_deferred(143) }
Signal.trap('HUP')  { cleanup_deferred(129) }

def cleanup_deferred(code)
  return if $in_cleanup

  $in_cleanup = true
  Signal.trap('INT', 'IGNORE')
  Signal.trap('TERM', 'IGNORE')
  Signal.trap('HUP', 'IGNORE')
  $state_finalized = true
  stop_alert
  begin
    reset_state_files
    log_event('Protocol stopped manually')
    puts
    puts "#{$secondary}#{BOLD}Interrupted.#{NC} #{DIM}State files reset to stopped.#{NC}"
  rescue StandardError
    # best effort
  end
  restore_terminal
  $pending_exit = code
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def finalize_session
  $session_text = 'session complete'
  $remaining_str = '00:00:00'
  $pct = 100
  $next_text = ''
  sync_state
  $state_finalized = true
  log_event("Protocol complete - total points: #{$points}")
end

def final_banner
  banner_width = 60
  title = 'ALL SESSIONS COMPLETE'
  inner = banner_width - 2
  pad = (inner - title.length) / 2
  border = '#' * banner_width
  puts
  puts "#{$primary}#{border}#{NC}"
  puts "#{$primary}##{NC}#{' ' * pad}#{BOLD}#{title}#{' ' * (inner - pad - title.length)}#{NC}##{$primary}"
  puts "#{$primary}#{border}#{NC}"
  puts
  puts "  #{BOLD}Total Rounds:#{NC}  #{$primary}#{$rounds}#{NC}"
  puts "  #{BOLD}Total Points:#{NC} #{$primary}#{$points}#{NC}"
  puts
  puts "#{$primary}#{BOLD}Great work!#{NC} #{DIM}Exiting.#{NC}"
end

def print_logo
  puts $primary
  puts LOGO
  puts NC
  puts "#{$primary}#{BOLD}     Study / Break Timer Protocol#{NC}"
  puts "#{DIM}\u2500\u2500 live state written to date \u00b7 day \u00b7 session \u00b7 timer \u00b7 log#{NC}"
  puts
end

parse_args(ARGV)

cfg = find_config_file
load_config(cfg) if cfg

# Environment variables beat the config file.
$alert_sound = $env_alert_sound unless $env_alert_sound.empty?
$sink_name = $env_sink_name unless $env_sink_name.empty?
$state_dir = $env_state_dir unless $env_state_dir.empty?
unless $env_max_log_bytes.empty?
  if $env_max_log_bytes =~ /^\d+$/ && $env_max_log_bytes.to_i.positive?
    $max_log_bytes = $env_max_log_bytes.to_i
  end
end

apply_quote_sources
setup_paths
select_theme
setup_terminal

$stdout.sync = true
print_logo
setup_audio_sink
update_date_day
# From here on the state files may be written (and have to be reset if the
# program dies unexpectedly).
$state_ready = true
log_event("Starting new study protocol: #{rounds_label($rounds)}, " \
          "#{duration_label($study_min)} study, #{duration_label($break_min)} break")

puts "#{$secondary}Protocol:#{NC} #{BOLD}#{rounds_label($rounds)}#{NC}  #{DIM}|#{NC}  " \
     "#{BOLD}#{duration_label($study_min)}#{NC} study  #{DIM}|#{NC}  " \
     "#{BOLD}#{duration_label($break_min)}#{NC} break  #{DIM}|#{NC}  " \
     "#{BOLD}Theme: #{$theme_name}#{NC}"
puts "#{DIM}Config: #{$config_loaded}#{NC}" unless $config_loaded.empty?
puts

(1..$rounds).each do |round|
  run_phase('study', $study_min, round, $rounds)
  run_phase('break', $break_min, round, $rounds) if round < $rounds
  check_pending_exit
end

finalize_session
final_banner
restore_terminal
exit 0
