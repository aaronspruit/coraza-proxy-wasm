#!/usr/bin/env bash
# Copyright The OWASP Coraza contributors
# SPDX-License-Identifier: Apache-2.0

# update-plugins.sh — Fetch the latest CRS plugins and update the local plugins directory.
# Reads the list of plugin repos from .crs-plugins.txt.
# Tracks per-plugin versions in .crs-plugins-versions.
#
# Exit codes:
#   0 — one or more plugins updated
#   1 — error
#   2 — all plugins already up-to-date (no changes)

set -euo pipefail

# Resolve the repo root (script lives in .github/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

PLUGINS_DIR="wasmplugin/rules/plugins"
PLUGINS_LIST=".crs-plugins.txt"
VERSIONS_FILE=".crs-plugins-versions"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read the current recorded version for a plugin (empty if not recorded).
get_current_version() {
  local repo="$1"
  if [[ -f "${VERSIONS_FILE}" ]]; then
    grep -F "${repo}=" "${VERSIONS_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true
  fi
}

# Write (or update) a version entry in the versions file.
set_version() {
  local repo="$1" version="$2"
  if [[ -f "${VERSIONS_FILE}" ]] && grep -qF "${repo}=" "${VERSIONS_FILE}" 2>/dev/null; then
    sed -i "s|^${repo}=.*|${repo}=${version}|" "${VERSIONS_FILE}"
  else
    echo "${repo}=${version}" >> "${VERSIONS_FILE}"
  fi
}

# For a given repo, resolve the latest version identifier.
# Uses the latest release tag if available, otherwise the default branch HEAD SHA.
# Outputs two values: VERSION_ID  DOWNLOAD_REF
resolve_latest_version() {
  local repo="$1"

  # Try latest release first
  local tag
  tag="$(curl -sf "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')" || true

  if [[ -n "${tag}" ]]; then
    echo "${tag} ${tag}"
    return
  fi

  # No release — use default branch HEAD SHA
  local sha
  sha="$(curl -sf "https://api.github.com/repos/${repo}/commits?per_page=1" 2>/dev/null \
    | grep '"sha"' | head -1 | sed 's/.*"sha": *"//;s/".*//')" || true

  if [[ -n "${sha}" ]]; then
    echo "${sha} ${sha}"
    return
  fi

  echo ""
}

# Download the plugins/ directory from a repo at a given ref into a local directory.
download_plugin_files() {
  local repo="$1" ref="$2" dest_dir="$3"

  local tmpdir
  tmpdir="$(mktemp -d)"

  # Download the repo tarball at the given ref
  local tarball_url="https://api.github.com/repos/${repo}/tarball/${ref}"
  if ! curl -sfL "${tarball_url}" -o "${tmpdir}/repo.tar.gz"; then
    echo "::warning::Failed to download tarball for ${repo}@${ref}"
    rm -rf "${tmpdir}"
    return 1
  fi

  tar -xzf "${tmpdir}/repo.tar.gz" -C "${tmpdir}"

  # The tarball extracts into a directory named <owner>-<repo>-<shortsha>/
  local extracted
  extracted="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -1)"

  if [[ ! -d "${extracted}/plugins" ]]; then
    echo "::warning::No plugins/ directory found in ${repo}@${ref}"
    rm -rf "${tmpdir}"
    return 1
  fi

  # Copy only .conf and .data files (skip README, lua scripts that won't work in wasm)
  find "${extracted}/plugins" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.data' \) \
    ! -name 'empty-*.conf' \
    -exec cp -a {} "${dest_dir}/" \;

  rm -rf "${tmpdir}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ ! -f "${PLUGINS_LIST}" ]]; then
  echo "::error::Plugin list file ${PLUGINS_LIST} not found"
  exit 1
fi

# Ensure plugins directory exists with CRS empty placeholder files
mkdir -p "${PLUGINS_DIR}"

# Read plugin repos (skip comments and blank lines)
mapfile -t REPOS < <(grep -v '^\s*#' "${PLUGINS_LIST}" | grep -v '^\s*$' | tr -d '[:space:]' | sed '/^$/d')

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "No plugins configured in ${PLUGINS_LIST}"
  exit 2
fi

UPDATED=0
FAILED=0
SKIPPED=0
UPDATED_SUMMARY=""

for repo in "${REPOS[@]}"; do
  echo "--- Checking ${repo} ---"

  current_version="$(get_current_version "${repo}")"

  version_info="$(resolve_latest_version "${repo}")"
  if [[ -z "${version_info}" ]]; then
    echo "::warning::Could not resolve version for ${repo} — skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  latest_version="$(echo "${version_info}" | awk '{print $1}')"
  download_ref="$(echo "${version_info}" | awk '{print $2}')"

  if [[ "${current_version}" == "${latest_version}" ]]; then
    echo "  Already up-to-date: ${current_version}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "  Updating: ${current_version:-<none>} → ${latest_version}"

  if download_plugin_files "${repo}" "${download_ref}" "${PLUGINS_DIR}"; then
    set_version "${repo}" "${latest_version}"
    UPDATED=$((UPDATED + 1))
    short_name="${repo#*/}"
    UPDATED_SUMMARY="${UPDATED_SUMMARY}\n- ${short_name}: ${current_version:-<new>} → ${latest_version}"
  else
    FAILED=$((FAILED + 1))
  fi
done

# Sort the versions file for cleanliness
if [[ -f "${VERSIONS_FILE}" ]]; then
  sort -o "${VERSIONS_FILE}" "${VERSIONS_FILE}"
fi

echo ""
echo "========================================="
echo "Plugins updated: ${UPDATED}"
echo "Plugins skipped (up-to-date): ${SKIPPED}"
echo "Plugins failed: ${FAILED}"
echo "========================================="

if [[ ${UPDATED} -gt 0 ]]; then
  echo -e "\nUpdated plugins:${UPDATED_SUMMARY}"
  # Export for GitHub Actions
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "updated=true" >> "${GITHUB_OUTPUT}"
    # Multiline summary for PR body
    {
      echo "summary<<EOF"
      echo -e "${UPDATED_SUMMARY}"
      echo "EOF"
    } >> "${GITHUB_OUTPUT}"
  fi
  exit 0
else
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "updated=false" >> "${GITHUB_OUTPUT}"
  fi
  exit 2
fi
