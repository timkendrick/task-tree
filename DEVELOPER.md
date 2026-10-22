# Developer guide

## Library layout

The CLI under `scripts/cli/` is organised into four tiers:

```
scripts/cli/**                 commands — argument parsing, control flow, user-facing output
      ↓
lib/{task,workspace,           semantic facades — the task, workspace, worktree and
     worktree,history}.sh      history models, expressed in domain terms
      ↓
lib/repo.sh                    backend-neutral VCS interface (_repo__*)
      ↓
lib/vcs/jj.sh                  backend implementation (_jj__*) — the only place `jj`
                               or `git` is invoked
```

Utility modules — `ui`, `string`, `format`, `path`, `frontmatter`, `commit`, `hook` — sit beside the
facades and perform no VCS access. `lib/common.sh` is the single entry point every command sources;
it contains nothing but `source` directives.

Library functions are named `_<namespace>__<verb>[_<noun>]`, where the namespace is the module name
followed by a double underscore. A *leading* double underscore (`__jj__read`) marks a module-private
helper. Each module's header states its responsibility and lists its public surface.

See `ARCHITECTURE.md` for the module inventory, the rules governing what each tier may call, the
backend contract, and the working-copy invariants that branch writes depend on.

## Running the tests

Every module and every command has a co-located `*.test.sh` suite. `scripts/test` discovers
`scripts/cli/**/*.test.sh` automatically, so a suite filter narrows to one module or command:
`scripts/test lib/vcs`, `scripts/test lib/frontmatter`, `scripts/test task/checkpoint`.

```bash
scripts/test                                         # run every suite serially (very slow!)
scripts/test    --parallel                           # run all tests in a worker pool (default: one worker per CPU)
TT_TEST_CONCURRENCY=4 scripts/test    --parallel     # limit to 4 concurrent tests
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

`--parallel` runs all tests across all suites in a single flat worker pool. The pool size is controlled by `TT_TEST_CONCURRENCY` (default: the number of CPUs). This caps the number of concurrent bash+jj processes regardless of how many suites or tests exist. Decrease it if you observe resource contention.

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

### What a test costs

Every `tt` command is a bash process that shells out to `jj` and `git` several dozen times, and
each test runs a handful of commands. Process creation is therefore the cost that matters: on
macOS it is slow and it does not scale across cores — spawning from fourteen workers at once gives
only about four times the throughput of one — so the way to make the suite faster is to make it
spawn fewer processes. Extra workers pay off only because the command cache below leaves workers
waiting on each other rather than spawning.

The runner builds one template workspace per run and every `setup_workspace` copies it (two
symlinks re-pointed) instead of initialising a repository and running `tt workspace init` from
scratch. A suite run directly, outside `scripts/test`, builds its workspaces the slow way.

### The command cache

Most tests reach their starting point through the same commands applied to the same workspace
state, so the runner keeps a cache of what each `run_tt` invocation did. The first time a command
runs against a given state it runs for real and its resulting repo, stdout, stderr and exit status
are recorded; every later run of the same command against the same state receives a copy of that
result instead, with the recording test's paths replaced by its own.

"The same state" is checked rather than assumed. The cache key covers the repository's current
operation ID, a manifest of the working copy (every path outside the `.jj` and `.git` stores,
with file content), the command line, whatever is on stdin, and the `TT_*`, editor and colour
settings a command's behaviour can depend on. A test that changed the workspace by any means —
a harness helper, a file written directly, a `jj` command — therefore runs its next command
live, and from then on its history is its own. Workspaces with a dedicated worktree are never
cached in either direction, because the backend records worktree paths absolutely.

Two tests reaching the same command against the same state at the same time do not both run it:
the first claims the cache entry and the second waits for the recording, so that both continue
from identical histories and keep sharing entries afterwards. This is why the suite now benefits
from more workers than the process-creation ceiling alone would allow.

The cache only ever replays a command that some test in the same run executed against the
identical state, so a test never sees a workspace no `tt` command produced, and every distinct
command-against-state in the suite still runs once per run. What it gives up is repetition: a
command that several tests would each have run is run by one of them. Set `TT_TEST_NO_CACHE=1`
to run every command live; a suite run directly, outside `scripts/test`, has no cache.

### Speeding up the test suite with a RAM disk

When running the full test suite, it is strongly recommended to provide a RAM disk to prevent unnecessary I/O thrashing.

Each test section creates a fresh jj repository on disk. Because every `tt` command shells out to several `jj` processes in sequence, the suite is partly I/O-bound. macOS typically sees wall time reductions of ~30% by running the repos on a RAM disk.

`TT_TEST_ROOT` tells the harness where to create its per-section temp directories. When unset (the default) it uses `mktemp -d`, which lands on the normal APFS volume. Point it at a RAM disk mount path instead and all jj repo I/O happens in memory.

`scripts/ramdisk` manages a macOS RAM disk for this purpose:

```bash
# Create a 2 GiB RAM disk (default size) and store the mount path
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

The default size covers a full parallel run with room to spare: the command cache keeps a copy of
the workspace for every distinct command-against-state the suite produces, and a full run peaks at
a little over 1 GiB. A disk that fills up shows as slow, failing tests rather than an explicit
error, so pass a larger `--size` (bytes) rather than a smaller one if in doubt:

```bash
RAMDISK=$(scripts/ramdisk create --size $(( 4 * 1024 * 1024 * 1024 )))
```
