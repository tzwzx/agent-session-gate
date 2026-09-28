# Help and version

Help prints the usage block. `--help` / `-h` succeed. An unknown command prints the same usage on stderr and exits 2. `--version` / `-v` print the package version.

## Sub-features

- `help-long` prints help for `--help` and exits 0.
- `help-short` prints help for `-h` and exits 0.
- `help-unknown` prints help on stderr for an unknown command and exits 2.
- `version-long` prints the `package.json` version for `--version`.
- `version-short` prints the same version for `-v`.

## How to get to it (user POV)

- Run `agent-hooks --help`.
- Run `agent-hooks -h`.
- Run `agent-hooks wat`.
- Run `agent-hooks --version`.
- Run `agent-hooks -v`.

## Driving it with verify-cli

Preconditions:

- `bin/doctor` has passed.
- A disposable `$REPO` from `bin/repo` exists. Help does not write hook state, but `bin/cli` still requires a non-package cwd.

- **Long help.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name help-long -- --help`. `exit.txt` is `0`. `stdout.txt` contains `Usage:`, `session-start`, `after-edit`, `stop`, `-h, --help`, and `-v, --version`. `stderr.txt` is empty.
- **Short help.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name help-short -- -h`. Same stdout strings. `exit.txt` is `0`.
- **Unknown command.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name help-unknown -- wat`. `exit.txt` is `2`. `stderr.txt` contains `Usage:` and `session-start`.
- **Long version.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name version-long -- --version`. `exit.txt` is `0`. `stdout.txt` is the `version` field from this repo's `package.json` plus a newline.
- **Short version.** Run `"$PATH_VERIFY/cli" --cwd "$REPO" --name version-short -- -v`. Same stdout as `version-long`.
- **Proof.** Diff `help-long/stdout.txt` against `help-short/stdout.txt`. Diff the two version files. Keep them under `test-results/verify-agent-hooks/`.

## Gotchas

- Unknown command exits **2**, not 1.
- `--help` does not read stdin. Still use a disposable `--cwd` so `bin/cli` does not refuse.
- Do not treat `-h` as coverage for `--help`.
