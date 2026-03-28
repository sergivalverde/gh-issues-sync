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
