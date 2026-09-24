---
title: "Parallel test runner hangs when a test crashes"
status: TODO
created: 2026-09-24T14:44:08Z
updated: 2026-09-24T14:44:08Z
---
`scripts/test --parallel` never terminates when any test function dies part-way through its
body. The run stalls after every other test has reported, with no failure and no diagnostic, and
has to be killed by hand. Run serially the same test reports a normal failure and the suite exits
1, so the defect is in the parallel worker pool rather than in any suite.

## Reproduction

A throwaway suite containing nothing but a test that aborts is enough:

```bash
test_probe__plain_abort() {
  setup_workspace "probe"
  false
  assert_success "unreachable" 0
}
```

| Test body | `--parallel` | serial |
|---|---|---|
| A command that fails but is tolerated with `\|\| rc=$?` | completes | completes |
| A plain `false` | **hangs** | exit 1 |
| A `run_tt` that exits non-zero under `set -e` | **hangs** | exit 1 |

The trigger is the test function terminating without reaching its normal completion path. It is
independent of `run_tt`, of the command cache, and of whether the workspace has a worktree.

## Why it matters

A crashing test is exactly the case the runner most needs to report, and it is the case in which
it says nothing at all. The failure mode also scales badly: a full `--parallel` run that hangs
gives no clue which of several hundred tests was responsible, and the natural next step —
re-running serially — costs the wall-clock saving the pool exists to provide.

Diagnosing it is worse than it sounds because the hang is silent: the counter in the progress
output stops one short of the total, and identifying the missing test means diffing the tests that
reported against the tests that were selected.

## Scope

Make a worker whose test dies report that test as failed and release its slot, so the pool always
drains. The runner should exit non-zero with the crashed test named, matching serial behaviour.

Worth checking while in there: whether a worker killed by a signal, or one whose `tt` command
blocks on `/dev/tty`, leaves the pool in the same state, and whether the cache's
claim-and-wait path can strand a waiter when the recording test dies holding a claim.

Add coverage that a crashing test fails the run rather than hanging it. Such a test needs a hard
timeout so a regression fails the suite instead of hanging it in turn.
