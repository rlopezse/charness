#!/bin/bash
# Starts / stops the Claude Harness server for the macOS app wrapper.
# Also works on Linux (handy for testing).   Usage: launch.sh start | open | stop | status
umask 077
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${HARNESS_HOME:-$HOME/.claude-harness}"
PIDFILE="$DATA/server.pid"
PORTFILE="$DATA/server.port"
LOG="$DATA/server.log"
mkdir -p "$DATA" && chmod 700 "$DATA"

node_ok() { [ -n "$1" ] && [ -x "$1" ] && "$1" -e 'process.exit(parseInt(process.versions.node) >= 20 ? 0 : 1)' 2>/dev/null; }

find_node() {
  local c
  for c in "${HARNESS_NODE:-}" "$(command -v node 2>/dev/null)" /opt/homebrew/bin/node /usr/local/bin/node \
           "$HOME/.volta/bin/node" "$HOME"/.nvm/versions/node/*/bin/node "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node; do
    if node_ok "$c"; then echo "$c"; return 0; fi
  done
  # Last resort: ask a login shell (picks up nvm/asdf/etc. from your shell profile). Time-boxed.
  if command -v perl >/dev/null 2>&1; then
    c="$(perl -e 'alarm 8; exec @ARGV' "${SHELL:-/bin/zsh}" -lic 'command -v node' 2>/dev/null | tail -n 1)"
  else
    c="$("${SHELL:-/bin/zsh}" -lic 'command -v node' 2>/dev/null | tail -n 1)"
  fi
  if node_ok "$c"; then echo "$c"; return 0; fi
  return 1
}

# A GUI app does not see your shell's exports. If ANTHROPIC_API_KEY isn't set, look in the macOS Keychain
# (item "claude-harness"). Otherwise the Claude Code login on this Mac is used, if you have one.
load_key() {
  [ -n "${ANTHROPIC_API_KEY:-}" ] && return 0
  command -v security >/dev/null 2>&1 || return 0
  local k
  k="$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-harness -w 2>/dev/null)" || return 0
  [ -n "$k" ] && export ANTHROPIC_API_KEY="$k"
  return 0
}

port_open() {
  if [ -x /usr/bin/nc ]; then /usr/bin/nc -z 127.0.0.1 "$1" >/dev/null 2>&1; else (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}

ours_alive() {
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null)" || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= 2>/dev/null | grep -q "server.mjs"
}

cmd_open() {
  [ "${HARNESS_LAUNCH_NO_UI:-}" = 1 ] && return 0
  local port token url app
  port="$(cat "$PORTFILE" 2>/dev/null)"; token="$(cat "$DATA/token" 2>/dev/null)"
  if [ -z "$port" ] || [ -z "$token" ]; then echo "The server is not running." >&2; return 1; fi
  url="http://127.0.0.1:$port/?token=$token"
  if [ "$(uname)" = Darwin ]; then
    # A Chromium-family browser gets its own empty profile (no extensions can read your chats) in a
    # chrome-less "app" window. Anything else falls back to your default browser.
    for app in "Google Chrome" "Brave Browser" "Microsoft Edge" "Chromium"; do
      if [ -d "/Applications/$app.app" ] || [ -d "$HOME/Applications/$app.app" ]; then
        open -na "$app" --args --app="$url" --user-data-dir="$DATA/browser-profile" \
          --no-first-run --no-default-browser-check --disable-sync --disable-background-networking --no-pings
        return 0
      fi
    done
    open "$url"
  else
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

cmd_start() {
  if ours_alive; then cmd_open; return $?; fi
  local node port tries=0 i=0
  node="$(find_node)" || { echo "Node.js 20 or newer was not found. Install it (https://nodejs.org, or 'brew install node') and open the app again." >&2; exit 1; }
  if [ ! -d "$HERE/node_modules/@anthropic-ai/claude-agent-sdk" ]; then
    echo "Dependencies are missing. In Terminal run:  cd \"$HERE\" && npm install" >&2; exit 1
  fi
  load_key
  port="${PORT:-4317}"
  while port_open "$port"; do
    port=$((port + 1)); tries=$((tries + 1))
    if [ "$tries" -gt 20 ]; then echo "No free port found between 4317 and 4337." >&2; exit 1; fi
  done
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1000000 ]; then : > "$LOG"; fi
  nohup "$node" "$HERE/server.mjs" --port "$port" >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"; echo "$port" > "$PORTFILE"
  until port_open "$port" && [ -s "$DATA/token" ]; do
    sleep 0.2; i=$((i + 1))
    if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "The server stopped right after starting. Last log lines:" >&2; tail -n 8 "$LOG" >&2; exit 1; fi
    if [ "$i" -gt 50 ]; then echo "The server did not come up within 10 seconds. See $LOG" >&2; exit 1; fi
  done
  cmd_open
}

cmd_stop() {
  if ours_alive; then
    local pid i=0
    pid="$(cat "$PIDFILE")"
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; fi
  fi
  rm -f "$PIDFILE" "$PORTFILE"
  return 0
}

cmd_status() {
  if ours_alive; then echo "running on port $(cat "$PORTFILE" 2>/dev/null)"; else echo "stopped"; return 1; fi
}

case "${1:-}" in
  start)  cmd_start ;;
  open)   cmd_open ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *) echo "usage: $0 start|open|stop|status" >&2; exit 2 ;;
esac
