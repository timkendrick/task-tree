# Bash script code style

- You MUST use the following shebang: `#!/usr/bin/env bash`
- You MUST use `set -euo pipefail`
- You MUST include a `usage()` function to describe arguments
- You MUST parse arguments before performing any actions
- You MUST log diagnostic/error information to stderr, and script output to stdout
- You SHOULD follow responsible engineering practices:
  - Refactor functions when they start to become unwieldy
  - Extract isolated subroutines into reusable DRY helper functions
