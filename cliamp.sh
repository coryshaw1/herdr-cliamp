#!/usr/bin/env bash
#
# herdr-cliamp — one entry point for every plugin action.
#
#   cliamp.sh open      bootstrap the session + cliamp, then open the float
#   cliamp.sh attach    attach this terminal to the session (used by the pane)
#   cliamp.sh status    now-playing toast
#   cliamp.sh toggle    play/pause
#   cliamp.sh next      next track
#   cliamp.sh prev      previous track
#
# Two independent sockets are in play, and keeping them straight is the whole
# trick:
#
#   * cliamp's IPC socket (~/.config/cliamp/cliamp.sock) is at a FIXED path no
#     matter which herdr session hosts the TUI. That is why status/toggle/next/
#     prev work from any workspace without opening the float.
#
#   * herdr's per-session API socket. The player session has its own; toasts must
#     be aimed at the MAIN session's socket or they render in the hidden session
#     where nobody can see them.
#
# Requires: herdr >= 0.8.0, cliamp, jq, python3 (socket API; herdr's CLI flag
# parsing for some subcommands is unreliable in 0.8.0).
set -uo pipefail

# herdr may invoke this with a minimal environment, so guarantee the tools.
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
  case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d" ;; esac
done
export PATH

# ---- configuration ----------------------------------------------------------
# Override in $HERDR_PLUGIN_CONFIG_DIR/config.sh (herdr plugin config-dir
# herdr-cliamp), which is sourced before anything else is derived.
# Our own directory, so the script works whether herdr invokes it as a plugin
# action (HERDR_PLUGIN_ROOT set) or a popup keybind runs it directly (not set).
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-cliamp}"
[ -f "$CONFIG_DIR/config.sh" ] && . "$CONFIG_DIR/config.sh"

# Name of the dedicated herdr session that hosts the player.
SESSION="${CLIAMP_SESSION:-music}"
# Command that launches the TUI. `exec` matters: it makes cliamp the pane's
# process, so quitting it closes the pane instead of dropping to a stray shell.
CLIAMP_CMD="${CLIAMP_CMD:-cliamp}"
# Where toasts appear.
TOAST_POSITION="${CLIAMP_TOAST_POSITION:-top-right}"

HERDR_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
SESSION_DIR="$HERDR_HOME/sessions/$SESSION"
SESSION_SOCK="$SESSION_DIR/herdr.sock"
# The main session's socket: toasts go here, never to the player session.
MAIN_SOCK="${CLIAMP_MAIN_SOCKET:-$HERDR_HOME/herdr.sock}"

need() {
  command -v "$1" >/dev/null 2>&1 || { printf 'herdr-cliamp: missing %s\n' "$1" >&2; return 1; }
}

# ---- herdr socket API -------------------------------------------------------
# Spoken directly rather than through the CLI: several methods have no CLI
# surface, and `report-metadata`-style flag parsing is broken in 0.8.0.
api() {
  local sock="$1" method="$2" params="$3"
  python3 - "$sock" "$method" "$params" <<'PY' 2>/dev/null
import json, os, socket, sys
sock, method, params = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(os.path.expanduser(sock))
    s.sendall((json.dumps({"id": "herdr-cliamp", "method": method,
                           "params": json.loads(params)}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    sys.stdout.write(buf.decode().strip())
except Exception:
    sys.exit(1)
PY
}

toast() {
  HERDR_SOCKET_PATH="$MAIN_SOCK" herdr notification show "$1" \
    --body "$2" --position "$TOAST_POSITION" --sound none >/dev/null 2>&1
}

# ---- playback state ---------------------------------------------------------
cliamp_json() { cliamp status --json 2>/dev/null; }

cliamp_running() {
  cliamp_json | jq -e '.ok == true' >/dev/null 2>&1
}

# m:ss, or h:mm:ss past an hour (audiobooks and long mixes).
hms() {
  local t=${1%%.*}
  case "$t" in ''|*[!0-9-]*) printf '?'; return ;; esac
  [ "$t" -lt 0 ] && t=0
  if [ "$t" -ge 3600 ]; then
    printf '%d:%02d:%02d' $((t/3600)) $((t%3600/60)) $((t%60))
  else
    printf '%d:%02d' $((t/60)) $((t%60))
  fi
}

icon_for() {
  case "$1" in
    playing) printf '▶' ;;
    paused)  printf '⏸' ;;
    stopped) printf '⏹' ;;
    *)       printf '•' ;;
  esac
}

# Toast the current state. Reads fresh rather than trusting a prior command.
show_status() {
  local json state title artist album pos dur stream icon meta progress body
  json="$(cliamp_json)"
  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e '.ok == true' >/dev/null 2>&1; then
    toast "cliamp not running" "Run the \"cliamp: open floating player\" action"
    return 0
  fi

  state="$(printf '%s' "$json"  | jq -r '.state // "unknown"')"
  # cliamp >= the stream-metadata patch resolves .track.title/.artist from the
  # live ICY tag for radio, and exposes the unsplit value as .track.stream_title.
  # Older builds report only the station name; both work, the newer one just has
  # the actual song.
  title="$(printf '%s' "$json"  | jq -r '.track.title // ""')"
  artist="$(printf '%s' "$json" | jq -r '.track.artist // ""')"
  album="$(printf '%s' "$json"  | jq -r '.track.album // ""')"
  pos="$(printf '%s' "$json"    | jq -r '.position // 0')"
  dur="$(printf '%s' "$json"    | jq -r '.duration // 0')"
  stream="$(printf '%s' "$json" | jq -r '.track.stream // false')"
  station="$(printf '%s' "$json" | jq -r '.track.station // ""')"

  icon="$(icon_for "$state")"
  [ -n "$title" ] || title="(nothing loaded)"

  # Live radio reports no useful duration, so show elapsed only.
  progress=""
  if [ "${dur%%.*}" -gt 0 ] 2>/dev/null; then
    progress="$(hms "$pos") / $(hms "$dur")"
  elif [ "$stream" = "true" ]; then
    progress="live · $(hms "$pos")"
  fi

  # Headline is what is playing; the song leads.
  headline="$title"
  [ -n "$artist" ] && headline="$artist — $title"

  # Where it is playing: a station for radio, an album for everything else.
  # cliamp never reports both, so one line covers either.
  context="$station"
  if [ -z "$context" ] && [ "$album" != "$artist" ]; then
    context="$album"
  fi

  # Skip the context line entirely when there is none, rather than emitting a
  # blank -- a stream before its first metadata has neither station nor album.
  body="$context"
  [ -n "$progress" ] && body="${body:+$body
}$progress"
  [ -n "$body" ] || body="$state"

  toast "$icon $headline" "$body"
}

# A transport command only makes sense against a running player.
transport() {
  if ! cliamp_running; then
    toast "cliamp not running" "Run the \"cliamp: open floating player\" action"
    return 0
  fi
  cliamp "$1" >/dev/null 2>&1
  sleep 0.3   # let the player settle so the toast reports the new state
  show_status
}

# ---- session bootstrap ------------------------------------------------------
session_running() {
  herdr session list 2>/dev/null \
    | awk -v s="$SESSION" '$1==s && $2=="running"{f=1} END{exit !f}'
}

# Ensure the session server, a workspace, and cliamp all exist. Safe to re-run:
# each step is skipped when already satisfied.
ensure_session() {
  # The player session gets its own config (no sidebar/tab bar, keys mirroring
  # the user's) if the plugin ships or the user supplies one.
  local session_config="$CONFIG_DIR/session.toml"
  # HERDR_PLUGIN_ROOT is only set when herdr invokes us as a plugin action; the
  # popup keybind runs this script directly, so fall back to our own directory.
  # (Unset here would abort the whole script under `set -u`.)
  [ -f "$session_config" ] || session_config="${HERDR_PLUGIN_ROOT:-$SELF_DIR}/session.toml"
  [ -f "$session_config" ] && export HERDR_CONFIG_PATH="$session_config"

  if ! session_running; then
    herdr --session "$SESSION" server >/dev/null 2>&1 &
    local i
    for i in $(seq 1 40); do
      [ -S "$SESSION_SOCK" ] && break
      sleep 0.25
    done
  fi

  # A fresh session has no workspace; and when cliamp is quit its `exec`ed pane
  # exits, taking the tab (and sometimes the workspace) with it.
  local panes pane info
  panes="$(api "$SESSION_SOCK" pane.list '{}')"
  if ! printf '%s' "$panes" | grep -q '"pane_id"'; then
    api "$SESSION_SOCK" workspace.create \
      "{\"label\":\"Music\",\"cwd\":\"$HOME\",\"focus\":true}" >/dev/null
    sleep 2
    panes="$(api "$SESSION_SOCK" pane.list '{}')"
  fi

  pane="$(printf '%s' "$panes" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["panes"][0]["pane_id"])
except Exception: pass' 2>/dev/null)"
  [ -n "$pane" ] || return 1

  # Launch only if cliamp is not already this pane's foreground process. Testing
  # the pane (rather than a bare pgrep) keeps the singleton correct: cliamp owns
  # one IPC socket, and a second instance would answer for neither.
  info="$(api "$SESSION_SOCK" pane.process_info "{\"pane_id\":\"$pane\"}")"
  if ! printf '%s' "$info" | grep -q '"argv0":"cliamp"'; then
    api "$SESSION_SOCK" pane.send_text \
      "{\"pane_id\":\"$pane\",\"text\":\"exec $CLIAMP_CMD\\n\"}" >/dev/null
    sleep 1
  fi
}

# The plugin pane carries the [[panes]] title as its label, so an already-open
# float can be found and refocused instead of stacking another overlay.
find_player_pane() {
  api "$MAIN_SOCK" pane.list '{}' | python3 -c 'import json,sys
try:
    for p in json.load(sys.stdin)["result"]["panes"]:
        if p.get("label") == "cliamp":
            print(p["pane_id"]); break
except Exception: pass' 2>/dev/null
}

# ---- entry points -----------------------------------------------------------
case "${1:-}" in
  open)
    need herdr || exit 1
    ensure_session || { toast "cliamp" "Could not start the $SESSION session"; exit 1; }
    # Hand off to the plugin-owned overlay pane, which runs `attach` below.
    #
    # Flags must be space-separated: herdr 0.8.0 rejects `--plugin=X` ("unknown
    # option"), and there is no dotted-positional form. Do NOT fall back to
    # running `attach` here -- an action has no controlling terminal, so the
    # attach would panic in terminal init (ratatui, exit 101) instead of opening
    # anything. Report the failure instead.
    # No plugin pane: herdr's "overlay" placement is a split, not a float (see
    # herdr-plugin.toml). The true float is a config-level `type = "popup"` bound
    # to `cliamp.sh attach`. This action just prepares the session and tells the
    # user, so it stays useful in herdr's action menu.
    toast "cliamp ready" "Use your popup keybind to open the float"
    ;;
  attach)
    need herdr || exit 1
    ensure_session
    # Takes over only this (floating popup) terminal. Detaching hides the float
    # and leaves playback running.
    exec herdr session attach "$SESSION"
    ;;
  status)
    need cliamp || exit 1; need jq || exit 1
    show_status
    ;;
  toggle|next|prev)
    need cliamp || exit 1; need jq || exit 1
    transport "$1"
    ;;
  *)
    printf 'usage: cliamp.sh {open|attach|status|toggle|next|prev}\n' >&2
    exit 2
    ;;
esac
