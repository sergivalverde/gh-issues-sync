#!/usr/bin/env bash
set -euo pipefail

# Constants
ORG="tensormedical"
PROJECT_NUMBER=46
PROJECT_ID="PVT_kwDOAr65yM4AzR2f"
SESSIONS_DIR="$HOME/.claude/sessions"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "sync-workspace-status: starting"

# Auth check
if ! gh auth status &>/dev/null; then
  log "ERROR: gh auth failed."
  exit 1
fi

# Discover field IDs dynamically — skip if fields don't exist
FIELDS_JSON=$(gh api graphql -f query="
  query {
    organization(login: \"$ORG\") {
      projectV2(number: $PROJECT_NUMBER) {
        fields(first: 30) {
          nodes { ... on ProjectV2Field { id name dataType } }
        }
      }
    }
  }
")

WORKSPACE_FIELD_ID=$(echo "$FIELDS_JSON" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Workspace") | .id' 2>/dev/null || true)
AGENT_FIELD_ID=$(echo "$FIELDS_JSON" | jq -r '.data.organization.projectV2.fields.nodes[] | select(.name == "Agent Status") | .id' 2>/dev/null || true)

if [ -z "$WORKSPACE_FIELD_ID" ] && [ -z "$AGENT_FIELD_ID" ]; then
  log "No Workspace or Agent Status fields found on project. Skipping."
  exit 0
fi

log "Fields: Workspace=${WORKSPACE_FIELD_ID:-none}, Agent Status=${AGENT_FIELD_ID:-none}"

# Get all active Claude sessions with their cwd (stored as lines: cwd|startedAt)
SESSIONS_TMP=$(mktemp)
trap 'rm -f "$SESSIONS_TMP"' EXIT
session_count=0
if [ -d "$SESSIONS_DIR" ]; then
  for f in "$SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r '.pid' "$f" 2>/dev/null) || continue
    cwd=$(jq -r '.cwd' "$f" 2>/dev/null) || continue
    started=$(jq -r '.startedAt' "$f" 2>/dev/null) || continue

    # Check if PID is alive
    if kill -0 "$pid" 2>/dev/null; then
      echo "${cwd}|${started}" >> "$SESSIONS_TMP"
      session_count=$((session_count + 1))
    fi
  done
fi
log "Found $session_count active Claude sessions"

# Lookup session by cwd
get_session_started() {
  local search_cwd="$1"
  grep "^${search_cwd}|" "$SESSIONS_TMP" 2>/dev/null | head -1 | cut -d'|' -f2 || true
}

# Fetch project items with their current field values and linked PR branches
fetch_items() {
  local cursor=""
  local has_next="true"

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
              nodes {
                id
                content {
                  ... on Issue {
                    timelineItems(itemTypes: [CONNECTED_EVENT, CROSS_REFERENCED_EVENT], first: 5) {
                      nodes {
                        ... on ConnectedEvent { subject { ... on PullRequest { headRefName number url repository { nameWithOwner } } } }
                        ... on CrossReferencedEvent { source { ... on PullRequest { headRefName number url repository { nameWithOwner } } } }
                      }
                    }
                  }
                  ... on PullRequest { headRefName number url repository { nameWithOwner } }
                }
                fieldValues(first: 15) {
                  nodes {
                    ... on ProjectV2ItemFieldTextValue {
                      text
                      field { ... on ProjectV2Field { name } }
                    }
                  }
                }
              }
            }
          }
        }
      }
    ")

    echo "$result" | jq -c '.data.organization.projectV2.items.nodes[]'

    has_next=$(echo "$result" | jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage')
    cursor=$(echo "$result" | jq -r '.data.organization.projectV2.items.pageInfo.endCursor')
  done
}

# Find worktree path for a branch by scanning all git worktrees in known workspaces
find_worktree_path() {
  local branch="$1"
  # Scan common workspace directories for worktrees matching this branch
  for workspace_dir in "$HOME/tensormedical" "$HOME/Documents" "$HOME/Documents/raycast-extensions"; do
    [ -d "$workspace_dir" ] || continue
    for repo_dir in "$workspace_dir"/*/; do
      [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || continue
      local wt_info
      wt_info=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null) || continue
      local current_path=""
      while IFS= read -r line; do
        if [[ "$line" == "worktree "* ]]; then
          current_path="${line#worktree }"
        elif [[ "$line" == "branch refs/heads/$branch" ]]; then
          echo "$current_path"
          return 0
        fi
      done <<< "$wt_info"
    done
  done
  return 1
}

update_text_field() {
  local item_id="$1"
  local field_id="$2"
  local value="$3"

  gh api graphql -f query="
    mutation {
      updateProjectV2ItemFieldValue(input: {
        projectId: \"$PROJECT_ID\"
        itemId: \"$item_id\"
        fieldId: \"$field_id\"
        value: { text: \"$value\" }
      }) {
        projectV2Item { id }
      }
    }
  " &>/dev/null
}

log "Fetching project items..."
updated=0

while IFS= read -r item_json; do
  item_id=$(echo "$item_json" | jq -r '.id')

  # Extract branches: direct headRefName or from linked PR timeline events
  branches=$(echo "$item_json" | jq -r '
    [
      .content.headRefName,
      (.content.timelineItems?.nodes[]? | (.subject?.headRefName, .source?.headRefName))
    ] | map(select(. != null and . != "")) | unique[]
  ' 2>/dev/null)

  [ -z "$branches" ] && continue

  # Get current field values
  current_workspace=$(echo "$item_json" | jq -r '.fieldValues.nodes[] | select(.field.name == "Workspace") | .text // empty' 2>/dev/null)
  current_agent=$(echo "$item_json" | jq -r '.fieldValues.nodes[] | select(.field.name == "Agent Status") | .text // empty' 2>/dev/null)

  # Find worktree for any of the branches
  wt_path=""
  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    wt_path=$(find_worktree_path "$branch" 2>/dev/null) && break
  done <<< "$branches"

  [ -z "$wt_path" ] && continue

  # Compute values
  vscode_uri="https://vscode.dev/redirect?url=vscode://file${wt_path}"
  started_ms=$(get_session_started "$wt_path")
  if [ -n "$started_ms" ]; then
    started_date=$(date -r $((started_ms / 1000)) '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
    agent_status="Active since $started_date"
  else
    agent_status="Idle"
  fi

  # Update if changed (skip if field doesn't exist)
  if [ -n "$WORKSPACE_FIELD_ID" ] && [ "$current_workspace" != "$vscode_uri" ]; then
    update_text_field "$item_id" "$WORKSPACE_FIELD_ID" "$vscode_uri"
    updated=$((updated + 1))
    log "  Updated Workspace for item $item_id"
  fi
  if [ -n "$AGENT_FIELD_ID" ] && [ "$current_agent" != "$agent_status" ]; then
    update_text_field "$item_id" "$AGENT_FIELD_ID" "$agent_status"
    updated=$((updated + 1))
    log "  Updated Agent Status for item $item_id"
  fi


done < <(fetch_items)

log "Done. Updated $updated field(s)"
