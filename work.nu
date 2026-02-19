# =============================================================================
# work - Multi-project Git Worktree Manager for Nushell
# =============================================================================
#
# PURPOSE:
#   Manage git worktrees across multiple projects with a unified interface.
#   Enables parallel development on multiple branches without stashing or
#   switching branches in place.
#
# ARCHITECTURE:
#   - Projects are registered repos stored in a central config file
#   - Worktrees are created in a central location, organized by project
#   - Auto-registers projects on first worktree creation
#   - Integrates with GitHub CLI for PR status display
#
# STORAGE LAYOUT:
#   ~/.config/work/
#   └── projects.nuon                    # List of registered projects
#
#   ~/.work/worktrees/
#   ├── <project-name>/                  # One dir per project
#   │   ├── <branch-1>/                  # Each worktree is a full checkout
#   │   └── <branch-2>/
#   └── <another-project>/
#       └── <branch>/
#
# =============================================================================
# CLI REFERENCE
# =============================================================================
#
# COMMANDS:
#
#   work
#     Interactive project/worktree switcher with fuzzy search.
#     - Outside a project: shows project list first
#     - Inside a project: shows worktrees first, press ESC to go back to projects
#     - Displays PR status, build status, and age for each worktree
#
#   work <branch>
#     Create a new worktree for <branch> and cd into it.
#     - Auto-registers the current git repo if not already registered
#     - Creates branch from origin/main if it doesn't exist
#     - Reuses existing branch if it exists locally
#     - Sets up Claude Code session name automatically
#     - Runs git checkout in background for faster startup
#
#   work ls
#     List all worktrees for the current project (non-interactive).
#     - Shows branch name, age, PR number, PR state, and build status
#     - Highlights current worktree
#
#   work rm [branch]
#     Delete a worktree.
#     - If no branch specified, deletes the current worktree
#     - Warns if branch still exists on remote (PR not merged)
#     - Automatically switches to main repo if currently in the worktree
#
#   work prune
#     Clean up merged worktrees across ALL registered projects.
#     - Fetches from origin for each project
#     - Removes worktrees whose branches no longer exist on remote
#     - Skips worktrees with local uncommitted/unpushed changes
#     - Shows summary of pruned/skipped worktrees
#
#   work add [path]
#     Register a git repository as a project.
#     - Defaults to current directory if no path specified
#     - Project name is derived from directory name
#
# =============================================================================
# EXAMPLES
# =============================================================================
#
#   # Register current repo and create a worktree
#   cd ~/dev/myproject
#   work mz-new-feature
#
#   # Switch between worktrees interactively
#   work
#
#   # List worktrees with PR status
#   work ls
#
#   # Delete current worktree
#   work rm
#
#   # Clean up all merged branches
#   work prune
#
# =============================================================================

# Configuration paths (centralized storage)
const WORK_CONFIG_DIR = "~/.config/work"
const WORK_PROJECTS_FILE = "~/.config/work/projects.nuon"
const WORK_WORKTREES_DIR = "~/workspace/worktrees"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Converts a duration in seconds to a human-readable relative time string.
# Used for displaying worktree age in the UI.
# Examples: "just now", "5 minutes ago", "2 days ago", "3 weeks ago"
def time-ago [seconds: int]: nothing -> string {
    let minutes = $seconds // 60
    let hours = $seconds // 3600
    let days = $seconds // 86400
    let weeks = $seconds // 604800
    let months = $seconds // 2592000

    if $months > 0 {
        if $months == 1 { "1 month ago" } else { $"($months) months ago" }
    } else if $weeks > 0 {
        if $weeks == 1 { "1 week ago" } else { $"($weeks) weeks ago" }
    } else if $days > 0 {
        if $days == 1 { "1 day ago" } else { $"($days) days ago" }
    } else if $hours > 0 {
        if $hours == 1 { "1 hour ago" } else { $"($hours) hours ago" }
    } else if $minutes > 0 {
        if $minutes == 1 { "1 minute ago" } else { $"($minutes) minutes ago" }
    } else {
        "just now"
    }
}

# Creates the work config and worktrees directories if they don't exist.
# Called before any write operation to ensure storage is available.
def ensure-work-config []: nothing -> nothing {
    let config_dir = ($WORK_CONFIG_DIR | path expand)
    if not ($config_dir | path exists) {
        mkdir $config_dir
    }
}

# Creates the worktrees base directory if it doesn't exist.
def ensure-worktrees-dir []: nothing -> nothing {
    let worktrees_dir = ($WORK_WORKTREES_DIR | path expand)
    if not ($worktrees_dir | path exists) {
        mkdir $worktrees_dir
    }
}

# Loads the list of registered projects from the config file.
# Returns an empty list if the file doesn't exist.
# Each project has: { name: string, path: string }
def load-projects []: nothing -> list<record<name: string, path: string>> {
    let projects_file = ($WORK_PROJECTS_FILE | path expand)
    if ($projects_file | path exists) {
        open $projects_file
    } else {
        []
    }
}

# Save projects list
def save-projects [projects: list]: nothing -> nothing {
    ensure-work-config
    let projects_file = ($WORK_PROJECTS_FILE | path expand)
    $projects | save -f $projects_file
}

# Determines which project the user is currently in.
# Detection order:
#   1. Check if pwd is inside ~/.config/work/worktrees/<project>/ → return that project
#   2. Check if pwd is inside any registered project's main repo → return that project
#   3. Return null if not in any registered project
def get-current-project [] {
    let current_dir = (pwd | str trim)
    let projects = (load-projects)
    let worktrees_dir = ($WORK_WORKTREES_DIR | path expand)

    # Check if we're in a worktree
    if ($current_dir | str starts-with $worktrees_dir) {
        let relative = ($current_dir | str replace $"($worktrees_dir)/" "")
        let project_name = ($relative | split row "/" | first)
        let matching = ($projects | where name == $project_name)
        if ($matching | is-not-empty) {
            return ($matching | first)
        }
    }

    # Check if we're in a project's main repo
    for project in $projects {
        if ($current_dir | str starts-with $project.path) {
            return $project
        }
    }

    null
}

# Get worktree count for a project
def get-worktree-count [project_name: string]: nothing -> int {
    let worktrees_dir = ($WORK_WORKTREES_DIR | path expand)
    let project_worktrees = $"($worktrees_dir)/($project_name)"

    if ($project_worktrees | path exists) {
        ls $project_worktrees | where type == dir | length
    } else {
        0
    }
}

# Checks if a branch exists on the remote (origin).
# Used to determine if a PR has been merged (branch deleted from remote).
def branch-exists-on-remote [branch: string, repo_path: string]: nothing -> bool {
    (do { git -C $repo_path ls-remote --heads origin $branch } | complete).stdout | str trim | str length | $in > 0
}

# Checks if a worktree has uncommitted changes or unpushed commits.
# Used by `work prune` to avoid deleting worktrees with unsaved work.
def has-local-changes [worktree_path: string]: nothing -> bool {
    let status = (git -C $worktree_path status --porcelain | str trim)
    if ($status | str length) > 0 {
        return true
    }

    let branch = (git -C $worktree_path rev-parse --abbrev-ref HEAD | str trim)
    let unpushed = (do { git -C $worktree_path log $"origin/($branch)..HEAD" --oneline } | complete)
    if $unpushed.exit_code == 0 and ($unpushed.stdout | str trim | str length) > 0 {
        return true
    }

    false
}

# Fetches GitHub PR information for a branch using the `gh` CLI.
# Returns null if no PR exists or on error.
# Returns record with: number, url, state (OPEN/MERGED/CLOSED), build_status, check counts
def get-pr-info [branch: string, main_repo: string] {
    let result = (do { gh pr list -R $main_repo --head $branch --state all --json number,url,state,statusCheckRollup --limit 1 } | complete)
    if $result.exit_code != 0 {
        return null
    }
    let prs = ($result.stdout | from json)
    if ($prs | is-empty) {
        return null
    }
    let pr = ($prs | first)

    let checks = ($pr.statusCheckRollup? | default [])
    let checks_total = ($checks | length)
    let checks_passed = ($checks | where {|c| ($c.state? | default "") == "SUCCESS"} | length)
    let checks_failed = ($checks | where {|c| ($c.state? | default "") in ["FAILURE", "ERROR"]} | length)
    let checks_pending = ($checks | where {|c| ($c.state? | default "") == "PENDING"} | length)

    let build_status = if $checks_total == 0 {
        "none"
    } else if $checks_failed > 0 {
        "failing"
    } else if $checks_pending > 0 {
        "pending"
    } else if $checks_passed == $checks_total {
        "passing"
    } else {
        "unknown"
    }

    {
        number: $pr.number
        url: $pr.url
        state: $pr.state
        build_status: $build_status
        checks_passed: $checks_passed
        checks_failed: $checks_failed
        checks_pending: $checks_pending
        checks_total: $checks_total
    }
}

# =============================================================================
# UI COMPONENTS
# =============================================================================

# Builds the list of selectable items for the worktree menu.
# Includes "main" repo option plus all worktrees with their PR status.
# Each choice has: value (branch name or "__main__"), age, description (formatted for display)
def build-worktree-choices [project: record<name: string, path: string>] {
    let main_repo = $project.path
    let worktrees_base = ($WORK_WORKTREES_DIR | path expand)
    let worktrees_dir = $"($worktrees_base)/($project.name)"
    let current_dir = (pwd | str trim)
    let is_in_main = ($current_dir | str starts-with $main_repo) and not ($current_dir | str starts-with $worktrees_base)

    let worktrees = if ($worktrees_dir | path exists) {
        ls $worktrees_dir | where type == dir
    } else {
        []
    }

    mut choices = []

    # Add "main repo" option
    let main_marker = if $is_in_main { $" (ansi green)<- current(ansi reset)" } else { "" }
    let main_str = if $is_in_main { $"(ansi green)main(ansi reset)" } else { "main" }
    $choices = ($choices | append {
        value: "__main__"
        age: -2
        description: $"($main_str)  (ansi grey)\(main repo\)(ansi reset)($main_marker)"
    })

    if ($worktrees | is-not-empty) {
        let wt_choices = $worktrees
        | par-each {|wt|
            let name = ($wt.name | path basename)
            let path = $wt.name
            let created = ($wt.modified | into int) // 1_000_000_000
            let now = (date now | into int) // 1_000_000_000
            let age = $now - $created
            let age_str = (time-ago $age)
            let is_current = ($current_dir | str starts-with $path)
            let pr_info = (get-pr-info $name $main_repo)

            let pr_str = if ($pr_info != null) {
                let state_str = match $pr_info.state {
                    "MERGED" => $"(ansi purple)merged(ansi reset)"
                    "CLOSED" => $"(ansi red)closed(ansi reset)"
                    "OPEN" => $"(ansi green)open(ansi reset)"
                    _ => $pr_info.state
                }
                let build_str = if $pr_info.checks_total == 0 {
                    ""
                } else {
                    let icon = match $pr_info.build_status {
                        "passing" => $"(ansi green)✓(ansi reset)"
                        "failing" => $"(ansi red)✗(ansi reset)"
                        "pending" => $"(ansi yellow)○(ansi reset)"
                        _ => ""
                    }
                    let count_color = match $pr_info.build_status {
                        "passing" => "green"
                        "failing" => "red"
                        "pending" => "yellow"
                        _ => "grey"
                    }
                    $"($icon) (ansi $count_color)($pr_info.checks_passed)/($pr_info.checks_total)(ansi reset)"
                }
                $"(ansi cyan)#($pr_info.number)(ansi reset) ($state_str) ($build_str)"
            } else {
                ""
            }

            let current_marker = if $is_current { $" (ansi green)<- current(ansi reset)" } else { "" }
            let name_str = if $is_current { $"(ansi green)($name)(ansi reset)" } else { $name }

            {
                value: $name
                age: $age
                description: $"($name_str)  (ansi grey)\(($age_str)\)(ansi reset) ($pr_str)($current_marker)"
            }
        }
        | sort-by age

        $choices = ($choices | append $wt_choices)
    }

    $choices
}

# Displays the interactive worktree selection menu for a project.
# Returns:
#   - "done" if user selected a worktree/main and cd'd to it
#   - "back" if user pressed ESC to go back to project selection
#   - null if an error occurred
def --env show-worktree-menu [project: record<name: string, path: string>]: nothing -> string {
    let choices = (build-worktree-choices $project)
    let worktrees_base = ($WORK_WORKTREES_DIR | path expand)

    let selection = ($choices | get description | input list --fuzzy $"($project.name) [esc=back]:")

    if ($selection | is-empty) {
        return "back"
    }

    let selected_choice = ($choices | where description == $selection | first)

    if $selected_choice.value == "__main__" {
        cd $project.path
        if (which mise | is-not-empty) {
            do { mise trust --quiet } | complete | ignore
        }
        return "done"
    }

    let branch = $selected_choice.value
    let path = $"($worktrees_base)/($project.name)/($branch)"

    if ($path | path exists) {
        cd $path
        if (which mise | is-not-empty) {
            do { mise trust --quiet } | complete | ignore
        }
        return "done"
    } else {
        print $"(ansi red)Worktree not found: ($path)(ansi reset)"
        return null
    }
}

# =============================================================================
# COMMAND IMPLEMENTATIONS
# =============================================================================

# Lists all worktrees for the current project with their status.
# Displays: branch name, age, PR number, PR state, build status (✓/✗/○)
# Requires being inside a registered project.
def "work ls" []: nothing -> nothing {
    let project = (get-current-project)
    if ($project == null) {
        print $"(ansi red)Error: Not in a registered project(ansi reset)"
        print $"Use (ansi cyan)work add(ansi reset) to register a project"
        return
    }

    let worktrees_base = ($WORK_WORKTREES_DIR | path expand)
    let worktrees_dir = $"($worktrees_base)/($project.name)"
    let main_repo = $project.path

    if not ($worktrees_dir | path exists) {
        print $"(ansi yellow)No worktrees for ($project.name)(ansi reset)"
        return
    }

    let worktrees = (ls $worktrees_dir | where type == dir)

    if ($worktrees | is-empty) {
        print $"(ansi yellow)No worktrees for ($project.name)(ansi reset)"
        return
    }

    let current_dir = (pwd | str trim)

    print $"(ansi blue)($project.name)(ansi reset) worktrees:"
    print ""

    $worktrees
    | par-each {|wt|
        let name = ($wt.name | path basename)
        let path = $wt.name
        let created = ($wt.modified | into int) // 1_000_000_000
        let now = (date now | into int) // 1_000_000_000
        let age = $now - $created
        let age_str = (time-ago $age)
        let is_current = ($current_dir | str starts-with $path)
        let pr_info = (get-pr-info $name $main_repo)

        { name: $name, age_str: $age_str, age: $age, is_current: $is_current, pr_info: $pr_info }
    }
    | sort-by age
    | each {|row|
        let pr_str = if ($row.pr_info != null) {
            let state_str = match $row.pr_info.state {
                "MERGED" => $"(ansi purple)merged(ansi reset)"
                "CLOSED" => $"(ansi red)closed(ansi reset)"
                "OPEN" => $"(ansi green)open(ansi reset)"
                _ => $row.pr_info.state
            }
            let build_str = if $row.pr_info.checks_total == 0 {
                ""
            } else {
                let icon = match $row.pr_info.build_status {
                    "passing" => $"(ansi green)✓(ansi reset)"
                    "failing" => $"(ansi red)✗(ansi reset)"
                    "pending" => $"(ansi yellow)○(ansi reset)"
                    _ => ""
                }
                let count_color = match $row.pr_info.build_status {
                    "passing" => "green"
                    "failing" => "red"
                    "pending" => "yellow"
                    _ => "grey"
                }
                $"($icon) (ansi $count_color)($row.pr_info.checks_passed)/($row.pr_info.checks_total)(ansi reset)"
            }
            $"  (ansi cyan)#($row.pr_info.number)(ansi reset) ($state_str) ($build_str) (ansi grey)($row.pr_info.url)(ansi reset)"
        } else {
            ""
        }

        if $row.is_current {
            print $"  (ansi green)($row.name)(ansi reset)  (ansi grey)\(($row.age_str)\)(ansi reset) (ansi green)<- current(ansi reset)($pr_str)"
        } else {
            print $"  ($row.name)  (ansi grey)\(($row.age_str)\)(ansi reset)($pr_str)"
        }
    }

    print ""
}

# Deletes a worktree and its local branch.
# If no branch specified and currently inside a worktree, deletes that worktree.
# Warns if branch still exists on remote (indicates unmerged PR).
# Automatically cd's to main repo if deleting current worktree.
def --env "work rm" [
    branch?: string  # Branch name to delete (optional if in worktree)
]: nothing -> nothing {
    let project = (get-current-project)
    if ($project == null) {
        print $"(ansi red)Error: Not in a registered project(ansi reset)"
        return
    }

    let main_repo = $project.path
    let worktrees_base = ($WORK_WORKTREES_DIR | path expand)
    let worktrees_dir = $"($worktrees_base)/($project.name)"
    let current_dir = (pwd | str trim)

    let branch_name = if ($branch | is-empty) {
        if ($current_dir | str starts-with $worktrees_dir) {
            let relative = ($current_dir | str replace $"($worktrees_dir)/" "")
            let inferred = ($relative | split row "/" | first)
            print $"(ansi yellow)Removing '($inferred)'...(ansi reset)"
            $inferred
        } else {
            print $"(ansi red)Usage: work rm <branch>(ansi reset)"
            return
        }
    } else {
        $branch
    }

    let worktree_path = $"($worktrees_dir)/($branch_name)"

    if not ($worktree_path | path exists) {
        print $"(ansi red)Worktree '($branch_name)' not found(ansi reset)"
        return
    }

    if ($current_dir | str starts-with $worktree_path) {
        print $"(ansi yellow)Switching to main repo...(ansi reset)"
        cd $main_repo
    }

    if (branch-exists-on-remote $branch_name $main_repo) {
        print $"(ansi yellow)Warning: Branch still exists on remote(ansi reset)"
        let reply = (input "Delete anyway? [y/N] ")
        if not ($reply =~ "^[Yy]$") {
            print $"(ansi yellow)Cancelled(ansi reset)"
            return
        }
    }

    do { git -C $main_repo worktree remove $worktree_path --force } | complete | ignore
    do { git -C $main_repo branch -D $branch_name } | complete | ignore

    print $"(ansi green)Removed ($branch_name)(ansi reset)"
}

# Cleans up worktrees whose branches have been deleted from remote.
# Operates across ALL registered projects (not just current).
# For each project:
#   1. Fetches from origin to get latest remote branch state
#   2. Checks each worktree - if branch no longer on remote, it's considered merged
#   3. Skips worktrees with local uncommitted/unpushed changes
#   4. Removes worktree directory and local branch
def --env "work prune" []: nothing -> nothing {
    let projects = (load-projects)

    if ($projects | is-empty) {
        print $"(ansi yellow)No projects registered(ansi reset)"
        return
    }

    let worktrees_base = ($WORK_WORKTREES_DIR | path expand)
    let current_dir = (pwd | str trim)
    mut total_pruned = 0
    mut total_skipped = 0
    mut projects_pruned = 0

    for project in $projects {
        let main_repo = $project.path
        let worktrees_dir = $"($worktrees_base)/($project.name)"

        if not ($worktrees_dir | path exists) {
            continue
        }

        let worktrees = (ls $worktrees_dir | where type == dir)
        if ($worktrees | is-empty) {
            continue
        }

        print $"(ansi blue)($project.name)(ansi reset) - fetching..."
        do { git -C $main_repo fetch origin --prune } | complete | ignore

        mut project_had_prunes = false

        for wt in $worktrees {
            let branch_name = ($wt.name | path basename)
            let worktree_path = $wt.name

            if (branch-exists-on-remote $branch_name $main_repo) {
                continue
            }

            if (has-local-changes $worktree_path) {
                print $"  (ansi yellow)($branch_name)(ansi reset)  (ansi red)has local changes - skipped(ansi reset)"
                $total_skipped = $total_skipped + 1
                continue
            }

            if ($current_dir | str starts-with $worktree_path) {
                cd $main_repo
            }

            do { git -C $main_repo worktree remove $worktree_path --force } | complete | ignore
            do { git -C $main_repo branch -D $branch_name } | complete | ignore

            print $"  (ansi grey)($branch_name)(ansi reset)  (ansi green)removed(ansi reset)"
            $total_pruned = $total_pruned + 1
            $project_had_prunes = true
        }

        if $project_had_prunes {
            $projects_pruned = $projects_pruned + 1
        }
    }

    print ""
    if $total_pruned > 0 {
        print $"(ansi green)Pruned ($total_pruned) worktree\(s\) across ($projects_pruned) project\(s\)(ansi reset)"
    } else {
        print $"(ansi yellow)No worktrees to prune(ansi reset)"
    }
    if $total_skipped > 0 {
        print $"(ansi yellow)Skipped ($total_skipped) with local changes(ansi reset)"
    }
}

# Registers a git repository as a managed project.
# The project name is derived from the directory name (e.g., ~/dev/web → "web").
# Projects can also be auto-registered by using `work <branch>` in an unregistered repo.
def "work add" [
    path?: string  # Path to git repo (defaults to current directory)
]: nothing -> nothing {
    let repo_path = if ($path | is-empty) {
        pwd | str trim
    } else {
        $path | path expand
    }

    let in_git_repo = (do { git -C $repo_path rev-parse --git-dir } | complete).exit_code == 0
    if not $in_git_repo {
        print $"(ansi red)Error: Not a git repository(ansi reset)"
        return
    }

    let name = ($repo_path | path basename)
    let projects = (load-projects)

    if ($projects | where name == $name | is-not-empty) {
        print $"(ansi yellow)Project '($name)' already registered(ansi reset)"
        return
    }

    if ($projects | where path == $repo_path | is-not-empty) {
        print $"(ansi yellow)Path already registered(ansi reset)"
        return
    }

    let new_projects = ($projects | append { name: $name, path: $repo_path })
    save-projects $new_projects

    print $"(ansi green)Registered '($name)'(ansi reset)"
}

# Interactive two-level navigator for projects and worktrees.
# Flow:
#   - If inside a project: shows worktree list first, ESC goes to project list
#   - If outside a project: shows project list first, selecting enters worktree list
# This creates a drill-down interface: Projects → Worktrees → cd to selection
def --env work-switch []: nothing -> nothing {
    let current_project = (get-current-project)
    let projects = (load-projects)

    if ($projects | is-empty) {
        print $"(ansi yellow)No projects registered(ansi reset)"
        print $"Use (ansi cyan)work add(ansi reset) to register a project"
        return
    }

    mut selected_project_name = if ($current_project != null) { $current_project.name } else { "" }
    mut selected_project_path = if ($current_project != null) { $current_project.path } else { "" }

    loop {
        if ($selected_project_name != "") {
            let result = (show-worktree-menu { name: $selected_project_name, path: $selected_project_path })
            if $result == "done" {
                break
            } else if $result == "back" {
                $selected_project_name = ""
                $selected_project_path = ""
            } else {
                break
            }
        } else {
            let home = $env.HOME
            let choices = $projects
            | each {|p|
                let count = (get-worktree-count $p.name)
                let is_current = ($current_project != null and $current_project.name == $p.name)
                let display_path = ($p.path | str replace $home "~")

                let count_str = if $count == 0 {
                    $"(ansi grey)no worktrees(ansi reset)"
                } else if $count == 1 {
                    $"(ansi cyan)1 worktree(ansi reset)"
                } else {
                    $"(ansi cyan)($count) worktrees(ansi reset)"
                }

                let current_marker = if $is_current { $" (ansi green)<- current(ansi reset)" } else { "" }
                let name_str = if $is_current { $"(ansi green)($p.name)(ansi reset)" } else { $"(ansi white_bold)($p.name)(ansi reset)" }

                {
                    value: $p.name
                    path: $p.path
                    description: $"($name_str)  ($count_str)  (ansi grey)($display_path)(ansi reset)($current_marker)"
                }
            }

            let selection = ($choices | get description | input list --fuzzy "Select project:")

            if ($selection | is-empty) {
                break
            }

            let selected = ($choices | where description == $selection | first)
            $selected_project_name = $selected.value
            $selected_project_path = $selected.path
        }
    }
}

# Creates a new worktree for the given branch and cd's into it.
# Behavior:
#   1. If not in a registered project, auto-registers current git repo
#   2. Fetches origin/main to ensure we have latest
#   3. If branch exists locally, creates worktree from it
#   4. If branch doesn't exist, creates new branch from origin/main
#   5. Sets up .claude/settings.local.json with session name
#   6. Runs git checkout in background for faster startup
#   7. cd's into the worktree
def --env work-go [branch: string]: nothing -> nothing {
    mut project = (get-current-project)

    # Auto-register if in a git repo
    if ($project == null) {
        let in_git_repo = (do { git rev-parse --git-dir } | complete).exit_code == 0
        if not $in_git_repo {
            print $"(ansi red)Error: Not in a git repository(ansi reset)"
            return
        }

        let repo_root = (git rev-parse --show-toplevel | str trim)
        let name = ($repo_root | path basename)

        print $"(ansi yellow)Registering '($name)'...(ansi reset)"
        let projects = (load-projects)
        let new_projects = ($projects | append { name: $name, path: $repo_root })
        save-projects $new_projects

        $project = { name: $name, path: $repo_root }
    }

    let main_repo = $project.path
    let worktrees_base = ($WORK_WORKTREES_DIR | path expand)
    let worktrees_dir = $"($worktrees_base)/($project.name)"
    let worktree_path = $"($worktrees_dir)/($branch)"

    if not ($worktree_path | path exists) {
        print $"(ansi blue)($project.name)(ansi reset) > ($branch)"
        print "Fetching origin/main..."
        let fetch_result = (do { git -C $main_repo fetch origin main } | complete)
        if $fetch_result.exit_code != 0 {
            print $"(ansi red)Error: Failed to fetch(ansi reset)"
            return
        }

        ensure-worktrees-dir
        if not ($worktrees_dir | path exists) {
            mkdir $worktrees_dir
        }

        let branch_exists = (git -C $main_repo branch --list $branch | str trim | str length) > 0

        if $branch_exists {
            print $"Creating from existing branch..."
            let result = (do { git -C $main_repo worktree add --no-checkout $worktree_path $branch } | complete)
            if $result.exit_code != 0 {
                print $"(ansi red)Error: ($result.stderr)(ansi reset)"
                return
            }
        } else {
            print $"Creating new branch from origin/main..."
            let result = (do { git -C $main_repo worktree add --no-checkout -b $branch $worktree_path origin/main } | complete)
            if $result.exit_code != 0 {
                print $"(ansi red)Error: ($result.stderr)(ansi reset)"
                return
            }
        }

        mkdir $"($worktree_path)/.claude"
        $'{"name": "($branch)"}' | save -f $"($worktree_path)/.claude/settings.local.json"

        do { git -C $worktree_path checkout HEAD } | complete | ignore
    }

    cd $worktree_path

    if (which mise | is-not-empty) {
        do { mise trust --quiet } | complete | ignore
    }
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Main command dispatcher. Routes to appropriate subcommand or creates worktree.
# Usage:
#   work           → Interactive switcher (work-switch)
#   work ls        → List worktrees
#   work prune     → Clean up merged worktrees
#   work add       → Register current repo
#   work <branch>  → Create worktree (work-go)
def --env work [
    arg?: string  # Branch name or subcommand (ls, rm, prune, add)
]: nothing -> nothing {
    if ($arg | is-empty) {
        work-switch
        return
    }

    if $arg == "ls" {
        work ls
        return
    }

    if $arg == "prune" {
        work prune
        return
    }

    if $arg == "add" {
        work add
        return
    }

    # Treat as branch name
    work-go $arg
}
