# Agent instructions

## Source control safety
- Always commit changes early and push to a remote branch.
- Prefer opening a (draft) PR as soon as changes compile or are reasonably complete.

## Heavy tasks
- Do NOT run heavy installs/tests locally unless explicitly asked.
- Prefer CI (GitHub Actions) to run: install, lint, test, build.

## Pull request workflow

- After pushing a branch, always open a PR (draft is fine).
- Do not run heavy installs/tests locally unless CI is unavailable.

## CI monitoring (required)

- After opening the PR, always monitor GitHub Actions status.
- Wait for required checks to finish before continuing work.
- If checks fail, read the CI logs and fix based on the failure.
- Only rerun heavy tasks locally if CI output is insufficient.

The GitHub token is available, so PR status and check results can be queried directly.
