#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VibeGrid"
APP_BUNDLE_NAME="${APP_NAME}.app"
CONFIGURATION="${CONFIGURATION:-release}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist}"
BUNDLE_ID="${BUNDLE_ID:-${APP_BUNDLE_ID:-com.vibegrid.app}}"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-13.0}"
APP_CATEGORY="${APP_CATEGORY:-public.app-category.productivity}"
COPYRIGHT_TEXT="${COPYRIGHT_TEXT:-Copyright (c) 2026 VibeGrid. All rights reserved.}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
AUTO_SELECT_CODESIGN_IDENTITY="${AUTO_SELECT_CODESIGN_IDENTITY:-1}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-}"
EMBEDDED_PROVISIONPROFILE="${EMBEDDED_PROVISIONPROFILE:-}"
ICON_FILE="${ICON_FILE:-${ROOT_DIR}/Sources/VibeGrid/Resources/AppIcon.icns}"
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-0}"

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

export CLANG_MODULE_CACHE_PATH="${ROOT_DIR}/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="${ROOT_DIR}/.build/ModuleCache"

swift build --configuration "${CONFIGURATION}" --disable-sandbox
BIN_DIR="$(swift build --configuration "${CONFIGURATION}" --disable-sandbox --show-bin-path 2>/dev/null)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "error: built executable not found at ${BIN_PATH}" >&2
  exit 1
fi

APP_DIR="${OUT_DIR}/${APP_BUNDLE_NAME}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Copy ALL SwiftPM resource bundles (VibeGrid + ITermActivityKit etc.)
BUNDLE_COUNT=0
for bundle in "${BIN_DIR}"/*.bundle; do
  [[ -d "${bundle}" ]] || continue
  cp -R "${bundle}" "${APP_DIR}/Contents/Resources/"
  echo "Bundled: $(basename "${bundle}")"
  BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done
if [[ "${BUNDLE_COUNT}" -eq 0 ]]; then
  echo "error: no SwiftPM resource bundles found in ${BIN_DIR}" >&2
  exit 1
fi

ICON_PLIST_ENTRIES=""
if [[ -n "${ICON_FILE}" ]]; then
  if [[ ! -f "${ICON_FILE}" ]]; then
    echo "error: icon file not found at ${ICON_FILE}" >&2
    exit 1
  fi
  ICON_BASENAME="$(basename "${ICON_FILE}")"
  cp "${ICON_FILE}" "${APP_DIR}/Contents/Resources/${ICON_BASENAME}"
  ICON_BASENAME_XML="$(xml_escape "${ICON_BASENAME}")"
  ICON_PLIST_ENTRIES=$(
    cat <<ICONPLIST
  <key>CFBundleIconFile</key>
  <string>${ICON_BASENAME_XML}</string>
ICONPLIST
  )
fi

if [[ -n "${EMBEDDED_PROVISIONPROFILE}" ]]; then
  if [[ ! -f "${EMBEDDED_PROVISIONPROFILE}" ]]; then
    echo "error: provisioning profile not found at ${EMBEDDED_PROVISIONPROFILE}" >&2
    exit 1
  fi
  cp "${EMBEDDED_PROVISIONPROFILE}" "${APP_DIR}/Contents/embedded.provisionprofile"
fi

APP_NAME_XML="$(xml_escape "${APP_NAME}")"
BUNDLE_ID_XML="$(xml_escape "${BUNDLE_ID}")"
APP_VERSION_XML="$(xml_escape "${APP_VERSION}")"
BUILD_VERSION_XML="$(xml_escape "${BUILD_VERSION}")"
APP_CATEGORY_XML="$(xml_escape "${APP_CATEGORY}")"
MIN_SYSTEM_VERSION_XML="$(xml_escape "${MIN_SYSTEM_VERSION}")"
COPYRIGHT_TEXT_XML="$(xml_escape "${COPYRIGHT_TEXT}")"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME_XML}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME_XML}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID_XML}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME_XML}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION_XML}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_VERSION_XML}</string>
  <key>LSApplicationCategoryType</key>
  <string>${APP_CATEGORY_XML}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION_XML}</string>
  <key>LSUIElement</key>
  <${VIBEGRID_LSUIELEMENT:-true}/>
  <key>NSHumanReadableCopyright</key>
  <string>${COPYRIGHT_TEXT_XML}</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
${ICON_PLIST_ENTRIES}
</dict>
</plist>
PLIST

if [[ -n "${ENTITLEMENTS_PATH}" && ! -f "${ENTITLEMENTS_PATH}" ]]; then
  echo "error: entitlements file not found at ${ENTITLEMENTS_PATH}" >&2
  exit 1
fi

list_codesign_identities() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/^[[:space:]]*[0-9]+\)/ && NF >= 2 {
        line = $1
        sub(/^[[:space:]]*[0-9]+\)[[:space:]]*/, "", line)
        split(line, parts, /[[:space:]]+/)
        if (parts[1] != "") {
          print parts[1] "\t" $2
        }
      }'
}

resolve_codesign_identity_hash() {
  local identities
  identities="$(list_codesign_identities)"
  if [[ -z "${identities}" ]]; then
    return 0
  fi

  while IFS=$'\t' read -r hash name; do
    case "${name}" in
      "Developer ID Application:"*|"Apple Development:"*|"Sign to Run Locally"*|"Mac Developer:"*|"VibeGrid Local Code Signing"*)
        echo "${hash}"
        return 0
        ;;
    esac
  done <<< "${identities}"

  echo "${identities}" | head -n 1 | cut -f1
}

codesign_identity_name_for_hash() {
  local wanted_hash="${1:-}"
  if [[ -z "${wanted_hash}" ]]; then
    return 0
  fi

  while IFS=$'\t' read -r hash name; do
    if [[ "${hash}" == "${wanted_hash}" ]]; then
      echo "${name}"
      return 0
    fi
  done < <(list_codesign_identities)
}

if [[ -z "${CODESIGN_IDENTITY}" ]]; then
  if [[ "${AUTO_SELECT_CODESIGN_IDENTITY}" == "1" ]]; then
    SELECTED_IDENTITY_HASH="$(resolve_codesign_identity_hash)"
    if [[ -n "${SELECTED_IDENTITY_HASH}" ]]; then
      CODESIGN_IDENTITY="${SELECTED_IDENTITY_HASH}"
      SELECTED_IDENTITY_NAME="$(codesign_identity_name_for_hash "${SELECTED_IDENTITY_HASH}")"
      if [[ -n "${SELECTED_IDENTITY_NAME}" ]]; then
        echo "Using selected signing identity: ${SELECTED_IDENTITY_NAME} (${SELECTED_IDENTITY_HASH})"
      else
        echo "Using selected signing identity hash: ${SELECTED_IDENTITY_HASH}"
      fi
    else
      CODESIGN_IDENTITY="-"
      echo "No codesigning certificate found; falling back to ad-hoc signing (-)."
      echo "Tip: run ./scripts/setup_local_codesign_identity.sh once to create a stable local identity."
    fi
  else
    CODESIGN_IDENTITY="-"
  fi
elif [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "Using explicit ad-hoc signing (-)."
fi

if [[ "${CODESIGN_IDENTITY}" != "-" ]]; then
  CODESIGN_IDENTITY_NAME="$(codesign_identity_name_for_hash "${CODESIGN_IDENTITY}")"
  if [[ -n "${CODESIGN_IDENTITY_NAME}" ]]; then
    echo "Signing identity: ${CODESIGN_IDENTITY_NAME} (${CODESIGN_IDENTITY})"
  else
    echo "Signing identity: ${CODESIGN_IDENTITY}"
  fi
else
  echo "Signing identity: ad-hoc (-)"
fi

CODESIGN_ARGS=(--force --deep --sign "${CODESIGN_IDENTITY}")
if [[ -n "${ENTITLEMENTS_PATH}" ]]; then
  CODESIGN_ARGS+=(--entitlements "${ENTITLEMENTS_PATH}")
fi
if [[ "${ENABLE_HARDENED_RUNTIME}" == "1" ]]; then
  CODESIGN_ARGS+=(--options runtime)
fi

codesign "${CODESIGN_ARGS[@]}" "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

echo "Built app bundle: ${APP_DIR}"
echo "Launch with: open \"${APP_DIR}\""
echo "Accessibility permissions will apply to this app bundle identity."
