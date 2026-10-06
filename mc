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

set_env() { # set_env KEY VALUE
  if grep -q "^$1=" server.env; then
    sed -i.bak "s|^$1=.*|$1=$2|" server.env && rm -f server.env.bak
  else
    echo "$1=$2" >> server.env
  fi
}

rcon() { docker exec -i mc rcon-cli "$@"; }

case "${1:-}" in
  start)   compose up -d; echo "Server starting. Watch it with: ./mc logs" ;;
  stop)    compose stop ;;
  restart) compose up -d --force-recreate ;;
  status)  compose ps ;;
  logs)    compose logs -f --tail=200 mc ;;
  console) rcon ;;
  cmd)     shift; rcon "$@" ;;
  mode)
    type=$(echo "${2:-}" | tr '[:lower:]' '[:upper:]')
    case "$type" in
      HYBRID|ARCLIGHT) set_env TYPE ARCLIGHT; set_env ARCLIGHT_TYPE NEOFORGE; set_env VERSION 1.21.1
        echo "Hybrid (Arclight + NeoForge, Minecraft 1.21.1): mods AND plugins."
        echo "NeoForge 1.21.1 mods -> data/mods    Paper/Spigot 1.21.1 plugins -> data/plugins" ;;
      MOHIST) set_env TYPE MOHIST; set_env VERSION 1.20.1
        echo "Hybrid (Mohist + Forge, Minecraft 1.20.1): mods AND plugins."
        echo "Forge 1.20.1 mods -> data/mods    Paper/Spigot 1.20.1 plugins -> data/plugins" ;;
      PAPER) set_env TYPE PAPER; set_env VERSION LATEST
        echo "Plugins only. Plugins -> data/plugins (or MODRINTH_PROJECTS)." ;;
      FABRIC|NEOFORGE|FORGE) set_env TYPE "$type"; set_env VERSION LATEST
        echo "Mods only. $type mods -> data/mods (or MODRINTH_PROJECTS)." ;;
      VANILLA) set_env TYPE VANILLA; set_env VERSION LATEST; echo "Vanilla, no mods or plugins." ;;
      *) echo "Pick one of: hybrid mohist paper fabric neoforge forge vanilla"; exit 1 ;;
    esac
    echo "VERSION is now $(grep '^VERSION=' server.env | cut -d= -f2); pin it in server.env to match your mods/plugins."
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
    git pull --ff-only
    compose pull
    compose up -d --force-recreate
    ;;
  *) usage ;;
esac
