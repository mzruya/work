# Work

`work` manages [git worktrees](https://git-scm.com/docs/git-worktree) with multi-project management, an interactive picker, and GitHub PR status.

```
~/workspace/web $ work mz-auth-redesign
Fetching origin/main...
Creating new branch from origin/main...
~/workspace/worktrees/web/mz-auth-redesign $
```

## Quick start

**Bash / Zsh** (requires `fzf` and `jq`):

```bash
# In your .bashrc or .zshrc
source /path/to/work.sh
```

**Nushell**:

```nushell
# In your config.nu
source ~/.config/nushell/work.nu
```

Both implementations require `git` and `gh` (GitHub CLI).

## Commands

| Command | What it does |
|---------|-------------|
| `work` | Interactive fuzzy picker: project -> worktree -> cd |
| `work <branch>` | Create a worktree (or cd into an existing one) |
| `work ls` | List worktrees with PR status and CI results |
| `work rm [branch]` | Delete a worktree and its local branch |
| `work prune` | Clean up merged worktrees across all projects |
| `work add [path]` | Register a git repo as a project |

## How it looks

### Interactive navigator (`work`)

Fuzzy-select a project, then a worktree. ESC goes back.

```
Select project:
> web           3 worktrees   ~/workspace/web
  zenpayroll    1 worktree    ~/workspace/zenpayroll
  api           no worktrees  ~/workspace/api
```

### Worktree list (`work ls`)

PR state, CI status, and links — all inline.

```
web worktrees:

  mz-feature-auth   (2 days ago)   #142 open ✓ 12/12  https://github.com/org/web/pull/142
  mz-fix-login      (5 days ago)   #138 merged
  mz-refactor-api   (1 week ago)   #135 open ✗ 8/12   https://github.com/org/web/pull/135
  mz-add-tests      (3 days ago)   <- current
```

### Prune merged branches (`work prune`)

Cleans up across every registered project in one shot.

```
$ work prune
web - fetching...
  mz-old-feature      removed
  mz-shipped          removed
zenpayroll - fetching...
  mz-done             removed

Pruned 3 worktree(s) across 2 project(s)
```

## Storage layout

Projects are registered in `~/.config/work/` and worktrees live under `~/workspace/worktrees/`:

```
~/workspace/worktrees/
├── web/
│   ├── mz-feature-auth/      # full git checkout
│   └── mz-fix-login/
└── api/
    └── mz-experiment/
```

## Two implementations, same behavior

| | Bash/Zsh (`work.sh`) | Nushell (`work.nu`) |
|---|---|---|
| Fuzzy picker | `fzf` | `input list --fuzzy` |
| Config format | plain text | `.nuon` |
| JSON parsing | `jq` | native `from json` |
| Parallelism | background jobs | `par-each` |

Both use the same worktree directory layout, so worktrees are cross-visible.
