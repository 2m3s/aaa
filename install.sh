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
  [ -f "$DIR/server.env" ] && cp "$DIR/server.env" "$DIR/server.env.keep"
  git -C "$DIR" checkout -- server.env 2>/dev/null || true
  if ! git -C "$DIR" pull --ff-only; then
    [ -f "$DIR/server.env.keep" ] && mv "$DIR/server.env.keep" "$DIR/server.env"
    echo "Update failed (see above)."; exit 1
  fi
  if [ -f "$DIR/server.env.keep" ]; then mv "$DIR/server.env.keep" "$DIR/server.env"; fi
else
  echo "==> Downloading server files to $DIR"
  git clone "$REPO_URL" "$DIR"
fi
if [ ! -f "$DIR/server.env" ]; then
  # Fresh install: random passwords, and size the heap to this machine.
  cp "$DIR/server.env.example" "$DIR/server.env"
  rand() { head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
  sed -i "s|^RCON_PASSWORD=.*|RCON_PASSWORD=$(rand 20)|" "$DIR/server.env"
  sed -i "s|^PANEL_PASSWORD=.*|PANEL_PASSWORD=$(rand 16)|" "$DIR/server.env"
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  if [ "$mem_gb" -ge 6 ]; then heap=4G; else heap=3G; fi
  sed -i "s|^MEMORY=.*|MEMORY=$heap|" "$DIR/server.env"
  echo "==> This machine has ~${mem_gb}GB RAM, giving Minecraft $heap"
fi
# Installs from before the web panel existed have no panel login yet.
if ! grep -q '^PANEL_PASSWORD=.' "$DIR/server.env"; then
  sed -i '/^PANEL_PASSWORD=/d; /^PANEL_USER=/d' "$DIR/server.env"
  printf '\nPANEL_USER=admin\nPANEL_PASSWORD=%s\n' "$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)" >> "$DIR/server.env"
fi
chmod +x "$DIR/mc" "$DIR/scripts/mc-entry.sh"

cd "$DIR"
$DOCKER compose up -d

if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
  $SUDO ufw allow 25565/tcp >/dev/null && $SUDO ufw allow 8080/tcp >/dev/null && echo "==> Opened ports 25565 and 8080 in ufw"
fi

ip=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
pw=$(grep '^PANEL_PASSWORD=' server.env | cut -d= -f2-)
user=$(grep '^PANEL_USER=' server.env | cut -d= -f2-)
cat <<EOF

==> Done! The server is starting (the first start downloads Minecraft, give it a few minutes).
    Connect in Minecraft to:  ${ip:-<this machine's IP>}:25565

    Web panel (console, files, mods, plugins, settings):
      http://${ip:-<this machine's IP>}:8080
      user: ${user:-admin}   password: $pw

    cd $DIR
    ./mc logs            watch it start (Ctrl+C to leave)
    ./mc web             show the panel address and login again
    nano server.env      change settings, then ./mc restart
EOF
if [ -n "$SUDO" ] && [ "$DOCKER" != "docker" ]; then
  echo
  echo "    Note: your user isn't in the docker group yet. Run"
  echo "      sudo usermod -aG docker \$USER   then log out and back in,"
  echo "    or prefix ./mc commands with sudo."
fi
