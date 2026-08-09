#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
derived_data_path="${MARKDOWN_READER_DERIVED_DATA_PATH:-${project_root}/.derivedData-release}"
artifact_dir="${MARKDOWN_READER_ARTIFACT_DIR:-${project_root}/Build}"
product_name="Markdown Reader.app"
built_product="${derived_data_path}/Build/Products/Release/${product_name}"
artifact_path="${artifact_dir}/${product_name}"

replace_bundle() {
  local source_path="$1"
  local destination_path="$2"
  local destination_parent="${destination_path:h}"
  local stage_root
  local staged_path
  local backup_root=""
  local backup_path=""

  /bin/mkdir -p "${destination_parent}"
  stage_root="$(/usr/bin/mktemp -d "${destination_parent}/.markdown-reader-stage.XXXXXX")"
  staged_path="${stage_root}/${product_name}"

  /usr/bin/ditto "${source_path}" "${staged_path}"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${staged_path}"

  if [[ -e "${destination_path}" || -L "${destination_path}" ]]; then
    backup_root="$(/usr/bin/mktemp -d "${destination_parent}/.markdown-reader-backup.XXXXXX")"
    backup_path="${backup_root}/${product_name}"
    /bin/mv "${destination_path}" "${backup_path}"
  fi

  if ! /bin/mv "${staged_path}" "${destination_path}"; then
    if [[ -n "${backup_path}" && -e "${backup_path}" ]]; then
      /bin/mv "${backup_path}" "${destination_path}"
    fi
    print -u2 "Could not install the staged bundle. Staging data remains at: ${stage_root}"
    return 1
  fi
  /bin/rmdir "${stage_root}"

  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "${destination_path}"; then
    if [[ -n "${backup_path}" && -e "${backup_path}" ]]; then
      /bin/mv "${destination_path}" "${stage_root}"
      /bin/mv "${backup_path}" "${destination_path}"
      print -u2 "Verification failed; the previous bundle was restored. Failed bundle: ${stage_root}"
    fi
    return 1
  fi

  if [[ -n "${backup_root}" ]]; then
    case "${backup_root}" in
      "${destination_parent}"/.markdown-reader-backup.*)
        /bin/rm -rf "${backup_root}"
        ;;
      *)
        print -u2 "Refusing to remove unexpected backup path: ${backup_root}"
        return 1
        ;;
    esac
  fi
}

/usr/bin/xcodebuild \
  -project "${project_root}/MarkdownReader.xcodeproj" \
  -scheme MarkdownReader \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${derived_data_path}" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build

if [[ ! -d "${built_product}" ]]; then
  print -u2 "Expected build product was not created: ${built_product}"
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "${built_product}"

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${built_product}/Contents/Info.plist")"
if [[ "${bundle_identifier}" != "com.cchen.MarkdownReader" ]]; then
  print -u2 "Unexpected bundle identifier: ${bundle_identifier}"
  exit 1
fi

if [[ ! -x "${built_product}/Contents/MacOS/Markdown Reader" ]]; then
  print -u2 "The app executable is missing from the Release product."
  exit 1
fi

if [[ ! -d "${built_product}/Contents/PlugIns/Markdown Quick Look.appex" ]]; then
  print -u2 "The Quick Look extension is missing from the Release product."
  exit 1
fi

replace_bundle "${built_product}" "${artifact_path}"

print "Release artifact ready: ${artifact_path}"
print "Signing: local ad hoc (no Apple Developer credentials or notarization)"
