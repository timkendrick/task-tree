# Developer guide

## Running the tests

```bash
scripts/test                                         # run all 25 suites serially (very slow!)
scripts/test    --parallel                           # run all tests in a worker pool (default: 4 workers)
TT_TEST_CONCURRENCY=8 scripts/test    --parallel     # limit to 8 concurrent tests
scripts/test    task/checkpoint                      # suite filter: suites matching "task/checkpoint"
scripts/test    --filter basic                       # test filter: only tests whose label matches "basic"
scripts/test    task/checkout --filter basic         # combine both filter types
scripts/test    --filter 'partial|complete'          # test filter: ERE — matches either word
scripts/test    --filter basic --filter force        # test filter: OR — matches "basic" or "force"
```

## Tracing VCS activity

`TT_LOG` narrates the version-control commands `tt` runs underneath. It takes one of two values;
anything else — including an uppercase spelling — leaves tracing off.

| Value | What is traced |
|-------|----------------|
| `info` | The mutations `tt` performs on the repository, each shown as the command line that was run, followed by that command's own output. |
| `verbose` | Everything: reads, the git plumbing behind a bare write, and the internal bookkeeping a mutation needs, in addition to everything `info` shows. |

```bash
TT_LOG=info tt task edit          # what did tt change?
TT_LOG=verbose tt task edit       # what did tt actually run?
TT_LOG=verbose scripts/test lib/vcs --filter symlink
```

A routine `tt task edit` traces one line at `info` and roughly forty at `verbose`, because a
branch write is built from git plumbing plus a temporary-ref import hop. That machinery is
deliberately hidden at `info`: it is the mechanism rather than the effect, and the temporary ref
makes `jj` report `Abandoned 1 commits that are no longer reachable`, which is alarming out of
context. What `info` shows is the branch move the user asked for.

**`TT_LOG` affects diagnostics only.** Everything it emits goes to stderr; stdout and the exit
status are byte-for-byte identical at every level, so tracing can be switched on for a command
whose output is being piped or captured. The level is chosen per call site inside
`lib/vcs/jj.sh` rather than derived from the command, so whether an operation is worth narrating
is an editorial decision recorded in that file.

Note that the test harness unsets `TT_LOG`, so an exported value cannot leak into assertions.
Suites that exercise tracing set it explicitly per invocation.

## Test suite performance

The entire test suite takes some time to run: make sure to filter test commands to ensure only the necessary set of tests are invoked.

`--parallel` runs all tests across all suites in a single flat worker pool. The pool size is controlled by `TT_TEST_CONCURRENCY` (default: `4`). This caps the number of concurrent bash+jj processes regardless of how many suites or tests exist. Increase the value on machines with many cores; decrease it if you observe resource contention.

**Suite filters** (positional arguments) are substring-matched against the suite file path relative to `scripts/cli/`. Multiple suite filters are OR-ed; a suite is included if it matches any of them.

**Test filters** (`--filter`) are ERE patterns matched against the full test label `"SUITE TITLE: test_function_name"` (e.g. `"tt task checkpoint: test_task_checkpoint__basic_with_message"`). Multiple `--filter` flags are OR-ed; a test runs if it matches any pattern. Filtered-out tests are excluded from the `[n/N]` count and summary totals.

Test output shows a global `[n/N]` counter across all running tests, per-test timing, and a single summary line at the end:

```
── [1/9] tt task checkpoint: test_task_checkpoint__basic_with_message
  ✓ checkpoint succeeds (should succeed)
  ✓ commit has Checkpoint
  ✓ WC clean after checkpoint
  (5.1s)

── [2/9] tt task checkpoint: test_task_checkpoint__with_file_changes
  ...

══════════════════════════════════════════════════════════════
  Results: 9 passed, 0 failed, 0 skipped  (21.7s)
══════════════════════════════════════════════════════════════
```

### Speeding up the test suite with a RAM disk

When running the full test suite, it is strongly recommended to provide a RAM disk to prevent unnecessary I/O thrashing.

Each test section creates a fresh jj repository on disk. Because every `tt` command shells out to several `jj` processes in sequence, the suite is partly I/O-bound. macOS typically sees wall time reductions of ~30% by running the repos on a RAM disk.

`TT_TEST_ROOT` tells the harness where to create its per-section temp directories. When unset (the default) it uses `mktemp -d`, which lands on the normal APFS volume. Point it at a RAM disk mount path instead and all jj repo I/O happens in memory.

`scripts/ramdisk` manages a macOS RAM disk for this purpose:

```bash
# Create a 512 MiB RAM disk (default size) and store the mount path
RAMDISK=$(scripts/ramdisk create)        # prints e.g. /Volumes/tt-f1f311fa

# Run tests against it
TT_TEST_ROOT=$RAMDISK scripts/test    --parallel

# Tear it down when done
scripts/ramdisk destroy $RAMDISK
```

Or as a one-liner:

```bash
RAMDISK=$(scripts/ramdisk create) && TT_TEST_ROOT=$RAMDISK scripts/test    --parallel; scripts/ramdisk destroy $RAMDISK
```

The volume name is randomly generated so multiple RAM disks can coexist (e.g. two terminal sessions or CI jobs running in parallel). The RAM disk is not persisted across reboots; create a fresh one each session.

A larger `--size` (bytes) is only needed if you run the full parallel suite and hit space pressure:

```bash
RAMDISK=$(scripts/ramdisk create --size $(( 1024 * 1024 * 1024 )))
```
