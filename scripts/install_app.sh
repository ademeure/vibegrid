#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE_NAME="${APP_BUNDLE_NAME:-VibeGrid.app}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.vibegrid.app}"
APP_PROCESS_NAME="${APP_PROCESS_NAME:-VibeGrid}"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build_app.sh"
SOURCE_APP="${ROOT_DIR}/dist/${APP_BUNDLE_NAME}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
LAUNCH_AFTER_INSTALL=1

usage() {
  cat <<'USAGE'
Usage: ./scripts/install_app.sh [options]

Builds VibeGrid, installs it to a stable app location (default: /Applications),
and launches it.

Options:
  --install-dir <path>  Install destination directory (default: /Applications)
  --no-launch           Do not launch the app after install
  -h, --help            Show this help
USAGE
}

is_app_running() {
  pgrep -x "${APP_PROCESS_NAME}" >/dev/null 2>&1
}

stop_running_app() {
  if ! is_app_running; then
    return 0
  fi

  echo "${APP_PROCESS_NAME} is running; attempting to quit before install..."
  osascript -e "tell application id \"${APP_BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true

  local waited=0
  while is_app_running && [[ ${waited} -lt 5 ]]; do
    sleep 1
    waited=$((waited + 1))
  done

  if is_app_running; then
    echo "${APP_PROCESS_NAME} is still running; force closing..."
    pkill -9 -x "${APP_PROCESS_NAME}" >/dev/null 2>&1 || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      if [[ $# -lt 2 ]]; then
        echo "error: --install-dir requires a value" >&2
        exit 1
      fi
      INSTALL_DIR="$2"
      shift 2
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

INSTALL_DIR="${INSTALL_DIR%/}"

# Validate install path to prevent path traversal with sudo rm -rf
if [[ "${INSTALL_DIR}" != /* ]]; then
  echo "error: --install-dir must be an absolute path" >&2
  exit 1
fi
if [[ "${INSTALL_DIR}" == *".."* ]]; then
  echo "error: --install-dir must not contain '..' components" >&2
  exit 1
fi

DEST_APP="${INSTALL_DIR}/${APP_BUNDLE_NAME}"

stop_running_app

if [[ -d "${DEST_APP}" ]]; then
  echo "Existing app detected at ${DEST_APP}; skipping Accessibility permission reset to preserve existing grant state."
fi

if [[ ! -x "${BUILD_SCRIPT}" ]]; then
  echo "error: build script not found or not executable: ${BUILD_SCRIPT}" >&2
  exit 1
fi

echo "Building app bundle..."
BUNDLE_ID="${APP_BUNDLE_ID}" \
"${BUILD_SCRIPT}"

if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "error: built app bundle not found at ${SOURCE_APP}" >&2
  exit 1
fi

PARENT_DIR="$(dirname "${INSTALL_DIR}")"

if [[ ! -d "${INSTALL_DIR}" ]]; then
  if [[ -w "${PARENT_DIR}" ]]; then
    mkdir -p "${INSTALL_DIR}"
  else
    echo "Creating ${INSTALL_DIR} requires admin privileges..."
    sudo mkdir -p "${INSTALL_DIR}"
  fi
fi

if [[ -w "${INSTALL_DIR}" ]]; then
  rm -rf "${DEST_APP}"
  ditto "${SOURCE_APP}" "${DEST_APP}"
else
  echo "Installing to ${INSTALL_DIR} requires admin privileges..."
  sudo rm -rf "${DEST_APP}"
  sudo ditto "${SOURCE_APP}" "${DEST_APP}"
fi

echo "Installed: ${DEST_APP}"

if [[ ${LAUNCH_AFTER_INSTALL} -eq 1 ]]; then
  open "${DEST_APP}"
  echo "Launched: ${DEST_APP}"
fi

echo
echo "Next steps (UI, not shell commands):"
echo "- In VibeGrid > Settings, enable \"Launch VibeGrid automatically at login\"."
echo "- In System Settings > Privacy & Security > Accessibility, ensure ${DEST_APP} is enabled."
