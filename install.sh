#!/usr/bin/env bash
# One-shot installer for Linux (Ubuntu/Debian/etc.):
#   curl -fsSL https://raw.githubusercontent.com/2m3s/aaa/main/install.sh | bash
# Installs git + Docker if missing, downloads this repo to ~/aaa and starts the server.
set -euo pipefail

REPO_URL="https://github.com/2m3s/aaa.git"
DIR="${MC_DIR:-$HOME/aaa}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

if ! command -v git >/dev/null 2>&1; then
  echo "==> Installing git"
  if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -y && $SUDO apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y git
  elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y git
  else echo "Please install git and re-run."; exit 1; fi
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"
  curl -fsSL https://get.docker.com | $SUDO sh
fi

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  DOCKER="$SUDO docker"
fi

if [ -d "$DIR/.git" ]; then
  echo "==> Updating $DIR"
  git -C "$DIR" pull --ff-only
else
  echo "==> Downloading server files to $DIR"
  git clone "$REPO_URL" "$DIR"
  # Fresh install: random RCON password, and size the heap to this machine.
  pw=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
  sed -i "s|^RCON_PASSWORD=.*|RCON_PASSWORD=$pw|" "$DIR/server.env"
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  if [ "$mem_gb" -ge 6 ]; then heap=4G; else heap=3G; fi
  sed -i "s|^MEMORY=.*|MEMORY=$heap|" "$DIR/server.env"
  echo "==> This machine has ~${mem_gb}GB RAM, giving Minecraft $heap"
fi
chmod +x "$DIR/mc"

cd "$DIR"
$DOCKER compose up -d

ip=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

==> Done! The server is starting (the first start downloads Minecraft, give it a minute or two).
    Connect in Minecraft to:  ${ip:-<this machine's IP>}:25565

    cd $DIR
    ./mc logs            watch it start (Ctrl+C to leave)
    data/mods            put NeoForge 1.21.1 mods here
    data/plugins         put Paper/Spigot 1.21.1 plugins here
    ./mc restart         load new mods/plugins
    nano server.env      change settings, then ./mc restart
EOF
if [ -n "$SUDO" ] && [ "$DOCKER" != "docker" ]; then
  echo
  echo "    Note: your user isn't in the docker group yet. Run"
  echo "      sudo usermod -aG docker \$USER   then log out and back in,"
  echo "    or prefix ./mc commands with sudo."
fi
