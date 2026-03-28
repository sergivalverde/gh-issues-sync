#!/usr/bin/env bash
set -euo pipefail

# Constants
GITHUB_USER="sergivalverde"
ORG="tensormedical"
PROJECT_NUMBER=46
PROJECT_ID="PVT_kwDOAr65yM4AzR2f"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "sync-issues-to-project: starting"

# Auth check
if ! gh auth status &>/dev/null; then
  log "ERROR: gh auth failed. Run 'gh auth login' to fix."
  exit 1
fi
log "Auth OK"
