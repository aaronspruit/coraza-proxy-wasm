#!/usr/bin/env bash
# Copyright The OWASP Coraza contributors
# SPDX-License-Identifier: Apache-2.0

# update-crs.sh — Fetch the latest OWASP CRS release and update the local rules.
# Usage: ./update-crs.sh
# Exit codes:
#   0 — rules updated (or already up-to-date when called with --check)
#   1 — error
#   2 — already up-to-date (no changes)

set -euo pipefail

REPO="coreruleset/coreruleset"
RULES_DIR="wasmplugin/rules"
CRS_DIR="${RULES_DIR}/crs"
VERSIONS_FILE=".crs-versions"

# Resolve the repo root (script lives in .github/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# 1. Determine current and latest versions
# ---------------------------------------------------------------------------

if [[ ! -f "${VERSIONS_FILE}" ]]; then
  echo "::error::Versions file ${VERSIONS_FILE} not found"
  exit 1
fi

CURRENT_VERSION="$(grep '^CRS_VERSION=' "${VERSIONS_FILE}" | head -1 | cut -d= -f2-)"
echo "Current CRS version: ${CURRENT_VERSION}"

# Fetch latest release tag from GitHub API
LATEST_TAG="$(curl -sf "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')"

if [[ -z "${LATEST_TAG}" ]]; then
  echo "::error::Failed to fetch latest release tag from ${REPO}"
  exit 1
fi

LATEST_VERSION="${LATEST_TAG#v}"  # strip leading 'v'
echo "Latest CRS version: ${LATEST_VERSION}"

if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
  echo "CRS rules are already up-to-date (${CURRENT_VERSION})."
  exit 2
fi

echo "Updating CRS from ${CURRENT_VERSION} → ${LATEST_VERSION} …"

# ---------------------------------------------------------------------------
# 2. Download and extract the minimal tarball
# ---------------------------------------------------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

TARBALL_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/coreruleset-${LATEST_VERSION}-minimal.tar.gz"
echo "Downloading ${TARBALL_URL}"
curl -sfL "${TARBALL_URL}" -o "${TMPDIR}/crs.tar.gz"

tar -xzf "${TMPDIR}/crs.tar.gz" -C "${TMPDIR}"
EXTRACTED_DIR="${TMPDIR}/coreruleset-${LATEST_VERSION}"

if [[ ! -d "${EXTRACTED_DIR}/rules" ]]; then
  echo "::error::Expected rules/ directory not found in tarball"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Replace local CRS files
# ---------------------------------------------------------------------------

# Replace crs/ rules directory
rm -rf "${CRS_DIR}"
mkdir -p "${CRS_DIR}"
cp -a "${EXTRACTED_DIR}/rules/." "${CRS_DIR}/"

# Replace crs-setup.conf.example
if [[ -f "${EXTRACTED_DIR}/crs-setup.conf.example" ]]; then
  cp -a "${EXTRACTED_DIR}/crs-setup.conf.example" "${RULES_DIR}/crs-setup.conf.example"
fi

# ---------------------------------------------------------------------------
# 4. Update version file
# ---------------------------------------------------------------------------

sed -i "s/^CRS_VERSION=.*/CRS_VERSION=${LATEST_VERSION}/" "${VERSIONS_FILE}"

# Update CRS_VERSION in ftw/Dockerfile if present
DOCKERFILE="ftw/Dockerfile"
if [[ -f "$DOCKERFILE" ]]; then
  sed -i "s/^ARG CRS_VERSION=.*/ARG CRS_VERSION=v${LATEST_VERSION}/" "$DOCKERFILE"
fi

echo "CRS rules updated to ${LATEST_VERSION}."
