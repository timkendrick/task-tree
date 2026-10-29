# Common functions for tt bootstrap CLI scripts.
# Source this file; do not execute directly.

_TT_LIB_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
. "$_TT_LIB_DIR/ui.sh"
. "$_TT_LIB_DIR/string.sh"
. "$_TT_LIB_DIR/format.sh"
. "$_TT_LIB_DIR/path.sh"
. "$_TT_LIB_DIR/frontmatter.sh"
. "$_TT_LIB_DIR/commit.sh"
. "$_TT_LIB_DIR/hook.sh"
. "$_TT_LIB_DIR/lock.sh"
. "$_TT_LIB_DIR/repo.sh"
. "$_TT_LIB_DIR/history.sh"
. "$_TT_LIB_DIR/task.sh"
. "$_TT_LIB_DIR/workspace.sh"
. "$_TT_LIB_DIR/worktree.sh"
