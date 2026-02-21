# Work - Multi-Project Git Worktree Manager

## Product Overview

**Problem:** Developers working across multiple repositories need to context-switch between branches frequently. Traditional `git stash` / `git checkout` workflows are slow and error-prone.

**Solution:** A unified CLI that manages git worktrees across all your projects. Each branch gets its own directory, enabling true parallel development. All worktrees are stored centrally for easy discovery and cleanup.

## Implementations

Two shell scripts with identical behavior:

1. **`work.sh`** — Bash/Zsh (source in `.bashrc`/`.zshrc`). Uses `fzf` for selection, plain text config.
2. **`work.nu`** — Nushell (source in `config.nu`). Uses `input list --fuzzy` for selection, `.nuon` config.

Both must be sourceable so `cd` affects the calling shell.

## File Structure

```
work.nu                         # Nushell implementation
work.sh                         # Bash implementation
test/                           # Integration tests (bats)
  helpers/setup.bash            # Test helpers
  mocks/                        # Mock binaries (gh, fzf)
  work_add.bats                 # Tests for work add
  work_go.bats                  # Tests for work <branch>
  work_ls.bats                  # Tests for work ls
  work_prune.bats               # Tests for work prune
  work_rm.bats                  # Tests for work rm
.github/workflows/test.yml      # CI workflow
```

## Storage Layout

```
~/.config/work/
├── projects.nuon               # Nushell registry (list of {name, path} records)
└── projects.txt                # Bash registry (one name:path per line)

~/workspace/worktrees/
├── <project>/
│   ├── <branch>/               # Full git worktree
│   └── <branch>/
└── <project>/
    └── <branch>/
```

The two implementations use **separate project registries** but the same worktree directory layout, so worktrees created by one are visible to the other (but projects must be registered in each separately).

---

## CLI Reference

| Command | Description |
|---------|-------------|
| `work` | Interactive project -> worktree navigator |
| `work <branch>` | Create worktree and cd into it |
| `work ls` | List worktrees with PR status |
| `work rm [branch]` | Delete worktree |
| `work prune` | Clean up merged worktrees (all projects) |
| `work add [path]` | Register a project |

---

## Behavioral Specifications

### `work` — Interactive Navigator

**Entry point behavior depends on context:**

| Context | Initial View |
|---------|--------------|
| Outside any project | Project list |
| Inside a registered project | Worktree list for that project |

**Navigation:**
- Select project -> shows its worktrees
- Press ESC in worktree view -> returns to project list
- Select worktree -> cd to that directory

**Project list:**
```
Select project:
> web           3 worktrees   ~/workspace/web
  zenpayroll    1 worktree    ~/workspace/zenpayroll
  api           no worktrees  ~/workspace/api    <- current
```

**Worktree list:**
```
web [esc=back]:
> main                (main repo)
  mz-feature-auth     (2 days ago)   #142 open   ✓ 12/12
  mz-fix-login        (5 days ago)   #138 merged
  mz-refactor-api     (1 week ago)   #135 open   ✗ 8/12
  mz-add-tests        (3 days ago)              <- current
```

### `work <branch>` — Create Worktree

1. **Auto-register:** If not in a registered project but in a git repo, register it automatically
2. **Fetch:** Run `git fetch origin main`
3. **Create:**
   - If branch exists locally -> create worktree from it
   - If branch doesn't exist -> create new branch from `origin/main`
4. **Setup:** Create `.claude/settings.local.json` with `{"name": "<branch>"}`
5. **Navigate:** cd into the worktree
6. **Post-cd:** Run `mise trust --quiet` if `mise` is installed

**New branch:**
```
~/workspace/web $ work mz-new-feature
web > mz-new-feature
Fetching origin/main...
Creating new branch from origin/main...
~/workspace/worktrees/web/mz-new-feature $
```

**Auto-register:**
```
~/workspace/newproject $ work mz-first-branch
Registering 'newproject'...
newproject > mz-first-branch
Fetching origin/main...
Creating new branch from origin/main...
~/workspace/worktrees/newproject/mz-first-branch $
```

**Existing worktree (no-op, just cd):**
```
~/workspace/web $ work mz-existing-feature
web > mz-existing-feature
~/workspace/worktrees/web/mz-existing-feature $
```

### `work ls` — List Worktrees

**Requires:** Must be inside a registered project.

```
~/workspace/web $ work ls
web worktrees:

  mz-feature-auth   (2 days ago)   #142 open ✓ 12/12  https://github.com/org/web/pull/142
  mz-fix-login      (5 days ago)   #138 merged
  mz-refactor-api   (1 week ago)   #135 open ✗ 8/12   https://github.com/org/web/pull/135
  mz-add-tests      (3 days ago)   <- current
```

**No worktrees:**
```
~/workspace/api $ work ls
No worktrees for api
```

**Not in project:**
```
~/random/dir $ work ls
Error: Not in a registered project
Use work add to register a project
```

### `work rm [branch]` — Delete Worktree

**Branch resolution:**
- If branch provided -> delete that worktree
- If no branch and inside a worktree -> delete current worktree
- If no branch and not in worktree -> error with usage hint

**Safety checks:**
1. If branch still exists on remote -> warn user (PR may not be merged)
2. Require confirmation to proceed

**Cleanup:**
- Remove worktree directory
- Delete local branch
- If deleting current worktree -> cd to main repo

**Delete current (merged):**
```
~/workspace/worktrees/web/mz-old-feature $ work rm
Removing 'mz-old-feature'...
Removed mz-old-feature
~/workspace/web $
```

**Delete by name:**
```
~/workspace/web $ work rm mz-old-feature
Removed mz-old-feature
```

**Branch still on remote:**
```
~/workspace/worktrees/web/mz-wip $ work rm
Warning: Branch still exists on remote
Delete anyway? [y/N] y
Switching to main repo...
Removed mz-wip
~/workspace/web $
```

**Not in worktree:**
```
~/workspace/web $ work rm
Usage: work rm <branch>
```

### `work prune` — Cleanup Merged Worktrees

**Scope:** Operates across ALL registered projects.

**For each project:**
1. Fetch from origin to update remote branch info
2. For each worktree:
   - Skip if branch still exists on remote
   - Skip (with warning) if has uncommitted changes or unpushed commits
   - Otherwise -> remove worktree and local branch

**Normal operation:**
```
$ work prune
web - fetching...
  mz-old-feature      removed
  mz-shipped          removed
zenpayroll - fetching...
  mz-done             removed

Pruned 3 worktree(s) across 2 project(s)
```

**With local changes:**
```
$ work prune
web - fetching...
  mz-old-feature      removed
  mz-wip              has local changes - skipped
zenpayroll - fetching...

Pruned 1 worktree(s) across 1 project(s)
Skipped 1 with local changes
```

**Nothing to prune:**
```
$ work prune
web - fetching...
zenpayroll - fetching...

No worktrees to prune
```

**No projects:**
```
$ work prune
No projects registered
```

### `work add [path]` — Register Project

- Path defaults to current directory
- Validates path is a git repository
- Project name = directory basename
- Prevents duplicate registrations (by name or path)

**Register current directory:**
```
~/workspace/web $ work add
Registered 'web'
```

**Register by path:**
```
$ work add ~/workspace/api
Registered 'api'
```

**Already registered:**
```
~/workspace/web $ work add
Project 'web' already registered
```

**Not a git repo:**
```
~/random/dir $ work add
Error: Not a git repository
```

---

## Project Detection Logic

To determine "current project":

1. Is pwd inside `~/workspace/worktrees/<project>/...`? -> that project
2. Is pwd inside any registered project's path? -> that project
3. Otherwise -> not in a project

---

## Display Standards

### Colors
| Element | Color |
|---------|-------|
| Open PR | Green |
| Merged PR | Purple |
| Closed PR | Red |
| Passing checks | Green |
| Failing checks | Red |
| Pending checks | Yellow |
| Current worktree | Green |
| PR numbers | Cyan |
| Paths, timestamps | Grey/dim |

### CI Status Format
```
✓ 5/5    # All passing (green)
✗ 3/5    # Has failures (red)
○ 4/5    # Has pending (yellow)
```

---

## Technical Requirements

### Bash/Zsh (`work.sh`)
- Define `work()` function with case statement
- Use `fzf` for fuzzy selection (with `--ansi` for colors)
- Use `jq` for JSON parsing
- Use background jobs (`&` + `wait`) for parallel PR fetching
- Store temp data in `$TMPDIR` or `/tmp`

### Nushell (`work.nu`)
- Define `def --env work` (env required for cd)
- Use `input list --fuzzy` for selection
- Use native `from json` for parsing
- Use `par-each` for parallel PR fetching

### Dependencies
- Both: `git`, `gh` (GitHub CLI)
- Bash only: `fzf`, `jq`
- Handle missing dependencies gracefully

---

## Edge Cases

- No projects registered -> prompt to use `work add`
- No worktrees for project -> show empty state
- `gh` CLI not available -> skip PR status, show branch names only
- Branch has no PR -> show branch without PR info
- Worktree has detached HEAD -> handle gracefully
- User cancels selection (ESC) -> exit cleanly

---

## Testing

Tests use [bats-core](https://github.com/bats-core/bats-core) and live in `test/`. Mock binaries for `gh` and `fzf` are in `test/mocks/`. Run tests with:

```bash
bats test/
```

Use `--fail-fast` to stop on first failure.
