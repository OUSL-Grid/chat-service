#!/usr/bin/env bash
set -euo pipefail

# Bootstrap GitHub milestones and issues for Campus Marketplace project.
# Requires: gh CLI authenticated with repo scope.

usage() {
  cat <<'USAGE'
Usage:
  ./scripts.sh --owner OUSL-Grid --repo chat-service [--dry-run]

Options:
  --owner        GitHub organization/user
  --repo         Repository name
  --milestone    Milestone title (default: Campus Marketplace MVP)
  --due-on       Milestone due date, ISO8601 (default: +90 days UTC)
  --dry-run      Print actions without creating resources
  -h, --help     Show this help message
USAGE
}

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: '$1' is required but not installed." >&2
    exit 1
  }
}

OWNER=""
REPO=""
MILESTONE_TITLE="Campus Marketplace MVP"
DUE_ON="$(date -u -d '+90 days' +'%Y-%m-%dT23:59:59Z')"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      OWNER="$2"; shift 2 ;;
    --repo)
      REPO="$2"; shift 2 ;;
    --milestone)
      MILESTONE_TITLE="$2"; shift 2 ;;
    --due-on)
      DUE_ON="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$OWNER" || -z "$REPO" ]]; then
  echo "Error: --owner and --repo are required." >&2
  usage
  exit 1
fi

if [[ "$DRY_RUN" != true ]]; then
  require_cmd gh
  gh auth status >/dev/null 2>&1 || {
    echo "Error: gh CLI is not authenticated. Run: gh auth login" >&2
    exit 1
  }
fi

ISSUES=(
  "Auth: University email verification|Implement OTP/magic-link flow restricted to approved university domains.|enhancement,auth"
  "Gateway: JWT auth + rate limiting|Validate RS256 JWT at gateway and apply per-user/IP limits for listings and chat APIs.|enhancement,security"
  "Listings: CRUD + status workflow|Add listing CRUD with states active/pending/sold/flagged/removed and publish events on create/flag/sold.|enhancement,listings"
  "Listings: Alembic migrations baseline|Create Alembic migration for listings, photos, and categories tables.|enhancement,database"
  "Chat: WebSocket room model|Implement one-room-per-listing/trade chat with Redis-backed presence.|enhancement,chat"
  "Chat: Ephemeral meetup pins|Allow one-shot location pin sharing with automatic expiry cleanup.|enhancement,chat,privacy"
  "Moderation: flag queue MVP|Create flag records for listing/chat/profile and simple moderator triage endpoints.|enhancement,moderation"
  "Skill Exchange: direct reciprocal matching|Implement direct A<->B skill matching and trade request initiation.|enhancement,skills"
)

api_path="repos/${OWNER}/${REPO}"

get_milestone_number() {
  gh api "${api_path}/milestones?state=all&per_page=100" \
    --jq ".[] | select(.title == \"${MILESTONE_TITLE}\") | .number" 2>/dev/null | head -n1 || true
}

create_milestone() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] create milestone '${MILESTONE_TITLE}' due ${DUE_ON}"
    return 0
  fi

  gh api "${api_path}/milestones" \
    --method POST \
    -f title="$MILESTONE_TITLE" \
    -f description="MVP scope for Campus Marketplace, Listings, and Chat services." \
    -f due_on="$DUE_ON" >/dev/null
  log "Created milestone: ${MILESTONE_TITLE}"
}

create_issue() {
  local title="$1"
  local body="$2"
  local labels_csv="$3"
  local labels_json="[]"

  if [[ -n "$labels_csv" ]]; then
    IFS=',' read -r -a labels <<<"$labels_csv"
    labels_json="$(printf '%s\n' "${labels[@]}" | awk 'NF { printf "%s\"%s\"", sep, $0; sep="," } END { printf "" }')"
    labels_json="[${labels_json}]"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] create issue: ${title}"
    return 0
  fi

  local payload
  payload=$(cat <<JSON
{
  "title": $(printf '%s' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "body": $(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "milestone": ${MILESTONE_NUMBER},
  "labels": ${labels_json}
}
JSON
)

  gh api "${api_path}/issues" --method POST --input - <<<"$payload" >/dev/null
  log "Created issue: ${title}"
}

if [[ "$DRY_RUN" == true ]]; then
  log "[dry-run] would ensure milestone '${MILESTONE_TITLE}' (due ${DUE_ON})"
  for issue_row in "${ISSUES[@]}"; do
    IFS='|' read -r issue_title issue_body issue_labels <<<"$issue_row"
    log "[dry-run] would ensure issue: ${issue_title}"
  done
  log "Done."
  exit 0
fi

log "Checking milestone '${MILESTONE_TITLE}'"
MILESTONE_NUMBER="$(get_milestone_number)"
if [[ -z "$MILESTONE_NUMBER" ]]; then
  create_milestone
  MILESTONE_NUMBER="$(get_milestone_number)"
  if [[ -z "$MILESTONE_NUMBER" ]]; then
    echo "Error: failed to create or resolve milestone '${MILESTONE_TITLE}'." >&2
    exit 1
  fi
else
  log "Milestone already exists (#${MILESTONE_NUMBER})"
fi

for issue_row in "${ISSUES[@]}"; do
  IFS='|' read -r issue_title issue_body issue_labels <<<"$issue_row"

  existing_number="$(gh api "${api_path}/issues?state=all&per_page=100" \
    --jq ".[] | select(.title == \"${issue_title}\") | .number" 2>/dev/null | head -n1 || true)"

  if [[ -n "$existing_number" ]]; then
    log "Issue already exists (#${existing_number}): ${issue_title}"
    continue
  fi

  create_issue "$issue_title" "$issue_body" "$issue_labels"
done

log "Done."
