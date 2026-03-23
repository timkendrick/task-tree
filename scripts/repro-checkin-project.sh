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
cd "$REPO"
jj git init --quiet

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

PROJECT_ID="$(jj log -r 'bookmarks()' --no-graph \
  -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' \
  | grep '^project/')"
echo "Project ID: $PROJECT_ID"

echo ""
echo "=== Creating a task under the project ==="
echo "Some task work" | "$TT" task create \
  --parent "$PROJECT_ID" \
  --slug my-task --title "My Task" \
  --repo "$REPO"

TASK_ID="$(jj log -r 'bookmarks()' --no-graph \
  -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' \
  | grep '^task/')"
echo "Task ID: $TASK_ID"

echo ""
echo "=== Log before checkin ==="
jj log --no-graph \
  -T 'change_id.short() ++ " " ++ local_bookmarks.map(|b| b.name()).join(",") ++ " " ++ description.first_line() ++ "\n"' \
  -n 10

echo ""
echo "=== Marking task DONE manually ==="
jj edit "$TASK_ID"
TASK_FILE=".tt/task/${TASK_ID#task/}/TASK.md"
sed -i '' 's/^status: .*/status: DONE/' "$TASK_FILE"
jj describe -m "Complete task: My Task ($TASK_ID)"
jj bookmark set "$TASK_ID" -r '@'
jj new

echo ""
echo "=== Checking in the task to the project ==="
echo "  Command: tt task checkin $TASK_ID"
if "$TT" task checkin --repo "$REPO" "$TASK_ID"; then
  echo "SUCCESS: task checkin to project worked"
else
  echo "FAILURE: task checkin to project failed (exit $?)"
  exit 1
fi

echo ""
echo "=== Log after task checkin ==="
jj log --no-graph \
  -T 'change_id.short() ++ " " ++ local_bookmarks.map(|b| b.name()).join(",") ++ " " ++ description.first_line() ++ "\n"' \
  -n 10

echo ""
echo "=== Now attempting to check in the PROJECT branch to main (the bug) ==="
echo "  Command: tt task checkin --target main $PROJECT_ID"
if "$TT" task checkin --repo "$REPO" --target main "$PROJECT_ID"; then
  echo "SUCCESS: project checkin to main worked"
else
  echo "FAILURE: project checkin to main failed (exit $?)"
  exit 1
fi

echo ""
echo "=== Final log ==="
jj log --no-graph \
  -T 'change_id.short() ++ " " ++ local_bookmarks.map(|b| b.name()).join(",") ++ " " ++ description.first_line() ++ "\n"' \
  -n 15

echo ""
echo "=== Verify .tt/task/ is absent on main after project checkin ==="
jj file list -r main | grep '\.tt/' || echo "(no .tt/task/ files on main — correct)"
