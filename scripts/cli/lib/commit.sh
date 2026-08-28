# Commit message formatting and parsing helpers for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _commit__format_message — construct a standardized tt commit message
#   _commit__parse_message  — split a tt commit message into its parts

# Usage: _commit__format_message NAMESPACE OPERATION ENTITY_ID DESCRIPTION
#
# Constructs a standardized tt commit message:
#   [tt:<namespace>:<entity-id>:<operation>] <description>
#
# When ENTITY_ID is empty (e.g. workspace operations), uses:
#   [tt:<namespace>:<operation>] <description>
#
# DESCRIPTION may be multi-line for checkpoint commits.
#
# Arguments:
#   NAMESPACE   — the command namespace, e.g. "workspace", "task"
#   OPERATION   — the operation name, e.g. "create", "edit", "checkpoint", etc.
#   ENTITY_ID   — the full task ID, e.g. "task/foo-ab123456" or "project/my-ab123456"
#                 (empty string for workspace-level operations)
#   DESCRIPTION — human-readable description (title, user message, etc.)
#
# Outputs the formatted commit message to stdout.
_commit__format_message() {
  local namespace="$1"
  local operation="$2"
  local entity_id="$3"
  local description="$4"

  if [[ -z "$entity_id" ]]; then
    printf '[tt:%s:%s] %s' "$namespace" "$operation" "$description"
  else
    printf '[tt:%s:%s:%s] %s' "$namespace" "$entity_id" "$operation" "$description"
  fi
}

# Usage: _commit__parse_message MESSAGE
#
# Inverse of _commit__format_message: splits a tt commit message into its parts.
# MESSAGE is a single line, e.g. the first line of a commit description.
#
# Outputs a single tab-separated record to stdout:
#   <namespace>\t<entity-id>\t<operation>\t<description>
#
# <entity-id> is empty for messages without one (e.g. "[tt:workspace:init]").
# Entity IDs never contain a colon but operations may (e.g. "context:add"), so a
# tag holding three or more colon-separated fields is read as namespace, entity
# ID, and the remaining fields rejoined as the operation.
#
# Exit 0: message parsed (record printed to stdout).
# Exit 1: MESSAGE is not a tt commit message (nothing printed).
_commit__parse_message() {
  local message="$1"

  [[ "$message" == '[tt:'* ]] || return 1
  local remainder="${message#\[tt:}"
  [[ "$remainder" == *']'* ]] || return 1

  local tag="${remainder%%\]*}"
  local description="${remainder#*\]}"
  description="${description# }"

  # A tag without a colon carries no operation, so it is not a tt commit message.
  [[ "$tag" == *:* ]] || return 1
  local namespace="${tag%%:*}"
  local rest="${tag#*:}"

  local entity_id operation
  if [[ "$rest" == *:* ]]; then
    entity_id="${rest%%:*}"
    operation="${rest#*:}"
  else
    entity_id=''
    operation="$rest"
  fi

  printf '%s\t%s\t%s\t%s\n' "$namespace" "$entity_id" "$operation" "$description"
}
