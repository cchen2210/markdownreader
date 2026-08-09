#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
artifact_path="${MARKDOWN_READER_ARTIFACT_PATH:-${project_root}/Build/Markdown Reader.app}"
install_root="${MARKDOWN_READER_INSTALL_ROOT:-${HOME}/Applications}"
installed_path="${install_root}/Markdown Reader.app"
launch_services_register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

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
  staged_path="${stage_root}/Markdown Reader.app"

  /usr/bin/ditto "${source_path}" "${staged_path}"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${staged_path}"

  if [[ -e "${destination_path}" || -L "${destination_path}" ]]; then
    backup_root="$(/usr/bin/mktemp -d "${destination_parent}/.markdown-reader-backup.XXXXXX")"
    backup_path="${backup_root}/Markdown Reader.app"
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

if [[ ! -d "${artifact_path}" ]]; then
  print -u2 "Release artifact not found: ${artifact_path}"
  print -u2 "Run Scripts/build-release.sh first."
  exit 1
fi

if /usr/bin/pgrep -x 'Markdown Reader' >/dev/null 2>&1; then
  print -u2 "Quit Markdown Reader before updating the installed app."
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "${artifact_path}"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${artifact_path}/Contents/Info.plist")"
if [[ "${bundle_identifier}" != "com.cchen.MarkdownReader" ]]; then
  print -u2 "Unexpected bundle identifier: ${bundle_identifier}"
  exit 1
fi

replace_bundle "${artifact_path}" "${installed_path}"

if [[ -x "${launch_services_register}" ]]; then
  "${launch_services_register}" -f -R -trusted "${installed_path}"
fi

print "Installed Markdown Reader at: ${installed_path}"
print "The stable install path can now be selected with Settings > General > Make Default."
