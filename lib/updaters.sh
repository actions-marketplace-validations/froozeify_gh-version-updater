#!/usr/bin/env bash
# lib/updaters.sh — file-specific version update logic for update-version.
#
# All functions that update files append the updated file path to the global
# UPDATED_FILES array defined in update-version.sh. Using a shared global
# (rather than echoing results back through a subshell) keeps log() output
# visible in the step log and avoids the risk of log lines being mixed into
# return values.

# Guard against double-sourcing.
[[ -n "${_UV_UPDATERS_LOADED:-}" ]] && return 0
readonly _UV_UPDATERS_LOADED=1

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

# Detect the indentation of an existing JSON file by examining the first
# indented line. Returns the number of spaces found, or 2 as a safe fallback.
detect_json_indent() {
  local file="$1"

  # grep --only-matching captures only the leading spaces, head takes the first match.
  local leading_spaces
  leading_spaces="$(grep --perl-regexp --only-matching '^ +' "${file}" | head --lines=1)"

  local indent="${#leading_spaces}"
  echo "${indent:-2}"
}

# Update the "version" key in a JSON file, preserving the file's own indentation.
# Returns 1 (without failing) if the file has no "version" field.
# $1 = file path  $2 = version string
update_json_version() {
  local file="$1"
  local version="$2"
  local tmp_file="${file}.update-version.tmp"

  if ! command -v jq > /dev/null 2>&1; then
    fail "jq is required to update ${file} but it is not installed."
  fi

  # Only proceed if the file actually declares a version field.
  if ! jq --exit-status '.version' "${file}" > /dev/null 2>&1; then
    warn "${file} has no 'version' field — skipping."
    return 1
  fi

  local indent
  indent="$(detect_json_indent "${file}")"
  log "  indent detected: ${indent} spaces"

  jq \
    --indent "${indent}" \
    --arg ver "${version}" \
    '.version = $ver' \
    "${file}" > "${tmp_file}"

  mv "${tmp_file}" "${file}"
}

# ---------------------------------------------------------------------------
# Plain-text helpers
# ---------------------------------------------------------------------------

# Replace the first line matching search_regex in a plain-text file.
# Uses ERE (--regexp-extended) so callers can write modern regex patterns.
# A temp file is used for cross-platform safety (BSD sed vs GNU sed differ on -i).
# $1 = file path  $2 = ERE search pattern  $3 = literal replacement string
update_text_version() {
  local file="$1"
  local search_regex="$2"
  local replacement="$3"
  local tmp_file="${file}.update-version.tmp"

  sed \
    --regexp-extended \
    "s|${search_regex}|${replacement}|" \
    "${file}" > "${tmp_file}"

  mv "${tmp_file}" "${file}"
}

# ---------------------------------------------------------------------------
# Auto-detection
# ---------------------------------------------------------------------------

# Scan the working directory for known config files and update each one found.
# Appends updated file paths to the global UPDATED_FILES array.
try_auto_detect() {
  local version="$1"

  # package.json
  if [[ -f "package.json" ]]; then
    log "Auto-detected package.json"
    if update_json_version "package.json" "${version}"; then
      UPDATED_FILES+=("package.json")
    fi
  fi

  # composer.json
  if [[ -f "composer.json" ]]; then
    log "Auto-detected composer.json"
    if update_json_version "composer.json" "${version}"; then
      UPDATED_FILES+=("composer.json")
    fi
  fi

  # pyproject.toml
  if [[ -f "pyproject.toml" ]]; then
    log "Auto-detected pyproject.toml"
    update_text_version \
      "pyproject.toml" \
      '^version = "[^"]*"' \
      "version = \"${version}\""
    UPDATED_FILES+=("pyproject.toml")
  fi

  # Cargo.toml
  if [[ -f "Cargo.toml" ]]; then
    log "Auto-detected Cargo.toml"
    update_text_version \
      "Cargo.toml" \
      '^version = "[^"]*"' \
      "version = \"${version}\""
    UPDATED_FILES+=("Cargo.toml")
  fi

  # pubspec.yaml
  if [[ -f "pubspec.yaml" ]]; then
    log "Auto-detected pubspec.yaml"
    update_text_version \
      "pubspec.yaml" \
      '^version: .*$' \
      "version: ${version}"
    UPDATED_FILES+=("pubspec.yaml")
  fi
}

# ---------------------------------------------------------------------------
# Explicit file list
# ---------------------------------------------------------------------------

# Update an explicit comma-separated list of files.
# Appends updated file paths to the global UPDATED_FILES array.
try_explicit_files() {
  local files_input="$1"
  local version="$2"

  # Split on commas; -r (raw) and -a (array) have no long forms in the bash built-in.
  IFS=',' read -ra file_list <<< "${files_input}"

  for raw_file in "${file_list[@]}"; do
    # Trim surrounding whitespace.
    local file
    file="$(echo "${raw_file}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${file}" ]] && continue

    if [[ ! -f "${file}" ]]; then
      fail "File not found: ${file}"
    fi

    case "${file}" in
      package.json | composer.json | *.json)
        log "Updating ${file}"
        if update_json_version "${file}" "${version}"; then
          UPDATED_FILES+=("${file}")
        fi
        ;;
      pyproject.toml | Cargo.toml)
        log "Updating ${file}"
        update_text_version \
          "${file}" \
          '^version = "[^"]*"' \
          "version = \"${version}\""
        UPDATED_FILES+=("${file}")
        ;;
      pubspec.yaml)
        log "Updating ${file}"
        update_text_version \
          "${file}" \
          '^version: .*$' \
          "version: ${version}"
        UPDATED_FILES+=("${file}")
        ;;
      *)
        fail "File '${file}' is not natively supported. Use 'custom-rules' for this file type."
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Custom rules
# ---------------------------------------------------------------------------

# Apply user-defined regex rules for any file format.
# Rule format (one per line):  file:search_regex:replacement_template
# A literal ':' inside search_regex or replacement_template must be escaped as '\:'
# (e.g. to match a YAML "version:" key). Lines starting with '#' and blank lines are skipped.
# Appends updated file paths to the global UPDATED_FILES array.
apply_custom_rules() {
  local rules_input="$1"
  local version="$2"
  # Unlikely to appear in a rule line; stands in for an escaped '\:' during splitting.
  local placeholder=$'\x01'

  # -r (raw) has no long form in the bash built-in.
  while IFS= read -r line; do
    # Trim surrounding whitespace.
    line="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Skip blank lines and comments.
    [[ -z "${line}" || "${line}" == \#* ]] && continue

    # Protect escaped colons so they survive the field split below, then split on
    # the first two remaining ':' (replacement_template may still contain unescaped ':').
    local escaped_line rule_file search_regex replacement_template
    escaped_line="${line//\\:/${placeholder}}"

    # --only-delimited: a line with no ':' at all yields empty fields (caught below)
    # instead of cut's default of passing the whole line through unchanged.
    rule_file="$(echo            "${escaped_line}" | cut --only-delimited --delimiter=':' --fields=1)"
    search_regex="$(echo         "${escaped_line}" | cut --only-delimited --delimiter=':' --fields=2)"
    replacement_template="$(echo "${escaped_line}" | cut --only-delimited --delimiter=':' --fields='3-')"

    rule_file="${rule_file//${placeholder}/:}"
    search_regex="${search_regex//${placeholder}/:}"
    replacement_template="${replacement_template//${placeholder}/:}"

    if [[ -z "${rule_file}" || -z "${search_regex}" || -z "${replacement_template}" ]]; then
      warn "Skipping malformed custom rule: ${line}"
      continue
    fi

    if [[ ! -f "${rule_file}" ]]; then
      fail "Custom rule references non-existent file: ${rule_file}"
    fi

    local replacement
    replacement="$(render_template "${replacement_template}" "${version}")"

    log "Applying custom rule to ${rule_file}"
    update_text_version "${rule_file}" "${search_regex}" "${replacement}"
    UPDATED_FILES+=("${rule_file}")

  done <<< "${rules_input}"
}
