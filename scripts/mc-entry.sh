#!/bin/bash
# Start script for the Minecraft container. Loads server.env fresh on every start,
# so settings saved in the web panel apply after a restart.
f=/aaa/server.env
for _ in $(seq 1 15); do [ -f "$f" ] && break; sleep 1; done  # the panel creates it on a fresh install
[ -f "$f" ] || f=/aaa/server.env.example
echo "Loading settings from ${f#/aaa/}"
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in ''|'#'*) continue ;; esac
  key=${line%%=*}
  [[ "$line" == *=* && "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  val=${line#*=}
  if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
  export "$key=$val"
done < "$f"
exec /image/scripts/start "$@"
