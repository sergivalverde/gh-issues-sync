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

# Fetch all personal repo names (paginated)
fetch_personal_repos() {
  gh api --paginate "/users/$GITHUB_USER/repos?per_page=100&type=owner" --jq '.[].full_name'
}

log "Fetching personal repos..."
REPOS=$(fetch_personal_repos)
REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
log "Found $REPO_COUNT personal repos"

# Fetch open issues for a repo (filters out PRs)
fetch_open_issues() {
  local repo="$1"
  gh api --paginate "/repos/$repo/issues?state=open&per_page=100" --jq '.[] | select(.pull_request == null) | .node_id'
}

added=0
skipped=0
errors=0

while IFS= read -r repo; do
  [ -z "$repo" ] && continue

  issue_ids=$(fetch_open_issues "$repo" 2>/dev/null || true)
  [ -z "$issue_ids" ] && continue

  issue_count=$(echo "$issue_ids" | wc -l | tr -d ' ')
  log "Repo $repo: $issue_count open issue(s)"

  while IFS= read -r issue_id; do
    [ -z "$issue_id" ] && continue

    # Check if already on project
    if echo "$EXISTING_IDS" | grep -qF "$issue_id"; then
      skipped=$((skipped + 1))
      continue
    fi

    # Add to project
    if gh api graphql -f query="
      mutation {
        addProjectV2ItemById(input: {projectId: \"$PROJECT_ID\", contentId: \"$issue_id\"}) {
          item { id }
        }
      }
    " &>/dev/null; then
      added=$((added + 1))
      log "  Added issue $issue_id"
    else
      errors=$((errors + 1))
      log "  ERROR: Failed to add issue $issue_id"
    fi
  done <<< "$issue_ids"
done <<< "$REPOS"

log "Done. Added: $added, Skipped: $skipped, Errors: $errors"
