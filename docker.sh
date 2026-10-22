#!/usr/bin/env bash
# docker.sh — one-command Docker management for this MetaMCP fork.
#
# On a fresh VPS:
#   git clone <this repo> && cd metamcp
#   ./docker.sh            # installs Docker if missing, creates .env with
#                          # generated secrets, pulls the fork image and
#                          # starts the whole stack, then prints the URL
#                          # and the bootstrap admin login.
#
# Commands:
#   up        Pull the published image and start (default when no command)
#   build     Build the image from this checkout (Dockerfile), then start
#   update    git pull + pull new image + recreate (deploy latest dev)
#   down      Stop the stack (data volumes are kept)
#   restart   Restart the stack
#   status    Show containers and app health
#   logs      Follow logs (optionally: logs app | logs postgres)
#   shell     Open a shell in the app container
#   backup    Dump Postgres to ./backups/metamcp-<timestamp>.sql.gz
#   destroy   Stop AND delete data volumes (asks for typed confirmation)
#
# Notes:
# - .env is created from example.env on first run; POSTGRES_PASSWORD,
#   BETTER_AUTH_SECRET and BOOTSTRAP_USER_PASSWORD are replaced with
#   generated values. The generated admin password is printed ONCE at the
#   end of the first `up` — save it, or change it in the UI and in .env.
# - APP_URL in .env ships as http://localhost:12008. On a VPS behind a
#   domain/reverse proxy, edit it to the public URL and re-run `./docker.sh up`.
# - App port stays loopback-only (127.0.0.1:12008) as the compose intends;
#   expose it through your reverse proxy or an SSH tunnel.

set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILES=(-f docker-compose.yml)
IMAGE_HINT="ghcr.io/tannhatcms/metamcp:latest"
APP_URL_LOCAL="http://127.0.0.1:12008"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- docker / sudo detection -------------------------------------------------
SUDO=""
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi
dc() {
  if [ -n "$SUDO" ]; then sudo docker compose "${COMPOSE_FILES[@]}" "$@";
  else docker compose "${COMPOSE_FILES[@]}" "$@"; fi
}
dk() {
  if [ -n "$SUDO" ]; then sudo docker "$@"; else docker "$@"; fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  warn "Docker (with the compose plugin) not found — installing via get.docker.com..."
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
  curl -fsSL https://get.docker.com | $SUDO sh
  $SUDO systemctl enable --now docker 2>/dev/null || true
  docker compose version >/dev/null 2>&1 || die "Docker installed but the compose plugin is missing — install docker-compose-plugin and retry."
  log "Docker installed: $(docker --version)"
}

# --- .env bootstrap ------------------------------------------------------------
gen_secret() { openssl rand -hex 32; }

set_env() { # set_env KEY VALUE — replace or append in .env
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}
get_env() { grep "^$1=" .env | head -1 | cut -d= -f2- | sed 's/[[:space:]]#.*$//'; }

ensure_env() {
  [ -f .env ] && return 0
  [ -f example.env ] || die "example.env not found — run this from the repo root of a full checkout."
  log "First run: creating .env from example.env with generated secrets..."
  cp example.env .env
  # Phòng thủ sâu: Docker Compose không strip inline comment trong env_file,
  # nên cắt đuôi " #..." trên các dòng KEY=value (bỏ qua dòng comment thuần) —
  # tránh value rác lọt vào cấu hình app.
  sed -i '/^[[:space:]]*#/!s/[[:space:]]#.*$//' .env
  local pg_pw auth_secret admin_pw
  pg_pw="$(gen_secret)"
  auth_secret="$(gen_secret)"
  admin_pw="$(gen_secret)"
  set_env POSTGRES_PASSWORD "$pg_pw"
  set_env DATABASE_URL "postgres://metamcp_user:${pg_pw}@postgres:5432/metamcp_db"
  set_env BETTER_AUTH_SECRET "$auth_secret"
  set_env BOOTSTRAP_USER_PASSWORD "$admin_pw"
  echo "$admin_pw" > .bootstrap-admin-password
  chmod 600 .env .bootstrap-admin-password
  log ".env created (chmod 600). Generated admin password saved to .bootstrap-admin-password for this first boot."
}

# --- lifecycle -----------------------------------------------------------------
wait_healthy() {
  log "Waiting for the app to answer on ${APP_URL_LOCAL} ..."
  local i
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "$APP_URL_LOCAL" 2>/dev/null; then
      log "App is up."
      return 0
    fi
    sleep 3
  done
  warn "App did not answer within ~3 minutes. Recent logs:"
  dc logs --tail=30 app || true
  return 1
}

print_done() {
  local email
  email="$(get_env BOOTSTRAP_USER_EMAIL || true)"
  echo
  log "MetaMCP is running."
  echo "  URL (on this host): ${APP_URL_LOCAL}"
  echo "  APP_URL in .env   : $(get_env APP_URL || echo '(default http://localhost:12008)')"
  if [ -f .bootstrap-admin-password ]; then
    echo "  Bootstrap admin   : ${email:-test@user.example}"
    echo "  Admin password    : $(cat .bootstrap-admin-password)   <-- save this, change it after login"
  fi
  echo "  Other hosts reach it via your reverse proxy or: ssh -L 12008:127.0.0.1:12008 <user>@<vps>"
}

cmd_up() {
  ensure_docker
  ensure_env
  log "Pulling images (${IMAGE_HINT} + postgres)..."
  dc pull
  log "Starting stack..."
  dc up -d
  wait_healthy || true
  dc ps
  print_done
}

cmd_build() {
  ensure_docker
  ensure_env
  COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.build.yml)
  log "Building image from this checkout (Dockerfile)..."
  dc build app
  log "Starting stack from the local build..."
  dc up -d
  wait_healthy || true
  dc ps
  print_done
}

cmd_update() {
  ensure_docker
  ensure_env
  if [ -d .git ] && command -v git >/dev/null 2>&1; then
    log "Pulling latest code..."
    git pull --ff-only || warn "git pull failed (local changes?) — continuing with the image update only."
  fi
  log "Pulling newest image and recreating..."
  dc pull
  dc up -d
  wait_healthy || true
  dc ps
}

cmd_down()    { dc down; log "Stack stopped. Data volumes kept (postgres_data, uv_cache)."; }
cmd_restart() { ensure_docker; ensure_env; dc up -d; wait_healthy || true; dc ps; }
cmd_status()  { dc ps; echo; curl -fsS -o /dev/null -w "app HTTP %{http_code} on ${APP_URL_LOCAL}\n" "$APP_URL_LOCAL" 2>/dev/null || echo "app not answering on ${APP_URL_LOCAL}"; }
cmd_logs()    { if [ -n "${1:-}" ]; then dc logs -f --tail=200 "$1"; else dc logs -f --tail=200; fi }
cmd_shell()   { dc exec app sh; }

cmd_backup() {
  ensure_env
  mkdir -p backups
  local out="backups/metamcp-$(date +%Y%m%d-%H%M%S).sql.gz"
  log "Dumping Postgres to ${out}..."
  dc exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "$out"
  log "Backup written: ${out} ($(du -h "$out" | cut -f1))"
}

cmd_destroy() {
  warn "This stops the stack and DELETES the data volumes (postgres_data, uv_cache) — all gateway data is lost."
  printf "Type 'destroy' to continue: "
  read -r answer
  [ "$answer" = "destroy" ] || { echo "Aborted."; exit 0; }
  dc down -v
  log "Stack and volumes removed."
}

case "${1:-up}" in
  up)      cmd_up ;;
  build)   cmd_build ;;
  update)  cmd_update ;;
  down)    cmd_down ;;
  restart) cmd_restart ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "${1:-}" ;;
  shell)   cmd_shell ;;
  backup)  cmd_backup ;;
  destroy) cmd_destroy ;;
  -h|--help|help)
    sed -n '2,30p' "$0" ;;
  *) die "Unknown command '$1' — run ./docker.sh help" ;;
esac
