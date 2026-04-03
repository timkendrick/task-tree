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
