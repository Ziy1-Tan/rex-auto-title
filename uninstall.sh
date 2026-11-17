#!/bin/sh
# Remove rex-auto-title: stop its service and delete its files.
# Tab names it already set stay until you or Rex change them.
#
#   curl -fsSL https://raw.githubusercontent.com/Ziy1-Tan/rex-auto-title/main/uninstall.sh | sh
set -eu

os=$(uname -s)
if [ "$os" = Darwin ]; then
  data="$HOME/Library/Application Support/rex-auto-title"
  label=io.github.ziy1-tan.rex-auto-title
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
else
  data="${XDG_DATA_HOME:-$HOME/.local/share}/rex-auto-title"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now rex-auto-title.service 2>/dev/null || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/rex-auto-title.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
fi
rm -f "$data/auto_title.lua" "$data/state.json"
echo "Removed rex-auto-title."
