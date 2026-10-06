#!/usr/bin/env bash
# Helper for managing the Minecraft server. Run ./mc with no arguments for help.
set -euo pipefail
cd "$(dirname "$0")"

if docker compose version >/dev/null 2>&1; then
  compose() { docker compose "$@"; }
else
  compose() { docker-compose "$@"; }
fi

usage() {
  cat <<'EOF'
Usage: ./mc <command>

  web                   Show the web panel address and login
  start                 Start the server (in the background)
  stop                  Save the world and stop the server
  restart               Restart (use after editing server.env)
  status                Show whether the server is running
  logs                  Follow the server log (Ctrl+C to leave)
  console               Interactive server console (type "exit" to leave)
  cmd <command...>      Run one server command, e.g. ./mc cmd op Steve
  mode <type>           Switch server type:
                          hybrid (mods + plugins, default) | mohist (mods + plugins, 1.20.1)
                          paper (plugins) | fabric | neoforge | forge (mods) | vanilla
  memory <size>         Set Java heap, e.g. ./mc memory 4G
  backup                Save a .tar.gz of the server into backups/
  update                Pull the latest repo + server image and restart
EOF
}

set_env() { # set_env KEY VALUE [FILE]
  local file=${3:-server.env}
  touch "$file"
  if grep -q "^$1=" "$file"; then
    sed -i.bak "s|^$1=.*|$1=$2|" "$file" && rm -f "$file.bak"
  else
    echo "$1=$2" >> "$file"
  fi
}

get_env() { grep "^$1=" server.env 2>/dev/null | head -1 | cut -d= -f2- || true; }

# server.env holds your settings and isn't tracked by git, so updates never touch it.
ensure_settings() {
  [ -f server.env ] || cp server.env.example server.env
  grep -q '^PANEL_USER=' server.env || set_env PANEL_USER admin
  if [ -z "$(get_env PANEL_PASSWORD)" ]; then
    set_env PANEL_PASSWORD "$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
  fi
}

show_web() {
  local ip port
  ip=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
  port=$(grep '^PANEL_PORT=' .env 2>/dev/null | cut -d= -f2); port=${port:-8080}
  echo "Web panel:  http://${ip:-SERVER-IP}:$port"
  echo "  user:     $(get_env PANEL_USER)"
  echo "  password: $(get_env PANEL_PASSWORD)"
  echo "(Open TCP port $port in your firewall if it doesn't load, e.g. sudo ufw allow $port/tcp)"
}

rcon() { docker exec -i mc rcon-cli "$@"; }

# Under sudo, run git as the folder's owner: git refuses to work as root in a
# repo owned by someone else ("dubious ownership").
git_() {
  local owner; owner=$(ls -nd . | awk '{print $3}')
  if [ "$(id -u)" = 0 ] && [ "$owner" != 0 ]; then sudo -u "#$owner" git "$@"; else git "$@"; fi
}

ensure_settings

case "${1:-}" in
  web)     compose up -d; show_web ;;
  start)   compose up -d; echo "Server starting. Watch it with: ./mc logs"; show_web ;;
  stop)    compose stop ;;
  restart) compose up -d --force-recreate ;;
  status)  compose ps ;;
  logs)    compose logs -f --tail=200 mc ;;
  console) rcon ;;
  cmd)     shift; rcon "$@" ;;
  mode)
    type=$(echo "${2:-}" | tr '[:lower:]' '[:upper:]')
    case "$type" in
      HYBRID|ARCLIGHT) set_env TYPE ARCLIGHT; set_env ARCLIGHT_TYPE NEOFORGE; set_env VERSION 1.21.1; set_env JAVA_TAG java21 .env
        echo "Hybrid (Arclight + NeoForge, Minecraft 1.21.1): mods AND plugins."
        echo "NeoForge 1.21.1 mods -> data/mods    Paper/Spigot 1.21.1 plugins -> data/plugins" ;;
      MOHIST) set_env TYPE MOHIST; set_env VERSION 1.20.1; set_env JAVA_TAG java17 .env
        echo "Hybrid (Mohist + Forge, Minecraft 1.20.1): mods AND plugins."
        echo "Forge 1.20.1 mods -> data/mods    Paper/Spigot 1.20.1 plugins -> data/plugins" ;;
      PAPER) set_env TYPE PAPER; set_env VERSION LATEST; set_env JAVA_TAG latest .env
        echo "Plugins only. Plugins -> data/plugins (or MODRINTH_PROJECTS)." ;;
      FABRIC|NEOFORGE|FORGE) set_env TYPE "$type"; set_env VERSION LATEST; set_env JAVA_TAG latest .env
        echo "Mods only. $type mods -> data/mods (or MODRINTH_PROJECTS)." ;;
      VANILLA) set_env TYPE VANILLA; set_env VERSION LATEST; set_env JAVA_TAG latest .env; echo "Vanilla, no mods or plugins." ;;
      *) echo "Pick one of: hybrid mohist paper fabric neoforge forge vanilla"; exit 1 ;;
    esac
    echo "VERSION is now $(get_env VERSION); pin it in server.env to match your mods/plugins."
    echo "If you pin an older VERSION, set JAVA_TAG in .env to match (java21 for 1.20.5-1.21.x, java17 for 1.18-1.20.4)."
    echo "Mods built for a different loader or version won't load, so clear out data/mods if you switched."
    echo "Back up first if this world matters: ./mc backup"
    echo "Apply with: ./mc restart"
    ;;
  memory)
    [ -n "${2:-}" ] || { echo "Usage: ./mc memory 4G"; exit 1; }
    set_env MEMORY "$2"; echo "MEMORY set to $2. Apply with: ./mc restart" ;;
  backup)
    mkdir -p backups
    file="backups/mc-$(date +%Y%m%d-%H%M%S).tar.gz"
    running=$(docker ps -q -f name='^mc$')
    if [ -n "$running" ]; then rcon save-off >/dev/null; rcon save-all flush >/dev/null; fi
    tar -czf "$file" data || true
    if [ -n "$running" ]; then rcon save-on >/dev/null; fi
    echo "Backup written to $file"
    ;;
  update)
    # Older installs tracked server.env in git; keep your copy safe across the pull.
    cp server.env server.env.keep
    git_ checkout -- server.env 2>/dev/null || true
    git_ pull --ff-only || { mv server.env.keep server.env; exit 1; }
    mv server.env.keep server.env
    exec ./mc update-finish ;;
  update-finish)
    compose pull
    compose up -d --force-recreate
    ;;
  *) usage ;;
esac
