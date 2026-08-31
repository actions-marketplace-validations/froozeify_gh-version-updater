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

# Fixed constant, not an input: attributes a commit to this action in its body without needing
# a fake author identity. Never versioned (no "@ref") so there's nothing to maintain as tags move.
readonly COMMIT_TRAILER="Generated-by: froozeify/gh-version-updater"

# ---------------------------------------------------------------------------
# Commit and push (git method — local git commit + push, e.g. for SSH remotes)
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

  git commit --message "${commit_message}" --message "${COMMIT_TRAILER}"

  # Inject the token into the remote URL for an authenticated push.
  local remote_url auth_remote_url
  remote_url="$(git remote get-url origin)"
  auth_remote_url="${remote_url/https:\/\//https://x-access-token:${token}@}"

  git push "${auth_remote_url}" "HEAD:refs/heads/${commit_branch}"
  log "Pushed to ${commit_branch}."
}

# ---------------------------------------------------------------------------
# Commit via API (default method — GitHub's createCommitOnBranch GraphQL mutation)
#
# GitHub signs the commit server-side (shows as Verified) and the author is always the
# identity behind ${token} — it can't be spoofed via commit-author-name/email. Relies on
# `git` only to detect "nothing changed" (the checkout is already at the branch tip, so a
# local diff is an accurate proxy for a remote one); the commit itself never touches .git.
# ---------------------------------------------------------------------------

commit_via_api() {
  local version="$1"
  local commit_message_template="$2"
  local commit_branch="$3"
  local token="$4"
  shift 4
  local files_to_commit=("$@")

  local commit_message
  commit_message="$(render_template "${commit_message_template}" "${version}")"

  step "Committing version bump (via GitHub API)"
  log "Message: ${commit_message}"
  log "Branch : ${commit_branch}"
  log "Files  : ${files_to_commit[*]}"

  git add -- "${files_to_commit[@]}"
  if git diff --cached --quiet; then
    log "Nothing to commit — files already at version ${version}."
    return
  fi

  local owner="${GITHUB_REPOSITORY%%/*}"
  local repo="${GITHUB_REPOSITORY##*/}"
  local api_url="https://api.github.com"
  local auth_header="Authorization: bearer ${token}"
  local accept_header="Accept: application/vnd.github+json"

  # File contents are fixed once (a direct field replacement, not a diff against remote
  # state), so a conflict retry only needs a fresh head oid — not to recompute this.
  local additions="[]"
  local file encoded
  for file in "${files_to_commit[@]}"; do
    encoded="$(base64 -w0 "${file}")"
    additions="$(jq -n --argjson acc "${additions}" --arg path "${file}" --arg contents "${encoded}" \
      '$acc + [{path: $path, contents: $contents}]')"
  done

  local attempt head_oid request_body response errors
  for attempt in 1 2 3; do
    head_oid="$(curl -fsS -H "${auth_header}" -H "${accept_header}" \
      "${api_url}/repos/${owner}/${repo}/branches/${commit_branch}" | jq -r '.commit.sha')"

    request_body="$(jq -n \
      --arg owner "${owner}" --arg repo "${repo}" --arg branch "${commit_branch}" \
      --arg oid "${head_oid}" --arg headline "${commit_message}" --arg body "${COMMIT_TRAILER}" \
      --argjson additions "${additions}" \
      '{
        query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid url } } }",
        variables: { input: {
          branch: { repositoryNameWithOwner: ($owner + "/" + $repo), branchName: $branch },
          expectedHeadOid: $oid,
          message: { headline: $headline, body: $body },
          fileChanges: { additions: $additions }
        } }
      }')"

    response="$(curl -sS -X POST \
      -H "${auth_header}" -H "${accept_header}" -H "Content-Type: application/json" \
      -d "${request_body}" "${api_url}/graphql")"

    errors="$(echo "${response}" | jq -c '.errors // empty')"

    if [[ -z "${errors}" ]]; then
      local oid
      oid="$(echo "${response}" | jq -r '.data.createCommitOnBranch.commit.oid')"
      log "Pushed to ${commit_branch} (${oid})."
      return
    fi

    if [[ "${attempt}" -lt 3 ]] && echo "${errors}" | grep -qiE 'expected|does not match|changed'; then
      warn "Branch ${commit_branch} moved while committing — retrying (attempt ${attempt}/3)."
      continue
    fi

    fail "createCommitOnBranch failed: ${errors}"
  done
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
  local action_ref="$5"
  shift 5
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

    [[ -n "${action_ref}" ]] && echo "| **Action version** | \`${action_ref}\` |"

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
  local commit_method="${INPUT_COMMIT_METHOD:-api}"
  local author_name="${INPUT_COMMIT_AUTHOR_NAME}"
  local author_email="${INPUT_COMMIT_AUTHOR_EMAIL}"
  local token="${INPUT_TOKEN}"
  local action_ref="${INPUT_ACTION_REF:-}"

  # --- Resolve version ---
  step "Resolving version"
  local version
  version="$(strip_v_prefix "${raw_version}")"
  log "Tag    : ${raw_version}"
  log "Version: ${version}"
  [[ -n "${action_ref}" ]] && log "Action : ${action_ref}"

  if [[ -z "${version}" ]]; then
    fail "Resolved version is empty (input was '${raw_version}'). Refusing to update files."
  fi

  # --- Update files ---
  step "Updating files"

  case "${files_input}" in
    auto)
      log "Mode: auto-detect"
      try_auto_detect "${version}"
      ;;
    '' | none)
      log "Mode: custom rules only"
      if [[ -z "${custom_rules}" ]]; then
        fail "files is 'none' but no custom-rules were provided — nothing to do."
      fi
      ;;
    *)
      log "Mode: explicit list"
      try_explicit_files "${files_input}" "${version}"
      ;;
  esac

  # Custom rules run on top of built-in updates (or alone when files is 'none').
  if [[ -n "${custom_rules}" ]]; then
    step "Applying custom rules"
    apply_custom_rules "${custom_rules}" "${version}"
  fi

  if [[ ${#UPDATED_FILES[@]} -eq 0 ]]; then
    fail "No files were updated (files='${files_input}', custom rules: ${#custom_rules} chars)."
  fi

  log "Files updated: ${UPDATED_FILES[*]}"

  # --- Commit ---
  if [[ "${do_commit}" == "true" ]]; then
    if [[ "${commit_method}" == "git" ]]; then
      commit_and_push \
        "${version}" \
        "${commit_message_template}" \
        "${commit_branch}" \
        "${author_name}" \
        "${author_email}" \
        "${token}" \
        "${UPDATED_FILES[@]}"
    else
      commit_via_api \
        "${version}" \
        "${commit_message_template}" \
        "${commit_branch}" \
        "${token}" \
        "${UPDATED_FILES[@]}"
    fi
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
    "${action_ref}" \
    "${UPDATED_FILES[@]}"

  step "Done"
  printf "${COLOR_GREEN}${COLOR_BOLD}✓ Version bumped to %s${COLOR_RESET}\n" "${version}"
}

main
