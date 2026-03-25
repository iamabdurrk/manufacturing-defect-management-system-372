#!/usr/bin/env bash
set -euo pipefail

# Startup entrypoint for the database container.
# Runs MongoDB provisioning (collections/indexes/seed) and then starts any auxiliary services
# (e.g., db_visualizer) that ship with this container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[database] Running provisioning..."
# Provisioning may fail if Mongo is not reachable yet; in that case exit non-zero to surface error early.
bash "${SCRIPT_DIR}/provision_mongodb.sh"

# Start db visualizer if present (non-blocking is not required here; container entrypoint can block).
if [[ -f "${SCRIPT_DIR}/db_visualizer/server.js" ]]; then
  echo "[database] Starting db_visualizer..."
  cd "${SCRIPT_DIR}/db_visualizer"
  if [[ -f package.json ]]; then
    # Avoid interactive output; install deps only if node_modules missing.
    if [[ ! -d node_modules ]]; then
      npm ci --silent
    fi
  fi
  node server.js
else
  echo "[database] No db_visualizer found; startup complete."
  tail -f /dev/null
fi
