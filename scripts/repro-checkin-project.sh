#!/usr/bin/env bash
# repro-checkin-project.sh — Reproduce the `tt task checkin --target` bug for project branches.
# Creates a temporary jj repo, sets up a tt project and task, then tries to check
# the project branch into an arbitrary target branch.
set -euo pipefail

TT="$(cd "$(dirname "${BASH_SOURCE[0]}")/cli" && pwd)/tt"

TMPDIR_BASE="${TMPDIR:-/tmp}"
REPO="$(mktemp -d "$TMPDIR_BASE/tt-repro-XXXXXX")"
trap 'rm -rf "$REPO"' EXIT

echo "=== Setting up temp repo at $REPO ==="

# Init jj repo
jj -R "$REPO" git init --quiet 2>&1 || jj init --quiet "$REPO" 2>&1 || true
cd "$REPO"
jj init --quiet 2>&1 || true

# Make sure we have a jj repo
jj status 2>&1 | head -3

# Create a baseline commit on 'main'
mkdir -p .tt
cat > .tt/config.toml <<'EOF'
task_prefix = "task/"
project_prefix = "project/"
EOF
jj describe -m "Initial commit"
jj bookmark set main -r '@'
jj new

echo ""
echo "=== Creating project branch ==="
echo "My project description" | "$TT" task create \
  --project --slug my-project --title "My Project" \
  --repo "$REPO"

PROJECT_ID="$(jj log -r 'bookmarks()' --no-graph -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' | grep '^project/')"
echo "Project ID: $PROJECT_ID"

echo ""
echo "=== Creating a task under the project ==="
jj checkout "$PROJECT_ID" 2>/dev/null || jj edit "$PROJECT_ID" 2>/dev/null || true
echo "Some task work" | "$TT" task create \
  --slug my-task --title "My Task" \
  --repo "$REPO"

TASK_ID="$(jj log -r 'bookmarks()' --no-graph -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' | grep '^task/')"
echo "Task ID: $TASK_ID"

echo ""
echo "=== Completing the task ==="
"$TT" task complete --repo "$REPO" "$TASK_ID"

echo ""
echo "=== Checking in the task to the project ==="
"$TT" task checkin --repo "$REPO" "$TASK_ID"

echo ""
echo "=== Current log after task checkin ==="
jj log --no-graph -T 'change_id.short() ++ " " ++ local_bookmarks.map(|b| b.name()).join(",") ++ " " ++ description.first_line() ++ "\n"' -n 10

echo ""
echo "=== Now attempting to check in the PROJECT branch to main (the bug) ==="
echo "  Command: tt task checkin --target main $PROJECT_ID"
if "$TT" task checkin --repo "$REPO" --target main "$PROJECT_ID"; then
  echo "SUCCESS: project checkin to main worked"
else
  echo "FAILURE: project checkin to main failed (exit $?)"
fi

echo ""
echo "=== Final log ==="
jj log --no-graph -T 'change_id.short() ++ " " ++ local_bookmarks.map(|b| b.name()).join(",") ++ " " ++ description.first_line() ++ "\n"' -n 15
