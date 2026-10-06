# Minecraft server: mods + plugins, 4GB

A Minecraft server that runs **mods and plugins at the same time**. It uses a hybrid server ([Arclight](https://github.com/IzzelAliz/Arclight) on NeoForge, Minecraft 1.21.1) inside Docker, through the [itzg/minecraft-server](https://docker-minecraft-server.readthedocs.io/) image. The image downloads Minecraft and keeps it updated for you. It's sized for a machine with about 4GB of RAM.

## Install (one command)

**Linux (Ubuntu/Debian VPS or PC):**

```bash
curl -fsSL https://raw.githubusercontent.com/2m3s/aaa/main/install.sh | bash
```

This installs git and Docker if they're missing, downloads this repo to `~/aaa`, sets random passwords, sizes the RAM to your machine and starts the server. Players connect to `YOUR-IP:25565`. At the end it prints the address and login for the web panel.

**Windows / Mac:** install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and [Git](https://git-scm.com/downloads), then run:

```bash
git clone https://github.com/2m3s/aaa && cd aaa && docker compose up -d
```

## Web panel

Open **`http://YOUR-SERVER-IP:8080`** in a browser on any PC or phone. Your login is `PANEL_USER` / `PANEL_PASSWORD` in `server.env`. Run `./mc web` on the server to see it again, or on Windows check `docker logs mc-panel`.

- **Console:** the live server log, plus a box to type commands (`op Name`, `whitelist add Name`, `say hi`…)
- **Mods / Plugins / Files:** upload by dragging files in, download, rename, delete, and edit config files in the browser
- **Settings:** edit `server.env`, then **Save & restart**
- **Restart** and **Backup** buttons at the top

Open TCP port 8080 on the server (see [Opening the ports](#opening-the-ports)). The panel is plain HTTP, so use a strong password. To use another port, put `PANEL_PORT=9000` in a file called `.env` next to `docker-compose.yml` and run `./mc restart`.

## Adding mods and plugins

Once the server has started for the first time, it creates the `data/` folder.

| What | Where | Must be built for |
|---|---|---|
| Mods | `data/mods/` | **NeoForge 1.21.1** |
| Plugins | `data/plugins/` | **Paper/Spigot 1.21.1** |

Download them from [Modrinth](https://modrinth.com/) or [CurseForge](https://www.curseforge.com/minecraft), drag the `.jar` files into the **Mods** or **Plugins** tab of the web panel, then click **Restart**.

Some mods are client-side as well (new blocks, items, mobs). Players then need the same mods installed in a **NeoForge 1.21.1** client. Plugins and server-only mods (performance, map pre-generation, etc.) don't need anything on the client.

## Managing the server (Linux/Mac)

```
./mc web                  show the web panel address and login
./mc start | stop | restart | status
./mc logs                 watch the console (Ctrl+C to leave)
./mc console              type server commands (exit to leave)
./mc cmd op YourName      run one command
./mc backup               save a backup into backups/
./mc update               update everything and restart
./mc memory 4G            change RAM
./mc mode <type>          change server type (see below)
```

On Windows, use `docker compose up -d`, `docker compose down`, `docker compose logs -f` and `docker exec -i mc rcon-cli`.

Settings like the MOTD, max players, difficulty, whitelist and ops live in **`server.env`**. It's created from `server.env.example` on the first start and isn't tracked by git, so `./mc update` never overwrites it. Edit it in the panel's **Settings** tab, or on the server followed by `./mc restart`.

## Server types

| `./mc mode …` | Runs | Minecraft version |
|---|---|---|
| `hybrid` (default) | NeoForge mods **+** plugins (Arclight) | 1.21.1 |
| `mohist` | Forge mods **+** plugins (Mohist). Try this if Arclight has issues, or if your modpack is Forge 1.20.1 | 1.20.1 |
| `paper` | Plugins only, the fastest and most stable | latest |
| `fabric` / `neoforge` / `forge` | Mods only | latest |
| `vanilla` | Neither | latest |

Switch over SSH with `./mc mode …`, not by editing `TYPE` in the panel: the command also picks the right Minecraft and Java versions. Make a backup before switching on a world you care about, and empty `data/mods` if the new mode uses a different loader or version.

## Tips for 4GB

- On a machine with exactly 4GB of RAM, the Java heap is set to **3G** and the rest is left for the OS. If the machine has 6GB or more, it gets 4G (`./mc memory 4G`).
- Keep it to roughly 30–50 light mods. Big modpacks (ATM, RLCraft…) want 6–10GB.
- Lower `VIEW_DISTANCE` / `SIMULATION_DISTANCE` in `server.env` if it lags.
- Good server-side performance mods (NeoForge): FerriteCore, ModernFix, Chunky (pre-generate the world).
- Hybrid servers are less battle-tested than plain Paper or plain NeoForge. Plugins that hook deep into the server internals, and mods that conflict with them, can break. If something misbehaves, remove the last thing you added.

## Opening the ports

TCP **25565** is for players and **8080** is for the web panel.

- **VPS:** `sudo ufw allow 25565/tcp && sudo ufw allow 8080/tcp` (the installer does this if ufw is on), plus your provider's firewall panel if it has one.
- **Home PC:** forward TCP 25565 on your router to this PC, or use a tunnel like [playit.gg](https://playit.gg). You only need 8080 on your home network.
