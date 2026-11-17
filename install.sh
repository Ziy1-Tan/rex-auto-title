#!/bin/sh
# Install rex-auto-title: copy auto_title.lua and run it as a login service,
# so every Rex tab is named after what it is doing.
#
#   ./install.sh                  install, or update an existing install
#   ./install.sh --no-service     copy the file only; run it yourself
#   REX=/path/to/rex ./install.sh use this rex command
#
# Remove it with ./uninstall.sh.
set -eu

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  echo "install.sh: HOME is not set to a folder" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
os=$(uname -s)
service=1
for arg in "$@"; do
  case "$arg" in
    --no-service) service=0 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

case "$os" in
  Darwin)
    data="$HOME/Library/Application Support/rex-auto-title"
    log="$HOME/Library/Logs/rex-auto-title.log"
    ;;
  Linux|FreeBSD)
    data="${XDG_DATA_HOME:-$HOME/.local/share}/rex-auto-title"
    log=""
    ;;
  *) fail "unsupported system $os (rex-auto-title runs on macOS and Linux)" ;;
esac
script="$data/auto_title.lua"

# On macOS, prefer the server's "Current" copy of rex: it stays the same
# across Rex updates.
find_rex() {
  if [ -n "${REX:-}" ]; then printf '%s\n' "$REX"; return 0; fi
  if [ "$os" = Darwin ]; then
    current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    if [ -x "$current" ]; then printf '%s\n' "$current"; return 0; fi
  fi
  command -v rex 2>/dev/null
}
rex=$(find_rex) || fail "can't find the rex command. Open Rex once, or run REX=/path/to/rex ./install.sh"
say "Using rex: $rex"

mkdir -p "$data"
cp "$here/auto_title.lua" "$script.new" && mv "$script.new" "$script"
say "Installed $script"

# sqlite3 reads Codex's thread list; the service needs it on PATH.
service_path="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
if [ "$service" = 0 ]; then
  say "Run it yourself with:"
  say "  \"$rex\" do \"$script\" --all"
  exit 0
fi

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

if [ "$os" = Darwin ]; then
  label=io.github.ziy1-tan.rex-auto-title
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$log")"
  # Wait until the Rex server answers, so launchd doesn't hold the service
  # back after a failed early start. $0 is rex, $1 the script.
  wait_script='i=0; while [ $i -lt 60 ]; do "$0" --autostart=false server status >/dev/null 2>&1 && break; i=$((i+1)); sleep 0.2; done; exec "$0" --autostart=false do "$1" --all mode=watch'
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>$(xml "$wait_script")</string>
    <string>$(xml "$rex")</string>
    <string>$(xml "$script")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$(xml "$service_path")</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$log")</string>
  <key>StandardErrorPath</key><string>$(xml "$log")</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  # bootout returns before launchd lets go of the label; bootstrap fails until it does.
  i=0
  until launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; do
    i=$((i + 1))
    [ $i -lt 20 ] || fail "launchctl bootstrap $plist failed"
    sleep 0.5
  done
  say "Started the login service $label (log: $log)"
elif command -v systemctl >/dev/null 2>&1; then
  units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$units"
  cat >"$units/rex-auto-title.service" <<EOF
[Unit]
Description=rex-auto-title: name Rex tabs after what they are doing

[Service]
ExecStart="$rex" --autostart=false do "$script" --all mode=watch
Restart=always
RestartSec=10
Environment="PATH=$service_path"

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now rex-auto-title.service
  systemctl --user restart rex-auto-title.service
  say "Started the systemd user service rex-auto-title"
else
  say "No launchd or systemd here. Keep this running yourself:"
  say "  \"$rex\" --autostart=false do \"$script\" --all &"
fi
