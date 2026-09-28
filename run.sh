#!/usr/bin/env bash
# Sentinel Eye lifecycle: setup, start, stop, status, logs, update, backup, clean.
# Runs in Docker (compose.yaml) by default; --native runs it straight from .venv on this machine instead.
#   ./run.sh help
# Bash 3.2 compatible (the one macOS ships), no zsh: a stock Linux VM doesn't have it.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)

GO2RTC_VERSION="v1.9.14"
SERVICE=sentinel-eye
PORT=${SENTINEL_PORT:-8007}
HOST=${SENTINEL_HOST:-0.0.0.0}
DATA_DIR=${SENTINEL_DATA_DIR:-./data}
PIDFILE="$ROOT/data/sentinel.pid"   # native only
LOGFILE="$ROOT/data/sentinel.log"   # native only
OS=$(uname -s)

usage() {
  cat <<EOF
Usage: ./run.sh [--docker|--native] <command> [args]

Commands:
  setup      Prepare everything start needs (docker: data dir + image; native: venv, go2rtc, ffmpeg check)
  start      Start in the background and wait until healthy (default command)
  run        Native only: run in the foreground (Ctrl-C stops it)
  stop       Stop it (docker: compose down; native: server, go2rtc, relays, ffmpeg)
  restart    stop + start
  status     Show whether it is running and healthy
  logs       Follow the server log (extra args go to 'docker compose logs', e.g. --tail 50)
  update     git pull, rebuild / reinstall dependencies, restart if it was running
  backup     Write data/ (settings, credentials, signing key, playback index) to backups/*.tar.gz
  shell      Docker only: open a shell inside the running container
  clean      Remove what setup built (docker: container + image; native: .venv, bin/go2rtc). Keeps data/.

Mode: --docker (default) or --native, or SENTINEL_MODE=docker|native. Without either, stop/status/logs
pick native when a native instance is running.
Environment: SENTINEL_HOST (default 0.0.0.0), SENTINEL_PORT (8007), SENTINEL_DATA_DIR (docker, ./data), TZ.
EOF
}

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# A specific bind address is where the server answers; 0.0.0.0/:: means loopback works.
probe_host() { case "$HOST" in ''|0.0.0.0|::) echo 127.0.0.1 ;; *) echo "$HOST" ;; esac; }
url()        { echo "http://$(probe_host):$PORT"; }
# True once the server answers and reports go2rtc up (same check as the compose healthcheck).
healthy()    { curl -fsS --max-time 5 "$(url)/api/status" 2>/dev/null | grep -q '"go2rtc": *true'; }
port_busy()  { (exec 3<>"/dev/tcp/$(probe_host)/$1") 2>/dev/null; }

# The server port plus go2rtc's own fixed ports: both modes use them, so only one can run at a time.
check_ports_free() {
  local p
  for p in "$PORT" 1984 8554 8555; do
    port_busy "$p" && die "port $p is already in use — is the other mode (or another instance) running? Try './run.sh status' with --docker and --native."
  done
  return 0
}

print_urls() {
  echo "Sentinel Eye: $(url)"
  case "$HOST" in
    ''|0.0.0.0|::) echo "  (listening on all interfaces; from another device use http://<this-host's-IP>:$PORT)" ;;
  esac
  echo "  Playback needs HTTPS or localhost (see README), e.g. ssh -N -L $PORT:127.0.0.1:$PORT <host>"
}

wait_healthy() {  # $1 = seconds
  local _
  for _ in $(seq 1 "$1"); do
    healthy && return 0
    sleep 1
  done
  return 1
}

# The pidfile's process, else one started without it (the old foreground run.sh, or 'run'). Matching on
# .venv keeps a host-networked container's own uvicorn out of it.
native_pid() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then cat "$PIDFILE"; return 0; fi
  pgrep -u "$(id -u)" -f '[.]venv/bin/uvicorn --app-dir app' | head -n 1 | grep .
}
native_running() { native_pid >/dev/null; }

MODE=${SENTINEL_MODE:-}
CMD=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker) MODE=docker ;;
    --native) MODE=native ;;
    -h|--help) usage; exit 0 ;;
    *) if [[ -z "$CMD" ]]; then CMD=$1; else ARGS+=("$1"); fi ;;
  esac
  shift
done
CMD=${CMD:-start}
if [[ -z "$MODE" ]]; then
  if native_running; then MODE=native; else MODE=docker; fi
fi
case "$MODE" in docker|native) ;; *) die "unknown mode '$MODE' (docker or native)";; esac

# ---------------------------------------------------------------------------------------------- docker

COMPOSE=()
compose() {
  if [[ ${#COMPOSE[@]} -eq 0 ]]; then
    if have docker && docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
    elif have docker-compose; then COMPOSE=(docker-compose)
    else die "Docker with the Compose plugin is required (or use --native). Install: https://docs.docker.com/engine/install/"
    fi
    docker info >/dev/null 2>&1 || die "the Docker daemon isn't reachable (is it running, and can $(id -un) use it?)"
  fi
  "${COMPOSE[@]}" "$@"
}

docker_running() { [[ -n "$(compose ps -q --status running "$SERVICE" 2>/dev/null)" ]]; }

docker_setup() {
  compose version >/dev/null
  mkdir -p "$DATA_DIR"
  # The container runs as UID 1000 and refuses to start if anything in /data isn't writable by it. On Linux
  # a bind mount keeps host ownership, so fix it here; Docker Desktop (macOS) maps ownership itself.
  if [[ "$OS" == Linux ]]; then
    local bad
    bad=$(find "$DATA_DIR" \( ! -uid 1000 -o ! -gid 1000 \) -print -quit 2>/dev/null || true)
    if [[ -n "$bad" ]]; then
      say "Giving $DATA_DIR to UID 1000 (the container user) — needs sudo"
      if [[ $(id -u) -eq 0 ]]; then chown -R 1000:1000 "$DATA_DIR"; else sudo chown -R 1000:1000 "$DATA_DIR"; fi
    fi
  fi
  say "Building image"
  compose build
}

docker_start() {
  if docker_running; then
    say "Already running"; docker_status; return 0
  fi
  check_ports_free
  docker_setup
  local files=(-f compose.yaml) seed=""
  # First run: let the app seed data/settings.json from .env (only read when settings.json doesn't exist).
  # Mounted through a throwaway override so compose.yaml never has to be edited.
  if [[ -f .env && ! -f "$DATA_DIR/settings.json" ]]; then
    seed=$(mktemp)
    printf 'services:\n  %s:\n    volumes:\n      - "%s/.env:/app/.env:ro"\n' "$SERVICE" "$ROOT" > "$seed"
    files+=(-f "$seed")
    say "First run: seeding settings from .env"
  fi
  say "Starting container"
  compose "${files[@]}" up -d
  if wait_healthy 60; then
    [[ -n "$seed" ]] && { rm -f "$seed"; compose up -d >/dev/null 2>&1; wait_healthy 60 || true; }  # drop the .env mount again
    say "Healthy"; print_urls
  else
    [[ -n "$seed" ]] && rm -f "$seed"
    compose logs --tail 40 "$SERVICE" >&2 || true
    [[ "$OS" == Darwin ]] && warn "Docker Desktop needs host networking on (Settings > Resources > Network > Enable host networking)."
    die "not healthy after 60s (logs above; './run.sh logs' to follow)"
  fi
}

docker_stop()    { say "Stopping container"; compose down -t 15; }
docker_status()  {
  if ! docker_running; then
    echo "docker: not running"
    if healthy; then echo "  (but something else answers on $(url) — a native instance? ./run.sh --native status)"; fi
    return 0
  fi
  compose ps "$SERVICE"
  if healthy; then echo "health: OK — $(url)"; else echo "health: not answering on $(url)"; fi
}
docker_logs()    {
  echo "(go2rtc's own log: $DATA_DIR/go2rtc.log)"
  if [[ ${#ARGS[@]} -gt 0 ]]; then compose logs -f "${ARGS[@]}" "$SERVICE"; else compose logs -f --tail 200 "$SERVICE"; fi
}
docker_shell()   { docker_running || die "not running"; compose exec "$SERVICE" sh; }
docker_backup()  {
  # Via the image, so it works while data/ is owned by UID 1000 and settings.json is mode 600.
  local out
  out="backups/sentinel-data-$(date +%Y%m%d-%H%M%S).tar.gz"
  mkdir -p backups && (umask 077 && compose run --rm --no-deps -T --entrypoint "" "$SERVICE" tar czf - -C /data . > "$out")
  say "Backup written to $out (contains the DVR password — keep it private)"
}
docker_clean()   { say "Removing container and image (data kept)"; compose down -t 15 --rmi all; }

# ---------------------------------------------------------------------------------------------- native

VENV="$ROOT/.venv"

native_env() {
  [[ "$OS" == Darwin ]] && export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # Homebrew ffmpeg
  # python.org builds don't trust a system CA bundle by default; without this the AI frame enhancer's one-time
  # model-weight download (docs/SPEC.md section 7.8) fails with SSL_CERT_VERIFY_FAILED. certifi is already a
  # transitive dependency.
  SSL_CERT_FILE="$("$VENV/bin/python3" -c 'import certifi; print(certifi.where())' 2>/dev/null)" || true
  export SSL_CERT_FILE SENTINEL_HOST="$HOST" SENTINEL_PORT="$PORT"
}

fetch_go2rtc() {
  # bin/go2rtc is .gitignore'd (a binary, and arch-specific), so a fresh clone never has it.
  local arch asset work
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) die "go2rtc: unsupported architecture $(uname -m) — download it from https://github.com/AlexxIT/go2rtc/releases to bin/go2rtc" ;;
  esac
  case "$OS" in
    Darwin) asset="go2rtc_mac_${arch}.zip" ;;
    Linux)  asset="go2rtc_linux_${arch}" ;;
    *) die "go2rtc: unsupported OS $OS" ;;
  esac
  say "Fetching go2rtc $GO2RTC_VERSION ($asset)"
  mkdir -p bin
  work=$(mktemp -d)
  curl -fsSL "https://github.com/AlexxIT/go2rtc/releases/download/$GO2RTC_VERSION/$asset" -o "$work/$asset"
  if [[ "$asset" == *.zip ]]; then unzip -q -o "$work/$asset" -d "$work"; mv "$work/go2rtc" bin/go2rtc
  else mv "$work/$asset" bin/go2rtc; fi
  chmod +x bin/go2rtc
  [[ "$OS" == Darwin ]] && { xattr -d com.apple.quarantine bin/go2rtc 2>/dev/null || true; }  # only set if a proxy tagged the download
  rm -rf "$work"
}

native_setup() {
  native_env
  if ! have ffmpeg; then
    if [[ "$OS" == Darwin ]]; then die "ffmpeg not found — brew install ffmpeg"
    else die "ffmpeg not found — sudo apt install ffmpeg (or your distro's equivalent)"; fi
  fi
  if [[ ! -x "$VENV/bin/uvicorn" ]]; then
    have python3 || die "python3 not found"
    say "Creating .venv and installing requirements"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q -r requirements.txt
  fi
  [[ -x bin/go2rtc ]] || fetch_go2rtc
  mkdir -p data
  native_env   # again, now that the venv (and certifi) exists
}

native_run() {
  native_running && die "already running in the background (pid $(native_pid)) — ./run.sh --native stop first"
  native_setup
  print_urls
  exec "$VENV/bin/uvicorn" --app-dir app server:app --host "$HOST" --port "$PORT"
}

native_start() {
  if native_running; then say "Already running (pid $(native_pid))"; native_status; return 0; fi
  check_ports_free
  native_setup
  say "Starting (log: data/sentinel.log)"
  nohup "$VENV/bin/uvicorn" --app-dir app server:app --host "$HOST" --port "$PORT" >>"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  if wait_healthy 60; then
    say "Healthy (pid $(native_pid))"; print_urls
  else
    tail -n 40 "$LOGFILE" >&2 || true
    native_running || rm -f "$PIDFILE"
    die "not healthy after 60s (log above; './run.sh --native logs' to follow)"
  fi
}

native_stop() {
  say "Stopping"
  if native_running; then
    local pid _
    pid=$(native_pid)
    kill "$pid" 2>/dev/null || true   # uvicorn's shutdown stops go2rtc itself
    for _ in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  # Stragglers, and instances started by the old foreground run.sh. Only our own user's processes, so a
  # container's (UID 1000) on a host-networked Linux box isn't touched unless that's also this user.
  local u; u=$(id -u)
  pkill -u "$u" -f "[u]vicorn --app-dir app" || true
  pkill -u "$u" -f "[b]in/go2rtc" || true
  pkill -u "$u" -f "[a]pp/hikrelay.py" || true
  pkill -u "$u" -f "[f]fmpeg.*-f rtsp" || true
}

native_status() {
  if ! native_running; then
    echo "native: not running"
    if healthy; then echo "  (but something else answers on $(url) — the container? ./run.sh --docker status)"; fi
    return 0
  fi
  echo "native: running (pid $(native_pid))"
  if healthy; then echo "health: OK — $(url)"; else echo "health: not answering on $(url)"; fi
}

native_logs() {
  [[ -f "$LOGFILE" ]] || die "no log yet (data/sentinel.log is written by './run.sh --native start')"
  echo "(go2rtc's own log: data/go2rtc.log)"
  tail -n 200 -F "$LOGFILE"
}

native_shell() { die "shell is docker-only"; }

native_backup() {
  local out
  out="backups/sentinel-data-$(date +%Y%m%d-%H%M%S).tar.gz"
  mkdir -p backups && (umask 077 && tar czf "$out" --exclude sentinel.pid -C data .)
  say "Backup written to $out (contains the DVR password — keep it private)"
}

native_clean() {
  native_running && die "running — ./run.sh --native stop first"
  say "Removing .venv and bin/go2rtc (data kept)"
  rm -rf "$VENV" bin/go2rtc
}

# ------------------------------------------------------------------------------------------- commands

update() {
  local was_running=0
  if [[ "$MODE" == docker ]]; then docker_running && was_running=1; else native_running && was_running=1; fi
  # Fast-forward only, whatever pull.rebase says; local edits are stashed around it and put back.
  if [[ -d .git ]]; then say "git pull"; git pull --no-rebase --ff-only --autostash; fi
  if [[ "$MODE" == docker ]]; then
    say "Rebuilding image"; compose build --pull
    if [[ $was_running -eq 1 ]]; then
      compose up -d
      wait_healthy 60 || die "not healthy after update ('./run.sh logs')"
      say "Healthy"
    fi
  else
    native_setup
    say "Updating Python requirements"; "$VENV/bin/pip" install -q -r requirements.txt
    [[ $was_running -eq 1 ]] && { native_stop; native_start; }
  fi
  [[ $was_running -eq 1 ]] || say "Updated (not running; './run.sh start' to start)"
}

case "$CMD" in
  setup|start|stop|status|logs|backup|shell|clean) "${MODE}_$CMD" ;;
  run)     [[ "$MODE" == native ]] || die "'run' is native-only (docker: ./run.sh start, then ./run.sh logs)"; native_run ;;
  restart) "${MODE}_stop"; "${MODE}_start" ;;
  update)  update ;;
  help)    usage ;;
  *)       usage >&2; exit 2 ;;
esac
