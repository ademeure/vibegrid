#!/usr/bin/env bash
# Run VibeGrid in dev mode as a proper .app bundle.
#
# WHY: `make dev` (swift run) produces a raw binary with no .app bundle.
# macOS requires a .app bundle for NSStatusItem to appear in the menu bar
# and for computer-use MCP to see the process. This script builds a debug
# .app bundle and launches it, killing any existing instance first.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Killing any running VibeGrid instances..."
pkill -x VibeGrid 2>/dev/null && sleep 0.5 || true

echo "==> Building debug .app bundle..."
CONFIGURATION=debug "${ROOT_DIR}/scripts/build_app.sh"

echo "==> Launching dist/VibeGrid.app..."
open "${ROOT_DIR}/dist/VibeGrid.app"

echo "==> Done. VibeGrid (debug) is running."
