# Short-lived mutual-exclusion locks for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# A lock is a directory: `mkdir` either creates it or fails because it already
# exists, atomically, so exactly one of several processes racing for the same
# path succeeds. The lock is held until the directory is removed. A process
# that dies while holding a lock leaves the directory behind; recovering from
# that is the caller's concern.
#
# Public surface:
#   _lock__acquire — take a lock, waiting up to a timeout for its release
#   _lock__release — give a lock up

# Usage: _lock__acquire PATH TIMEOUT
# Creates the lock directory PATH, retrying every 0.1s while it already exists,
# for up to TIMEOUT whole seconds. The parent of PATH must exist: it is never
# created, since `mkdir -p` would succeed on a lock that is already held.
# Returns 0 once the lock is held and 1 on timeout. Prints nothing, so the
# caller owns the error message.
_lock__acquire() {
  local path="$1" timeout="$2"
  local attempts=$(( timeout * 10 ))
  local attempt=0
  while true; do
    if mkdir "$path" 2>/dev/null; then
      return 0
    fi
    (( attempt += 1 ))
    if (( attempt > attempts )); then
      return 1
    fi
    sleep 0.1
  done
}

# Usage: _lock__release PATH
# Removes the lock directory PATH. Succeeds when the lock is not held.
_lock__release() {
  local path="$1"
  rm -rf "$path"
}
