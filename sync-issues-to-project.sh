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

# Fetch all issue node IDs already on the project (paginated)
fetch_project_item_ids() {
  local cursor=""
  local has_next="true"
  local all_ids=""

  while [ "$has_next" = "true" ]; do
    local cursor_arg=""
    if [ -n "$cursor" ]; then
      cursor_arg=", after: \"$cursor\""
    fi

    local result
    result=$(gh api graphql -f query="
      query {
        organization(login: \"$ORG\") {
          projectV2(number: $PROJECT_NUMBER) {
            items(first: 100${cursor_arg}) {
              pageInfo { hasNextPage endCursor }
              nodes { content { ... on Issue { id } } }
            }
          }
        }
      }
    ")

    local ids
    ids=$(echo "$result" | jq -r '.data.organization.projectV2.items.nodes[].content.id // empty')
    if [ -n "$ids" ]; then
      all_ids="$all_ids"$'\n'"$ids"
    fi

    has_next=$(echo "$result" | jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage')
    cursor=$(echo "$result" | jq -r '.data.organization.projectV2.items.pageInfo.endCursor')
  done

  echo "$all_ids"
}

log "Fetching existing project items..."
EXISTING_IDS=$(fetch_project_item_ids)
EXISTING_COUNT=$(echo "$EXISTING_IDS" | grep -c . || true)
log "Found $EXISTING_COUNT items already on project"
