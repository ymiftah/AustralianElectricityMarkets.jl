# GitHub CLI (gh) Usage Rules

- **Prefer CLI over Browser**: Use `gh` CLI for interacting with GitHub (PRs, Issues, Actions, etc.) instead of attempting to use browser actions when a CLI alternative exists.
- **Non-Interactive Mode**: Always use non-interactive mode with `gh` commands to avoid hanging. Use flags like `--confirm`, `--yes`, `-y`, `--fill`, and ensure `--web=false` is used where applicable.
- **Pre-creation Checks**: Before creating a new PR or Issue, always search for existing ones using `gh pr list` or `gh issue list` to avoid duplicates.
- **CI/CD Monitoring**: Use `gh run list` and `gh run view` to monitor the status of CI workflows instead of waiting or checking manually in the browser.
- **PR Creation**: Use `gh pr create --fill` to create PRs with titles and bodies automatically populated from commit messages whenever possible.
- **Safety**: Avoid using `gh` for destructive operations like deleting repositories or changing critical settings unless explicitly requested by the user.
- **Information Retrieval**: Prefer `gh` for gathering information about the repository (e.g., `gh repo view`, `gh release list`). Only use the browser if visual inspection of the UI is strictly necessary.
