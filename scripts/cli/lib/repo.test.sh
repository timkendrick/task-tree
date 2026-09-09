#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Contract tests for the VCS interface in lib/repo.sh
#
# The _repo__* wrapper list is the backend contract: every wrapper must have a
# same-suffix _jj__* implementation, and every _jj__* implementation must be
# exposed through a same-suffix _repo__* wrapper. Backend-internal helpers
# (double-underscore __jj__* names) are private to the backend module and are
# excluded from the contract.
# ---------------------------------------------------------------------------

test__repo__contract__interface_is_not_empty() {
  local line fn count=0
  while IFS= read -r line; do
    fn="${line##* }"
    case "$fn" in
      _repo__*) count=$((count + 1)) ;;
    esac
  done < <(declare -F)
  assert_neq "at least one _repo__ wrapper is declared" "$count" "0"
}

test__repo__contract__every_wrapper_has_backend_implementation() {
  local line fn suffix missing=''
  while IFS= read -r line; do
    fn="${line##* }"
    case "$fn" in
      _repo__*)
        suffix="${fn#_repo__}"
        declare -F "_jj__${suffix}" >/dev/null || missing="${missing} ${fn}"
        ;;
    esac
  done < <(declare -F)
  assert_output_empty "wrappers without a _jj__ implementation" "$missing"
}

test__repo__contract__every_backend_implementation_has_wrapper() {
  local line fn suffix missing=''
  while IFS= read -r line; do
    fn="${line##* }"
    case "$fn" in
      __jj__*)
        # Internal runner helpers: private to the backend, no wrapper expected.
        ;;
      _jj__*)
        suffix="${fn#_jj__}"
        declare -F "_repo__${suffix}" >/dev/null || missing="${missing} ${fn}"
        ;;
    esac
  done < <(declare -F)
  assert_output_empty "_jj__ implementations without a wrapper" "$missing"
}

run_tests "tt lib/repo (contract)"
