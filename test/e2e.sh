#!/bin/bash
# End-to-end test of rex-auto-title on a throwaway Rex server.
#
#   test/e2e.sh                 (needs Rex installed, a C compiler, and sqlite3)
#   test/e2e.sh --unit          only the unit tests
#   REX=/path/to/rex test/e2e.sh
#
# It runs its own Rex server on its own socket and state folder, with fake
# Codex, Claude Code, and pi chats that keep their conversations in a
# throwaway home folder. It never connects to your own Rex server or reads
# your real chats, and it stops only the server it started.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
os=$(uname -s)
if [ -z "${REX:-}" ]; then
  current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if [ "$os" = Darwin ] && [ -x "$current" ]; then REX=$current; else REX=$(command -v rex); fi
fi

T=$(cd "$(mktemp -d /tmp/rex-auto-title-e2e.XXXXXX)" && pwd -P)
H=$T/home
mkdir -p "$H/elsewhere" "$T/bin" "$T/state" "$T/at" "$T/proj" "$T/proj2" "$T/repo/sub"
: >"$T/init.lua"
SOCK="unix://$T/rex.sock"
passed=0
failed=0

clean_env() { env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG "$@"; }
R() { clean_env "$REX" --autostart=false -S "$SOCK" "$@"; }
A() { HOME="$H" CODEX_HOME="" R do "$here/auto_title.lua" "state_dir=$T/at" quiet=true "$@"; }

server_pid=""
start_server() {
  clean_env "$REX" server run --listen "$SOCK" --state-dir "$T/state" --config "$T/init.lua" >>"$T/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do
    if R ls >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "the test server didn't start:"; cat "$T/server.log"; exit 1
}
stop_server() {
  if [ -n "$server_pid" ]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
watch_pid=""
cleanup() {
  if [ -n "$watch_pid" ]; then kill "$watch_pid" 2>/dev/null || true; fi
  stop_server
  pkill -f "$T/bin/" 2>/dev/null || true
  if [ "$failed" -gt 0 ] || [ "${KEEP:-0}" = 1 ]; then
    echo "Kept the test folder for a look: $T"
  else
    rm -rf "$T"
  fi
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; }
# label WINDOW: the tab's label now
label() { R window ls -s work --json | jq -r --arg w "$1" '.windows[] | select(.window_id == $w) | .label'; }
# expect_label DESCRIPTION WINDOW WANT: wait up to 8 s for the label
expect_label() {
  local got=""
  for _ in $(seq 1 40); do
    got=$(label "$2")
    if [ "$got" = "$3" ]; then ok "$1"; return 0; fi
    sleep 0.2
  done
  bad "$1 (got '$got', want '$3')"
}
# tab DIR [COMMAND...]: open a tab in DIR, print its window ID
tab() {
  local dir=$1; shift
  if [ $# -gt 0 ]; then
    R window new -s work -c "$dir" --focus=false --json -- "$@" | jq -r .window_id
  else
    R window new -s work -c "$dir" --focus=false --json | jq -r .window_id
  fi
}
# run_in WINDOW TEXT: type TEXT and Enter into the tab's focused terminal
run_in() {
  local block
  block=$(R window ls -s work --json | jq -r --arg w "$1" '.windows[] | select(.window_id == $w) | .focused_block_id')
  R do -s work -e "rex.block.call('com.superlogical.terminal', 'write', { block_id = '$block', data = [[$2]] .. '\n' }) return 'ok'" >/dev/null
}
default_of() { echo "Window ${1: -8}"; }

for app in codex claude pi; do
  cc -O0 -o "$T/bin/$app" -DAPP="\"$app\"" -DFAKE_HOME="\"$H\"" "$here/test/fake.c"
done

echo "0. Unit tests"
start_server
if R do "$here/test/unit.lua" >"$T/unit.log" 2>&1; then ok "$(tail -1 "$T/unit.log")"; else cat "$T/unit.log"; bad "unit tests"; fi
if [ "${1:-}" = "--unit" ]; then echo; echo "$passed passed, $failed failed"; [ "$failed" = 0 ]; exit; fi

R new work -c "$T" --json >/dev/null
mkdir -p "$T/repo/.git/refs/remotes/origin"
echo "ref: refs/heads/feature/MC-4242-login-page" >"$T/repo/.git/HEAD"
echo "ref: refs/remotes/origin/main" >"$T/repo/.git/refs/remotes/origin/HEAD"

echo "1. Each agent's tab is named after its conversation"
w_codex=$(tab "$T/proj" "$T/bin/codex" --prompt "修复登录页" --name "登录页修复")
w_claude=$(tab "$T/proj2" "$T/bin/claude" --prompt "first prompt" --name "Review auth flow")
w_pi=$(tab "$T/repo/sub" "$T/bin/pi" --prompt "clean skills")
w_shell=$(tab "$T/repo")
w_home=$(tab "$H")
sleep 2
A mode=once
expect_label "codex: its thread's name" "$w_codex" "proj - 登录页修复"
expect_label "claude: its ai-title" "$w_claude" "proj2 - Review auth flow"
expect_label "pi: its opening prompt, folder, and branch" "$w_pi" "sub - MC-4242 - clean skills"
expect_label "shell: folder and branch" "$w_shell" "repo - MC-4242"
expect_label "home folder shell: Rex's default" "$w_home" "$(default_of "$w_home")"

echo "2. Names follow the work"
pi_file=$(ls "$H"/.pi/agent/sessions/*/*.jsonl)
printf '{"type":"session_info","name":"Skill cleanup"}\n' >>"$pi_file"
A mode=once
expect_label "pi: renamed with /name" "$w_pi" "sub - MC-4242 - Skill cleanup"
sleep 1
pi_dir=$(dirname "$pi_file")
printf '{"type":"session","id":"n"}\n{"type":"message","message":{"role":"user","content":[{"type":"text","text":"fresh start"}]}}\n' >"$pi_dir/2026-11-17T02-00-00-000Z_n.jsonl"
A mode=once
expect_label "pi: /new moves the tab to the new session" "$w_pi" "sub - MC-4242 - fresh start"
claude_file=$(ls "$H"/.claude/projects/*/*.jsonl)
printf '{"type":"custom-title","customTitle":"Auth rename"}\n' >>"$claude_file"
A mode=once
expect_label "claude: /rename beats its ai-title" "$w_claude" "proj2 - Auth rename"
echo "0123456789abcdef0123456789abcdef01234567" >"$T/repo/.git/HEAD"
A mode=once
expect_label "shell: detached HEAD shows a short hash" "$w_shell" "repo - 0123456"
echo "ref: refs/heads/main" >"$T/repo/.git/HEAD"
A mode=once
expect_label "shell: default branch is left out" "$w_shell" "repo"
run_in "$w_shell" "cd '$H/elsewhere'"
sleep 1
A mode=once
expect_label "shell: follows cd" "$w_shell" "elsewhere"
run_in "$w_shell" "cd '$H'"
sleep 1
A mode=once
expect_label "shell: back home restores Rex's default" "$w_shell" "$(default_of "$w_shell")"

echo "3. A name you set is yours"
R window rename -s work "$w_claude" "my review"
A mode=once
expect_label "manual name kept" "$w_claude" "my review"
A mode=once
expect_label "manual name still kept on the next pass" "$w_claude" "my review"
R api call -s work session.set_window_label "{\"window_id\":\"$w_claude\",\"label\":\"\"}" >/dev/null
A mode=once
expect_label "cleared name handed back" "$w_claude" "proj2 - Auth rename"

echo "4. Each tab keeps its own chat"
w_c2=$(tab "$T/proj" "$T/bin/codex" --prompt "other")
sleep 2
A mode=once
expect_label "first codex keeps its thread" "$w_codex" "proj - 登录页修复"
expect_label "second codex gets the new thread" "$w_c2" "proj - other"
R window close -s work "$w_c2"
sleep 1
A mode=once
expect_label "first codex unchanged after the other closes" "$w_codex" "proj - 登录页修复"
w_c3=$(tab "$T/proj" "$T/bin/codex" --none)
sleep 2
A mode=once
expect_label "a closed tab's thread isn't reused" "$w_c3" "proj"
R window close -s work "$w_c3"
w_n1=$(tab "$T/proj2" "$T/bin/pi" --none)
w_n2=$(tab "$T/proj2" "$T/bin/pi" --none)
sleep 2
pi_dir="$H/.pi/agent/sessions/--$(echo "${T#/}/proj2" | tr / -)--"
mkdir -p "$pi_dir"
printf '{"type":"session","id":"x"}\n{"type":"message","message":{"role":"user","content":[{"type":"text","text":"which tab"}]}}\n' >"$pi_dir/2026-11-17T01-00-00-000Z_x.jsonl"
A mode=once
expect_label "two new pi chats in one folder: no guess" "$w_n1" "proj2"
expect_label "two new pi chats in one folder: no guess (other)" "$w_n2" "proj2"
R window close -s work "$w_n1"
R window close -s work "$w_n2"

w_r=$(tab "$T/proj" "$T/bin/codex" resume 00000000-0000-4000-8000-000000000042 --prompt "resumed thread")
sleep 2
A mode=once
expect_label "codex resume ID: that thread, even next to another chat" "$w_r" "proj - resumed thread"
expect_label "codex resume ID: the other chat keeps its own" "$w_codex" "proj - 登录页修复"
R window close -s work "$w_r"

echo "5. Labels survive a restart of the tool and of Rex"
A mode=once
expect_label "a second run changes nothing" "$w_codex" "proj - 登录页修复"
stop_server
start_server
sleep 2
A mode=once
expect_label "after a Rex restart the label stays ours" "$w_codex" "proj - 登录页修复"

echo "6. Watching: renames without a manual run"
w_watch=$(tab "$T/proj2")
HOME="$H" CODEX_HOME="" clean_env "$REX" --autostart=false -S "$SOCK" do "$here/auto_title.lua" --all "state_dir=$T/at" interval=1 quiet=true >"$T/watch.log" 2>&1 &
watch_pid=$!
expect_label "watcher names a new tab" "$w_watch" "proj2"
run_in "$w_watch" "cd '$T/repo'"
expect_label "watcher follows cd" "$w_watch" "repo"
kill "$watch_pid" 2>/dev/null || true
watch_pid=""

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]

