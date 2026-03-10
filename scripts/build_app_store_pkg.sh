#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VibeGrid"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist}"
APP_PATH="${OUT_DIR}/${APP_NAME}.app"
PKG_PATH="${PKG_PATH:-${OUT_DIR}/${APP_NAME}-mac-app-store.pkg}"

BUNDLE_ID="${BUNDLE_ID:-com.vibegrid.app}"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
PROVISIONING_PROFILE_PATH="${PROVISIONING_PROFILE_PATH:-}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-${ROOT_DIR}/packaging/VibeGrid.mas.entitlements}"
ICON_FILE="${ICON_FILE:-}"

if [[ -z "${APP_SIGN_IDENTITY}" ]]; then
  echo "error: APP_SIGN_IDENTITY is required (Apple Distribution certificate)." >&2
  exit 1
fi

if [[ -z "${INSTALLER_SIGN_IDENTITY}" ]]; then
  echo "error: INSTALLER_SIGN_IDENTITY is required (Mac Installer Distribution certificate)." >&2
  exit 1
fi

if [[ -z "${PROVISIONING_PROFILE_PATH}" ]]; then
  echo "error: PROVISIONING_PROFILE_PATH is required." >&2
  exit 1
fi

if [[ ! -f "${PROVISIONING_PROFILE_PATH}" ]]; then
  echo "error: provisioning profile not found at ${PROVISIONING_PROFILE_PATH}" >&2
  exit 1
fi

if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
  echo "error: entitlements file not found at ${ENTITLEMENTS_PATH}" >&2
  exit 1
fi

echo "Building signed App Store app bundle..."
BUNDLE_ID="${BUNDLE_ID}" \
APP_VERSION="${APP_VERSION}" \
BUILD_VERSION="${BUILD_VERSION}" \
CODESIGN_IDENTITY="${APP_SIGN_IDENTITY}" \
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH}" \
EMBEDDED_PROVISIONPROFILE="${PROVISIONING_PROFILE_PATH}" \
ICON_FILE="${ICON_FILE}" \
ENABLE_HARDENED_RUNTIME=0 \
"${ROOT_DIR}/scripts/build_app.sh"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

echo "Creating App Store package..."
xcrun productbuild \
  --component "${APP_PATH}" /Applications \
  --sign "${INSTALLER_SIGN_IDENTITY}" \
  "${PKG_PATH}"

echo "Created package: ${PKG_PATH}"
echo "Validate signature with:"
echo "  pkgutil --check-signature \"${PKG_PATH}\""
