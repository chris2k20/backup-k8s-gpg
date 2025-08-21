# Contributing

Thanks for your interest! Here's how to contribute:

## Issues
- **Bug report**: describe the issue, expected vs. actual behavior, steps to reproduce, and environment (versions of kubectl/jq/yq).
- **Feature request**: problem statement, proposed solution, alternatives.

## Pull Requests
1. Fork and create a branch (e.g. `feat/...` or `fix/...`).
2. Local checks:
   - Run ShellCheck: `make lint`
3. Write a clear PR description (What/Why/How tested).

## Style & Guidelines
- Bash: keep strict mode `set -euo pipefail`.
- Do not include secrets in tests/logs/examples.
- Prefer small, focused functions with descriptive names.

## Releases/Versioning
- Versions are managed via Release Please. It will update `backup-k8s-gpg.sh` (`VERSION`) and the `Makefile`.

## Security
- Please do not disclose security issues publicly in the issue tracker. Contact the maintainers privately if possible.
