#!/usr/bin/env bash
# update-version.sh — entrypoint for the update-version GitHub Action.
# All inputs are received via environment variables (INPUT_*) set by action.yml.

set -euo pipefail

# Resolve the directory this script lives in so lib sourcing is path-independent.
ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${ACTION_DIR}/lib/tools.sh"
source "${ACTION_DIR}/lib/updaters.sh"

# Global array: updater functions in lib/updaters.sh append to this directly.
# Using a global avoids running updaters in subshells, which would swallow
# log() output and prevent log lines from appearing in the step log.
UPDATED_FILES=()

# ---------------------------------------------------------------------------
# Commit and push
# ---------------------------------------------------------------------------

commit_and_push() {
  local version="$1"
  local commit_message_template="$2"
  local commit_branch="$3"
  local author_name="$4"
  local author_email="$5"
  local token="$6"
  shift 6
  local files_to_commit=("$@")

  local commit_message
  commit_message="$(render_template "${commit_message_template}" "${version}")"

  step "Committing version bump"
  log "Author : ${author_name} <${author_email}>"
  log "Message: ${commit_message}"
  log "Branch : ${commit_branch}"
  log "Files  : ${files_to_commit[*]}"

  git config --local user.name  "${author_name}"
  git config --local user.email "${author_email}"

  git add -- "${files_to_commit[@]}"

  # If nothing changed (e.g. release was re-triggered), skip the commit gracefully.
  if git diff --cached --quiet; then
    log "Nothing to commit — files already at version ${version}."
    return
  fi

  git commit --message "${commit_message}"

  # Inject the token into the remote URL for an authenticated push.
  local remote_url auth_remote_url
  remote_url="$(git remote get-url origin)"
  auth_remote_url="${remote_url/https:\/\//https://x-access-token:${token}@}"

  git push "${auth_remote_url}" "HEAD:refs/heads/${commit_branch}"
  log "Pushed to ${commit_branch}."
}

# ---------------------------------------------------------------------------
# Step summary
# ---------------------------------------------------------------------------

# Write a markdown summary to the GitHub Actions job summary page.
# The summary is visible directly on the workflow run page — no need to expand
# individual steps. Skipped silently when running outside GitHub Actions.
write_step_summary() {
  local version="$1"
  local raw_version="$2"
  local did_commit="$3"
  local commit_branch="$4"
  shift 4
  local files=("$@")

  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return

  {
    echo "## update-version"
    echo ""
    echo "| | |"
    echo "|---|---|"
    echo "| **Tag** | \`${raw_version}\` |"
    echo "| **Version** | \`${version}\` |"

    if [[ "${did_commit}" == "true" ]]; then
      echo "| **Committed to** | \`${commit_branch}\` |"
    else
      echo "| **Committed** | Skipped (commit: false) |"
    fi

    echo ""
    echo "### Updated files"
    echo ""
    for file in "${files[@]}"; do
      echo "- \`${file}\`"
    done
  } >> "${GITHUB_STEP_SUMMARY}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local raw_version="${INPUT_VERSION}"
  local files_input="${INPUT_FILES}"
  local custom_rules="${INPUT_CUSTOM_RULES}"
  local do_commit="${INPUT_COMMIT}"
  local commit_message_template="${INPUT_COMMIT_MESSAGE}"
  local commit_branch="${INPUT_COMMIT_BRANCH}"
  local author_name="${INPUT_COMMIT_AUTHOR_NAME}"
  local author_email="${INPUT_COMMIT_AUTHOR_EMAIL}"
  local token="${INPUT_TOKEN}"

  # --- Resolve version ---
  step "Resolving version"
  local version
  version="$(strip_v_prefix "${raw_version}")"
  log "Tag    : ${raw_version}"
  log "Version: ${version}"

  if [[ -z "${version}" ]]; then
    fail "Resolved version is empty (input was '${raw_version}'). Refusing to update files."
  fi

  # --- Update files ---
  step "Updating files"

  if [[ "${files_input}" == "auto" ]]; then
    log "Mode: auto-detect"
    try_auto_detect "${version}"
  else
    log "Mode: explicit list"
    try_explicit_files "${files_input}" "${version}"
  fi

  # Custom rules run on top of built-in updates (or alone if files is explicit).
  if [[ -n "${custom_rules}" ]]; then
    step "Applying custom rules"
    apply_custom_rules "${custom_rules}" "${version}"
  fi

  if [[ ${#UPDATED_FILES[@]} -eq 0 ]]; then
    fail "No files were updated."
  fi

  log "Files updated: ${UPDATED_FILES[*]}"

  # --- Commit ---
  if [[ "${do_commit}" == "true" ]]; then
    commit_and_push \
      "${version}" \
      "${commit_message_template}" \
      "${commit_branch}" \
      "${author_name}" \
      "${author_email}" \
      "${token}" \
      "${UPDATED_FILES[@]}"
  else
    step "Skipping commit"
    log "commit: false — files updated but not committed."
  fi

  # --- Outputs ---
  echo "version=${version}"                  >> "${GITHUB_OUTPUT}"
  echo "files-updated=${UPDATED_FILES[*]}"   >> "${GITHUB_OUTPUT}"

  # --- Summary ---
  write_step_summary \
    "${version}" \
    "${raw_version}" \
    "${do_commit}" \
    "${commit_branch}" \
    "${UPDATED_FILES[@]}"

  step "Done"
  printf "${COLOR_GREEN}${COLOR_BOLD}✓ Version bumped to %s${COLOR_RESET}\n" "${version}"
}

main
