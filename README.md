# work

A CLI tool for managing git worktrees across multiple projects. Switch between branches without stashing or losing context — each branch gets its own full checkout in a central location.

## Features

- **Multi-project support** — register any number of git repos, manage all their worktrees from one tool
- **Interactive fuzzy picker** — drill down from project -> worktree -> cd, with ESC to go back
- **PR status at a glance** — see PR number, state (open/merged/closed), and CI status inline
- **Auto-registration** — run `work <branch>` in any git repo and it registers automatically
- **Merged branch cleanup** — `work prune` removes worktrees across all projects whose branches have been deleted from remote

## Installation

### Nushell

```nushell
# In your config.nu
source ~/.config/nushell/work.nu
```

### Bash / Zsh

Requires `fzf` and `jq` in addition to `git` and `gh`.

```bash
# In your .bashrc or .zshrc
source /path/to/work.sh
```

## Usage

```bash
# Register a project and create your first worktree
cd ~/dev/myproject
work mz-new-feature

# Interactive switcher
work

# List worktrees with PR status
work ls

# Delete current worktree
work rm

# Clean up all merged branches across all projects
work prune

# Register a project without creating a worktree
work add
```

## Commands

| Command | Description |
|---------|-------------|
| `work` | Interactive project -> worktree navigator |
| `work <branch>` | Create worktree and cd into it |
| `work ls` | List worktrees with PR status |
| `work rm [branch]` | Delete worktree (infers current if inside one) |
| `work prune` | Clean up merged worktrees across all projects |
| `work add [path]` | Register a git repo as a project |

## How it works

Projects are registered in `~/.config/work/` and worktrees live under `~/workspace/worktrees/`, organized by project name:

```
~/workspace/worktrees/
├── myproject/
│   ├── mz-new-feature/
│   └── mz-bugfix/
└── other-repo/
    └── mz-experiment/
```

Each worktree is a full git checkout. Creating a worktree fetches `origin/main`, branches from it (or reuses an existing branch), and cd's you into it.

### PR status in `work ls`

```
web worktrees:

  mz-feature-auth   (2 days ago)   #142 open ✓ 12/12  https://github.com/org/web/pull/142
  mz-fix-login      (5 days ago)   #138 merged
  mz-refactor-api   (1 week ago)   #135 open ✗ 8/12   https://github.com/org/web/pull/135
  mz-add-tests      (3 days ago)   <- current
```

## Dependencies

- `git` and `gh` (GitHub CLI) — required by both implementations
- `fzf` and `jq` — required by the bash implementation only
