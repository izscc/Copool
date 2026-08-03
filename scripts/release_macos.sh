#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="${PROJECT_PATH:-Copool.xcodeproj}"
SCHEME="${SCHEME:-Copool}"
CONFIGURATION="${CONFIGURATION:-Release}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-KLU8GF65GP}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Ning Huang (KLU8GF65GP)}"
WORK_ROOT="${WORK_ROOT:-}"
KEEP_WORK_ROOT="${KEEP_WORK_ROOT:-0}"
RELEASE_ROOT="${RELEASE_ROOT:-}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.alick.copool}"
APP_ENTITLEMENTS_PATH="${APP_ENTITLEMENTS_PATH:-$ROOT_DIR/Copool.release.entitlements}"
PLUGIN_ENTITLEMENTS_PATH="${PLUGIN_ENTITLEMENTS_PATH:-$ROOT_DIR/CopoolWidgetsMac.entitlements}"
NOTARIZE_WITH="${NOTARIZE_WITH:-auto}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
CREATE_GITHUB_RELEASE="${CREATE_GITHUB_RELEASE:-0}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-izscc/Copool}"
GH_RELEASE_NOTES="${GH_RELEASE_NOTES:-}"

log() {
  printf '[release_macos] %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

ensure_clean_dir() {
  rm -rf "$1"
  mkdir -p "$1"
}

cleanup_work_root() {
  if [[ "${KEEP_WORK_ROOT}" == "1" || -z "${WORK_ROOT:-}" ]]; then
    if [[ -n "${STAGE_ROOT:-}" && "${STAGE_ROOT}" == "${TMPDIR:-/tmp}"/copool-stage.* ]]; then
      rm -rf "$STAGE_ROOT"
    fi
    return
  fi

  if [[ -n "${STAGE_ROOT:-}" && "$STAGE_ROOT" != "$WORK_ROOT"/* ]]; then
    rm -rf "$STAGE_ROOT"
  fi
  rm -rf "$WORK_ROOT"
}

decode_profile_to_plist() {
  local profile_path="$1"
  local plist_path="$2"

  security cms -D -i "$profile_path" >"$plist_path" 2>/dev/null
}

extract_plist_value() {
  local plist_path="$1"
  local key_path="$2"

  /usr/libexec/PlistBuddy -c "Print ${key_path}" "$plist_path" 2>/dev/null
}

resolve_provisioning_profile_specifier() {
  resolve_provisioning_profile_specifier_for_bundle_id "$PRODUCT_BUNDLE_IDENTIFIER"
}

resolve_provisioning_profile_specifier_for_bundle_id() {
  local bundle_id="$1"
  local profile_dir
  local profile_path
  local plist_path
  local name
  local team_id
  local app_identifier
  local provisions_all_devices
  local bundle_identifier_suffix
  local tmp_dir

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/copool-profile-scan.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' RETURN

  for profile_dir in \
    "$HOME/Library/MobileDevice/Provisioning Profiles" \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  do
    [[ -d "$profile_dir" ]] || continue

    while IFS= read -r -d '' profile_path; do
      plist_path="$tmp_dir/profile.plist"
      decode_profile_to_plist "$profile_path" "$plist_path" || continue

      name="$(extract_plist_value "$plist_path" ":Name")"
      team_id="$(extract_plist_value "$plist_path" ":TeamIdentifier:0")"
      app_identifier="$(extract_plist_value "$plist_path" ":Entitlements:com.apple.application-identifier")"
      provisions_all_devices="$(extract_plist_value "$plist_path" ":ProvisionsAllDevices")"

      if [[ -z "$name" || -z "$team_id" || -z "$app_identifier" ]]; then
        continue
      fi

      if [[ "$team_id" != "$DEVELOPMENT_TEAM" ]]; then
        continue
      fi

      if [[ "$provisions_all_devices" != "true" ]]; then
        continue
      fi

      bundle_identifier_suffix="${app_identifier#${team_id}.}"
      if [[ "$bundle_identifier_suffix" == "$bundle_id" && "$name" == *"Developer ID"* ]]; then
        printf '%s' "$name"
        return 0
      fi
    done < <(find "$profile_dir" -maxdepth 1 \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print0)
  done

  return 1
}

resolve_profile_path_by_name() {
  local expected_name="$1"
  local profile_dir
  local profile_path
  local plist_path
  local name
  local tmp_dir

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/copool-profile-path.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' RETURN

  for profile_dir in \
    "$HOME/Library/MobileDevice/Provisioning Profiles" \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  do
    [[ -d "$profile_dir" ]] || continue

    while IFS= read -r -d '' profile_path; do
      plist_path="$tmp_dir/profile.plist"
      decode_profile_to_plist "$profile_path" "$plist_path" || continue
      name="$(extract_plist_value "$plist_path" ":Name")"
      if [[ "$name" == "$expected_name" ]]; then
        printf '%s' "$profile_path"
        return 0
      fi
    done < <(find "$profile_dir" -maxdepth 1 \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print0)
  done

  return 1
}

pick_notarization_backend() {
  case "$NOTARIZE_WITH" in
    asc|notarytool|skip)
      printf '%s' "$NOTARIZE_WITH"
      ;;
    auto)
      if command -v asc >/dev/null 2>&1 && asc auth status >/dev/null 2>&1; then
        printf 'asc'
      elif [[ -n "$NOTARY_PROFILE" ]]; then
        printf 'notarytool'
      else
        printf 'skip'
      fi
      ;;
    *)
      printf 'Invalid NOTARIZE_WITH value: %s\n' "$NOTARIZE_WITH" >&2
      exit 1
      ;;
  esac
}

embed_profile_if_found() {
  local bundle_id="$1"
  local target_path="$2"
  local profile_name
  local profile_path

  if ! profile_name="$(resolve_provisioning_profile_specifier_for_bundle_id "$bundle_id")"; then
    log "No Developer ID provisioning profile found for $bundle_id; continuing without embedded profile"
    return 0
  fi

  if ! profile_path="$(resolve_profile_path_by_name "$profile_name")"; then
    printf 'Unable to resolve profile path for %s\n' "$profile_name" >&2
    exit 1
  fi

  cp "$profile_path" "$target_path/Contents/embedded.provisionprofile"
}

sanitize_app_bundle() {
  local source_app="$1"
  local staged_app="$2"

  rm -rf "$staged_app"
  mkdir -p "$(dirname "$staged_app")"
  /usr/bin/ditto --norsrc --noqtn "$source_app" "$staged_app"
  xattr -cr "$staged_app"
}

sign_app_bundle() {
  local app_path="$1"
  local app_bundle_id
  local plugin_path
  local plugin_bundle_id

  app_bundle_id="$(defaults read "$app_path/Contents/Info" CFBundleIdentifier)"
  embed_profile_if_found "$app_bundle_id" "$app_path"

  while IFS= read -r -d '' plugin_path; do
    plugin_bundle_id="$(defaults read "$plugin_path/Contents/Info" CFBundleIdentifier)"
    embed_profile_if_found "$plugin_bundle_id" "$plugin_path"
    codesign \
      --force \
      --sign "$CODESIGN_IDENTITY" \
      --timestamp \
      --options runtime \
      --entitlements "$PLUGIN_ENTITLEMENTS_PATH" \
      "$plugin_path"
  done < <(find "$app_path/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0 2>/dev/null || true)

  codesign \
    --force \
    --sign "$CODESIGN_IDENTITY" \
    --timestamp \
    --options runtime \
    --entitlements "$APP_ENTITLEMENTS_PATH" \
    "$app_path"
}

release_notes() {
  if [[ -n "$GH_RELEASE_NOTES" ]]; then
    printf '%s' "$GH_RELEASE_NOTES"
    return
  fi

  cat <<EOF
macOS release for Copool ${APP_VERSION}.

Notes:
- Built from commit ${GIT_COMMIT}.
- Signed with ${CODESIGN_IDENTITY}.
- Notarization backend: ${NOTARIZATION_BACKEND}.
EOF
}

if [[ -z "$WORK_ROOT" ]]; then
  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/copool-release.XXXXXX")"
fi

if [[ -z "$RELEASE_ROOT" ]]; then
  RELEASE_ROOT="$WORK_ROOT/release"
fi

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$WORK_ROOT/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$WORK_ROOT/$SCHEME.xcarchive}"
STAGE_ROOT="${STAGE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/copool-stage.XXXXXX")}"

trap cleanup_work_root EXIT

require_command xcodebuild
require_command codesign
require_command ditto
require_command plutil
require_command shasum
require_command xattr
require_command defaults

NOTARIZATION_BACKEND="$(pick_notarization_backend)"
GIT_COMMIT="$(git rev-parse HEAD)"

if [[ "$NOTARIZATION_BACKEND" == "asc" ]]; then
  require_command asc
fi

if [[ "$NOTARIZATION_BACKEND" == "notarytool" ]]; then
  require_command xcrun
  if [[ -z "$NOTARY_PROFILE" ]]; then
    printf 'NOTARY_PROFILE is required when NOTARIZE_WITH=notarytool\n' >&2
    exit 1
  fi
fi
require_command xcrun

log "Preparing release directories"
ensure_clean_dir "$RELEASE_ROOT"
mkdir -p "$WORK_ROOT"
rm -rf "$DERIVED_DATA_PATH" "$ARCHIVE_PATH" "$STAGE_ROOT"

ARCHIVE_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -destination "generic/platform=macOS"
  archive
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
)

log "Archiving unsigned macOS app"
xcodebuild "${ARCHIVE_ARGS[@]}"

ARCHIVED_APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "$ARCHIVED_APP_PATH" ]]; then
  printf 'No archived .app bundle found in %s\n' "$ARCHIVE_PATH/Products/Applications" >&2
  exit 1
fi

APP_PATH="$STAGE_ROOT/$(basename "$ARCHIVED_APP_PATH")"
sanitize_app_bundle "$ARCHIVED_APP_PATH" "$APP_PATH"
log "Signing sanitized app bundle in temporary staging area"
sign_app_bundle "$APP_PATH"

log "Verifying code signature"
codesign --verify --deep --strict --verbose=5 "$APP_PATH"
codesign -dvvv "$APP_PATH" >/dev/null

APP_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
APP_BUILD="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)"
APP_NAME="$(basename "$APP_PATH" .app)"
ZIP_NAME="${APP_NAME}-${APP_VERSION}-macOS-signed.zip"
ZIP_PATH="$RELEASE_ROOT/$ZIP_NAME"
SHA_PATH="$ZIP_PATH.sha256"
SIGNED_ZIP_PATH="$ZIP_PATH"
SIGNED_SHA_PATH="$SHA_PATH"

log "Packaging release zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
printf '  %s  %s\n' "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')" "$(basename "$ZIP_PATH")" >"$SHA_PATH"

case "$NOTARIZATION_BACKEND" in
  asc)
    log "Submitting zip for notarization with asc"
    asc notarization submit --file "$ZIP_PATH" --wait
    log "Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    ZIP_NAME="${APP_NAME}-${APP_VERSION}-macOS-notarized.zip"
    ZIP_PATH="$RELEASE_ROOT/$ZIP_NAME"
    SHA_PATH="$ZIP_PATH.sha256"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    printf '  %s  %s\n' "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')" "$(basename "$ZIP_PATH")" >"$SHA_PATH"
    rm -f "$SIGNED_ZIP_PATH" "$SIGNED_SHA_PATH"
    ;;
  notarytool)
    log "Submitting zip for notarization with notarytool profile '$NOTARY_PROFILE'"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    log "Stapling notarization ticket"
    xcrun stapler staple "$APP_PATH"
    ZIP_NAME="${APP_NAME}-${APP_VERSION}-macOS-notarized.zip"
    ZIP_PATH="$RELEASE_ROOT/$ZIP_NAME"
    SHA_PATH="$ZIP_PATH.sha256"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    printf '  %s  %s\n' "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')" "$(basename "$ZIP_PATH")" >"$SHA_PATH"
    rm -f "$SIGNED_ZIP_PATH" "$SIGNED_SHA_PATH"
    ;;
  skip)
    log "Skipping notarization"
    ;;
esac

if [[ "$CREATE_GITHUB_RELEASE" == "1" ]]; then
  require_command gh
  TAG="v${APP_VERSION}"
  TITLE="Copool ${APP_VERSION}"
  NOTES_FILE="$RELEASE_ROOT/release-notes.txt"
  release_notes >"$NOTES_FILE"

  if gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    log "Uploading assets to existing GitHub release $TAG"
    gh release upload "$TAG" "$ZIP_PATH" "$SHA_PATH" --clobber --repo "$GITHUB_REPOSITORY"
  else
    log "Creating GitHub release $TAG"
    gh release create \
      "$TAG" \
      "$ZIP_PATH" \
      "$SHA_PATH" \
      --repo "$GITHUB_REPOSITORY" \
      --target "$GIT_COMMIT" \
      --title "$TITLE" \
      --notes-file "$NOTES_FILE"
  fi
fi

log "Done"
log "Version: ${APP_VERSION} (${APP_BUILD})"
log "App: $APP_PATH"
log "Zip: $ZIP_PATH"
log "SHA256: $SHA_PATH"
