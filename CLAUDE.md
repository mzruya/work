# work - Multi-project Git Worktree Manager

## What this is

A CLI tool for managing git worktrees across multiple projects. Two implementations exist with identical behavior:

- `work.nu` — Nushell (primary). Uses `input list --fuzzy` for selection, `.nuon` config format.
- `work.sh` — Bash port. Uses `fzf` for selection, plain text config format (`name:path` per line).

## File structure

```
work.nu          # Nushell implementation (source in config.nu)
work.sh          # Bash implementation (source in .bashrc/.zshrc)
```

## How it works

### Storage

- **Nushell config**: `~/.config/work/projects.nuon` (nuon format, list of `{name, path}` records)
- **Bash config**: `~/.config/work/projects.txt` (one `name:path` per line)
- **Worktrees**: `~/workspace/worktrees/<project>/<branch>/` (shared by both implementations)

The two implementations use **separate project registries** but the same worktree directory layout, so worktrees created by one are visible to the other (but projects must be registered in each separately).

### Commands

| Command | Description |
|---|---|
| `work` | Interactive fuzzy picker. Drills down: project → worktree → cd. If already inside a project, starts at worktree level. ESC goes back. |
| `work <branch>` | Create worktree for `<branch>` and cd into it. Auto-registers current repo if unregistered. Creates branch from `origin/main` if new, reuses if exists. Sets up `.claude/settings.local.json`. |
| `work ls` | List worktrees for current project with age, PR number, state, CI status. |
| `work rm [branch]` | Delete a worktree. Infers current worktree if no branch given. Warns if branch still on remote. |
| `work prune` | Across ALL projects: fetch, then remove worktrees whose branches no longer exist on remote. Skips worktrees with uncommitted/unpushed changes. |
| `work add [path]` | Register a git repo as a project. Name derived from directory basename. |

### Key behaviors

- `work <branch>` on an existing worktree just cd's into it (no-op creation).
- `work rm` from inside a worktree auto-cd's to main repo before deleting.
- `work prune` skips worktrees with local changes (uncommitted files or unpushed commits).
- PR info (number, state, CI status) is fetched via `gh pr list` in parallel.
- `mise trust --quiet` is called after cd if `mise` is installed.

### Dependencies

Both: `git`, `gh` (GitHub CLI)
Bash only: `fzf`, `jq`

## Architecture notes

- All commands that change directory use `--env` (nushell) or are shell functions (bash) so `cd` affects the calling shell.
- PR info fetching is parallelized: `par-each` in nushell, background subshells + temp files in bash.
- Worktrees are created with `--no-checkout` then `git checkout HEAD` runs separately (synchronously).
- The nushell version uses `ansi` commands for colors; bash uses raw escape codes via `$'\033[..m'` variables.
