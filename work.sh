#!/usr/bin/env bash
# =============================================================================
# work - Multi-project Git Worktree Manager for Bash
# =============================================================================
#
# Bash port of work.nu. Source this file in your .bashrc/.zshrc:
#   source ~/.config/nushell/work.sh
#
# Requires: git, gh (GitHub CLI), fzf, jq
#
# STORAGE LAYOUT:
#   ~/.config/work/
#   └── projects.txt                     # name:path per line
#
#   ~/workspace/worktrees/
#   ├── <project-name>/
#   │   ├── <branch-1>/
#   │   └── <branch-2>/
#   └── <another-project>/
#       └── <branch>/
#
# =============================================================================

WORK_CONFIG_DIR="$HOME/.config/work"
WORK_PROJECTS_FILE="$HOME/.config/work/projects.txt"
WORK_WORKTREES_DIR="$HOME/workspace/worktrees"

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

_work_check_deps() {
    local missing=()
    local deps=(git gh fzf jq find cut wc tr awk mktemp sort stat basename date)
    for cmd in "${deps[@]}"; do
        if ! type "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Error: Missing required dependencies: ${missing[*]}" >&2
        echo "" >&2
        echo "These commands must be available in your PATH:" >&2
        for cmd in "${missing[@]}"; do
            echo "  - $cmd" >&2
        done
        echo "" >&2
        echo "Current PATH: $PATH" >&2
        return 1
    fi
    return 0
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_work_time_ago() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local hours=$((seconds / 3600))
    local days=$((seconds / 86400))
    local weeks=$((seconds / 604800))
    local months=$((seconds / 2592000))

    if ((months > 0)); then
        if ((months == 1)); then echo "1 month ago"; else echo "${months} months ago"; fi
    elif ((weeks > 0)); then
        if ((weeks == 1)); then echo "1 week ago"; else echo "${weeks} weeks ago"; fi
    elif ((days > 0)); then
        if ((days == 1)); then echo "1 day ago"; else echo "${days} days ago"; fi
    elif ((hours > 0)); then
        if ((hours == 1)); then echo "1 hour ago"; else echo "${hours} hours ago"; fi
    elif ((minutes > 0)); then
        if ((minutes == 1)); then echo "1 minute ago"; else echo "${minutes} minutes ago"; fi
    else
        echo "just now"
    fi
}

_work_ensure_config() {
    [[ -d "$WORK_CONFIG_DIR" ]] || mkdir -p "$WORK_CONFIG_DIR"
}

_work_ensure_worktrees_dir() {
    [[ -d "$WORK_WORKTREES_DIR" ]] || mkdir -p "$WORK_WORKTREES_DIR"
}

# Prints lines of "name:path". Returns empty if no file.
_work_load_projects() {
    if [[ -f "$WORK_PROJECTS_FILE" ]]; then
        cat "$WORK_PROJECTS_FILE"
    fi
}

_work_save_projects() {
    _work_ensure_config
    # stdin -> file
    cat > "$WORK_PROJECTS_FILE"
}

# Sets _WORK_PROJECT_NAME and _WORK_PROJECT_PATH, or clears them.
_work_get_current_project() {
    _WORK_PROJECT_NAME=""
    _WORK_PROJECT_PATH=""
    local current_dir
    current_dir="$(pwd)"

    # Check if we're in a worktree
    if [[ "$current_dir" == "$WORK_WORKTREES_DIR"/* ]]; then
        local relative="${current_dir#"$WORK_WORKTREES_DIR"/}"
        local project_name="${relative%%/*}"
        local match
        match=$(_work_load_projects | grep "^${project_name}:")
        if [[ -n "$match" ]]; then
            _WORK_PROJECT_NAME="${match%%:*}"
            _WORK_PROJECT_PATH="${match#*:}"
            return 0
        fi
    fi

    # Check if we're in a project's main repo
    while IFS=: read -r name path; do
        [[ -z "$name" ]] && continue
        if [[ "$current_dir" == "$path"* ]]; then
            _WORK_PROJECT_NAME="$name"
            _WORK_PROJECT_PATH="$path"
            return 0
        fi
    done < <(_work_load_projects)

    return 1
}

_work_get_worktree_count() {
    local project_name="$1"
    local project_worktrees="$WORK_WORKTREES_DIR/$project_name"
    if [[ -d "$project_worktrees" ]]; then
        find "$project_worktrees" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
    else
        echo 0
    fi
}

_work_branch_exists_on_remote() {
    local branch="$1" repo_path="$2"
    local output
    output=$(git -C "$repo_path" ls-remote --heads origin "$branch" 2>/dev/null)
    [[ -n "$output" ]]
}

_work_has_local_changes() {
    local worktree_path="$1"
    local status
    status=$(git -C "$worktree_path" status --porcelain 2>/dev/null)
    if [[ -n "$status" ]]; then
        return 0
    fi

    local branch
    branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    local unpushed
    unpushed=$(git -C "$worktree_path" log "origin/${branch}..HEAD" --oneline 2>/dev/null)
    if [[ -n "$unpushed" ]]; then
        return 0
    fi

    return 1
}

# Prints JSON-ish fields. Sets _WORK_PR_* variables.
_work_get_pr_info() {
    local branch="$1" main_repo="$2"
    _WORK_PR_NUMBER=""
    _WORK_PR_URL=""
    _WORK_PR_STATE=""
    _WORK_PR_BUILD_STATUS=""
    _WORK_PR_CHECKS_PASSED=0
    _WORK_PR_CHECKS_FAILED=0
    _WORK_PR_CHECKS_PENDING=0
    _WORK_PR_CHECKS_TOTAL=0

    local result
    result=$(gh pr list -R "$main_repo" --head "$branch" --state all \
        --json number,url,state,statusCheckRollup --limit 1 2>/dev/null)
    [[ $? -ne 0 || -z "$result" || "$result" == "[]" ]] && return 1

    _WORK_PR_NUMBER=$(echo "$result" | jq -r '.[0].number')
    _WORK_PR_URL=$(echo "$result" | jq -r '.[0].url')
    _WORK_PR_STATE=$(echo "$result" | jq -r '.[0].state')

    _WORK_PR_CHECKS_TOTAL=$(echo "$result" | jq '.[0].statusCheckRollup // [] | length')
    _WORK_PR_CHECKS_PASSED=$(echo "$result" | jq '[.[0].statusCheckRollup // [] | .[] | select((.state // "") == "SUCCESS")] | length')
    _WORK_PR_CHECKS_FAILED=$(echo "$result" | jq '[.[0].statusCheckRollup // [] | .[] | select((.state // "") == "FAILURE" or (.state // "") == "ERROR")] | length')
    _WORK_PR_CHECKS_PENDING=$(echo "$result" | jq '[.[0].statusCheckRollup // [] | .[] | select((.state // "") == "PENDING")] | length')

    if ((_WORK_PR_CHECKS_TOTAL == 0)); then
        _WORK_PR_BUILD_STATUS="none"
    elif ((_WORK_PR_CHECKS_FAILED > 0)); then
        _WORK_PR_BUILD_STATUS="failing"
    elif ((_WORK_PR_CHECKS_PENDING > 0)); then
        _WORK_PR_BUILD_STATUS="pending"
    elif ((_WORK_PR_CHECKS_PASSED == _WORK_PR_CHECKS_TOTAL)); then
        _WORK_PR_BUILD_STATUS="passing"
    else
        _WORK_PR_BUILD_STATUS="unknown"
    fi

    return 0
}

# =============================================================================
# ANSI helpers
# =============================================================================

_C_RESET=$'\033[0m'
_C_RED=$'\033[31m'
_C_GREEN=$'\033[32m'
_C_YELLOW=$'\033[33m'
_C_BLUE=$'\033[34m'
_C_PURPLE=$'\033[35m'
_C_CYAN=$'\033[36m'
_C_GREY=$'\033[90m'
_C_WHITE_BOLD=$'\033[1;37m'

_work_pr_state_str() {
    case "$1" in
        MERGED) echo "${_C_PURPLE}merged${_C_RESET}" ;;
        CLOSED) echo "${_C_RED}closed${_C_RESET}" ;;
        OPEN)   echo "${_C_GREEN}open${_C_RESET}" ;;
        *)      echo "$1" ;;
    esac
}

_work_build_icon() {
    case "$1" in
        passing) echo "${_C_GREEN}✓${_C_RESET}" ;;
        failing) echo "${_C_RED}✗${_C_RESET}" ;;
        pending) echo "${_C_YELLOW}○${_C_RESET}" ;;
        *)       echo "" ;;
    esac
}

_work_build_color() {
    case "$1" in
        passing) echo "$_C_GREEN" ;;
        failing) echo "$_C_RED" ;;
        pending) echo "$_C_YELLOW" ;;
        *)       echo "$_C_GREY" ;;
    esac
}

# =============================================================================
# COMMAND: work ls
# =============================================================================

_work_ls() {
    _work_get_current_project
    if [[ -z "$_WORK_PROJECT_NAME" ]]; then
        echo "${_C_RED}Error: Not in a registered project${_C_RESET}"
        echo "Use ${_C_CYAN}work add${_C_RESET} to register a project"
        return 1
    fi

    local worktrees_dir="$WORK_WORKTREES_DIR/$_WORK_PROJECT_NAME"
    local main_repo="$_WORK_PROJECT_PATH"

    if [[ ! -d "$worktrees_dir" ]]; then
        echo "${_C_YELLOW}No worktrees for ${_WORK_PROJECT_NAME}${_C_RESET}"
        return 0
    fi

    local dirs=()
    while IFS= read -r d; do
        [[ -n "$d" ]] && dirs+=("$d")
    done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d | sort)

    if ((${#dirs[@]} == 0)); then
        echo "${_C_YELLOW}No worktrees for ${_WORK_PROJECT_NAME}${_C_RESET}"
        return 0
    fi

    local current_dir
    current_dir="$(pwd)"

    echo "${_C_BLUE}${_WORK_PROJECT_NAME}${_C_RESET} worktrees:"
    echo ""

    # Collect info (with parallel gh calls)
    local -a names ages age_strs is_currents
    local -a pr_numbers pr_states pr_build_statuses pr_checks_passed pr_checks_totals pr_urls
    local tmpdir
    tmpdir=$(mktemp -d)

    local i=0
    for d in "${dirs[@]}"; do
        local name
        name=$(basename "$d")
        names+=("$name")

        local mod_time now_time age
        if [[ "$(uname)" == "Darwin" ]]; then
            mod_time=$(stat -f %m "$d")
        else
            mod_time=$(stat -c %Y "$d")
        fi
        now_time=$(date +%s)
        age=$((now_time - mod_time))
        ages+=("$age")
        age_strs+=("$(_work_time_ago "$age")")

        if [[ "$current_dir" == "$d"* ]]; then
            is_currents+=("1")
        else
            is_currents+=("0")
        fi

        # Fetch PR info in background
        (
            if _work_get_pr_info "$name" "$main_repo"; then
                echo "${_WORK_PR_NUMBER}" > "$tmpdir/${i}.number"
                echo "${_WORK_PR_STATE}" > "$tmpdir/${i}.state"
                echo "${_WORK_PR_BUILD_STATUS}" > "$tmpdir/${i}.build"
                echo "${_WORK_PR_CHECKS_PASSED}" > "$tmpdir/${i}.passed"
                echo "${_WORK_PR_CHECKS_TOTAL}" > "$tmpdir/${i}.total"
                echo "${_WORK_PR_URL}" > "$tmpdir/${i}.url"
            fi
        ) &

        ((i++))
    done
    wait

    # Sort by age (ascending)
    local -a sorted_indices
    sorted_indices=($(
        for j in "${!ages[@]}"; do
            echo "$j ${ages[$j]}"
        done | sort -k2 -n | awk '{print $1}'
    ))

    for j in "${sorted_indices[@]}"; do
        local name="${names[$j]}"
        local age_str="${age_strs[$j]}"
        local is_current="${is_currents[$j]}"

        local pr_str=""
        if [[ -f "$tmpdir/${j}.number" ]]; then
            local pr_num pr_state pr_build pr_passed pr_total pr_url
            pr_num=$(cat "$tmpdir/${j}.number")
            pr_state=$(cat "$tmpdir/${j}.state")
            pr_build=$(cat "$tmpdir/${j}.build")
            pr_passed=$(cat "$tmpdir/${j}.passed")
            pr_total=$(cat "$tmpdir/${j}.total")
            pr_url=$(cat "$tmpdir/${j}.url")

            local state_str
            state_str=$(_work_pr_state_str "$pr_state")
            local build_str=""
            if ((pr_total > 0)); then
                local icon color
                icon=$(_work_build_icon "$pr_build")
                color=$(_work_build_color "$pr_build")
                build_str="${icon} ${color}${pr_passed}/${pr_total}${_C_RESET}"
            fi
            pr_str="  ${_C_CYAN}#${pr_num}${_C_RESET} ${state_str} ${build_str} ${_C_GREY}${pr_url}${_C_RESET}"
        fi

        if [[ "$is_current" == "1" ]]; then
            echo "  ${_C_GREEN}${name}${_C_RESET}  ${_C_GREY}(${age_str})${_C_RESET} ${_C_GREEN}<- current${_C_RESET}${pr_str}"
        else
            echo "  ${name}  ${_C_GREY}(${age_str})${_C_RESET}${pr_str}"
        fi
    done

    rm -rf "$tmpdir"
    echo ""
}

# =============================================================================
# COMMAND: work rm [branch]
# =============================================================================

_work_rm() {
    local branch="$1"

    _work_get_current_project
    if [[ -z "$_WORK_PROJECT_NAME" ]]; then
        echo "${_C_RED}Error: Not in a registered project${_C_RESET}"
        return 1
    fi

    local main_repo="$_WORK_PROJECT_PATH"
    local worktrees_dir="$WORK_WORKTREES_DIR/$_WORK_PROJECT_NAME"
    local current_dir
    current_dir="$(pwd)"

    local branch_name="$branch"
    if [[ -z "$branch_name" ]]; then
        if [[ "$current_dir" == "$worktrees_dir"/* ]]; then
            local relative="${current_dir#"$worktrees_dir"/}"
            branch_name="${relative%%/*}"
            echo "${_C_YELLOW}Removing '${branch_name}'...${_C_RESET}"
        else
            echo "${_C_RED}Usage: work rm <branch>${_C_RESET}"
            return 1
        fi
    fi

    local worktree_path="$worktrees_dir/$branch_name"

    if [[ ! -d "$worktree_path" ]]; then
        echo "${_C_RED}Worktree '${branch_name}' not found${_C_RESET}"
        return 1
    fi

    if [[ "$current_dir" == "$worktree_path"* ]]; then
        echo "${_C_YELLOW}Switching to main repo...${_C_RESET}"
        cd "$main_repo" || return 1
    fi

    if _work_branch_exists_on_remote "$branch_name" "$main_repo"; then
        echo "${_C_YELLOW}Warning: Branch still exists on remote${_C_RESET}"
        read -rp "Delete anyway? [y/N] " reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo "${_C_YELLOW}Cancelled${_C_RESET}"
            return 0
        fi
    fi

    git -C "$main_repo" worktree remove "$worktree_path" --force 2>/dev/null
    git -C "$main_repo" branch -D "$branch_name" 2>/dev/null

    echo "${_C_GREEN}Removed ${branch_name}${_C_RESET}"
}

# =============================================================================
# COMMAND: work prune
# =============================================================================

_work_prune() {
    local projects
    projects=$(_work_load_projects)

    if [[ -z "$projects" ]]; then
        echo "${_C_YELLOW}No projects registered${_C_RESET}"
        return 0
    fi

    local current_dir
    current_dir="$(pwd)"
    local total_pruned=0
    local total_skipped=0
    local projects_pruned=0

    while IFS=: read -r name path; do
        [[ -z "$name" ]] && continue
        local main_repo="$path"
        local worktrees_dir="$WORK_WORKTREES_DIR/$name"

        [[ ! -d "$worktrees_dir" ]] && continue

        local dirs=()
        while IFS= read -r d; do
            [[ -n "$d" ]] && dirs+=("$d")
        done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d)

        ((${#dirs[@]} == 0)) && continue

        echo "${_C_BLUE}${name}${_C_RESET} - fetching..."
        git -C "$main_repo" fetch origin --prune 2>/dev/null

        local project_had_prunes=0

        for wt in "${dirs[@]}"; do
            local branch_name
            branch_name=$(basename "$wt")

            if _work_branch_exists_on_remote "$branch_name" "$main_repo"; then
                continue
            fi

            if _work_has_local_changes "$wt"; then
                echo "  ${_C_YELLOW}${branch_name}${_C_RESET}  ${_C_RED}has local changes - skipped${_C_RESET}"
                ((total_skipped++))
                continue
            fi

            if [[ "$(pwd)" == "$wt"* ]]; then
                cd "$main_repo" || true
            fi

            git -C "$main_repo" worktree remove "$wt" --force 2>/dev/null
            git -C "$main_repo" branch -D "$branch_name" 2>/dev/null

            echo "  ${_C_GREY}${branch_name}${_C_RESET}  ${_C_GREEN}removed${_C_RESET}"
            ((total_pruned++))
            project_had_prunes=1
        done

        if ((project_had_prunes)); then
            ((projects_pruned++))
        fi
    done <<< "$projects"

    echo ""
    if ((total_pruned > 0)); then
        echo "${_C_GREEN}Pruned ${total_pruned} worktree(s) across ${projects_pruned} project(s)${_C_RESET}"
    else
        echo "${_C_YELLOW}No worktrees to prune${_C_RESET}"
    fi
    if ((total_skipped > 0)); then
        echo "${_C_YELLOW}Skipped ${total_skipped} with local changes${_C_RESET}"
    fi
}

# =============================================================================
# COMMAND: work add [path]
# =============================================================================

_work_add() {
    local repo_path="${1:-$(pwd)}"
    repo_path=$(cd "$repo_path" 2>/dev/null && pwd)

    if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
        echo "${_C_RED}Error: Not a git repository${_C_RESET}"
        return 1
    fi

    local name
    name=$(basename "$repo_path")

    if _work_load_projects | grep -q "^${name}:"; then
        echo "${_C_YELLOW}Project '${name}' already registered${_C_RESET}"
        return 0
    fi

    if _work_load_projects | grep -q ":${repo_path}$"; then
        echo "${_C_YELLOW}Path already registered${_C_RESET}"
        return 0
    fi

    _work_ensure_config
    echo "${name}:${repo_path}" >> "$WORK_PROJECTS_FILE"

    echo "${_C_GREEN}Registered '${name}'${_C_RESET}"
}

# =============================================================================
# INTERACTIVE: worktree menu
# =============================================================================

# Returns via _WORK_MENU_RESULT: "done", "back", or ""
_work_show_worktree_menu() {
    local project_name="$1" project_path="$2"
    _WORK_MENU_RESULT=""

    local main_repo="$project_path"
    local worktrees_dir="$WORK_WORKTREES_DIR/$project_name"
    local current_dir
    current_dir="$(pwd)"
    local is_in_main=0
    if [[ "$current_dir" == "$project_path"* && "$current_dir" != "$WORK_WORKTREES_DIR"* ]]; then
        is_in_main=1
    fi

    # Build fzf input: "value\tdisplay_line"
    local tmpdir
    tmpdir=$(mktemp -d)
    local entries=()

    # Main repo entry
    local main_label="main  (main repo)"
    if ((is_in_main)); then
        main_label="main  (main repo) <- current"
    fi
    entries+=("__main__	${main_label}")

    # Worktree entries
    if [[ -d "$worktrees_dir" ]]; then
        local dirs=()
        while IFS= read -r d; do
            [[ -n "$d" ]] && dirs+=("$d")
        done < <(find "$worktrees_dir" -mindepth 1 -maxdepth 1 -type d | sort)

        # Fetch PR info in parallel
        local i=0
        for d in "${dirs[@]}"; do
            local wt_name
            wt_name=$(basename "$d")
            (
                if _work_get_pr_info "$wt_name" "$main_repo"; then
                    echo "${_WORK_PR_NUMBER}" > "$tmpdir/${i}.number"
                    echo "${_WORK_PR_STATE}" > "$tmpdir/${i}.state"
                    echo "${_WORK_PR_BUILD_STATUS}" > "$tmpdir/${i}.build"
                    echo "${_WORK_PR_CHECKS_PASSED}" > "$tmpdir/${i}.passed"
                    echo "${_WORK_PR_CHECKS_TOTAL}" > "$tmpdir/${i}.total"
                fi
            ) &
            ((i++))
        done
        wait

        # Build entries sorted by age
        local -a age_entries=()
        i=0
        for d in "${dirs[@]}"; do
            local wt_name mod_time now_time age
            wt_name=$(basename "$d")
            if [[ "$(uname)" == "Darwin" ]]; then
                mod_time=$(stat -f %m "$d")
            else
                mod_time=$(stat -c %Y "$d")
            fi
            now_time=$(date +%s)
            age=$((now_time - mod_time))
            local age_str
            age_str=$(_work_time_ago "$age")

            local is_current=0
            [[ "$current_dir" == "$d"* ]] && is_current=1

            local pr_part=""
            if [[ -f "$tmpdir/${i}.number" ]]; then
                local pr_num pr_state pr_build pr_passed pr_total
                pr_num=$(cat "$tmpdir/${i}.number")
                pr_state=$(cat "$tmpdir/${i}.state")
                pr_build=$(cat "$tmpdir/${i}.build")
                pr_passed=$(cat "$tmpdir/${i}.passed")
                pr_total=$(cat "$tmpdir/${i}.total")
                pr_part="#${pr_num} ${pr_state}"
                if ((pr_total > 0)); then
                    pr_part="${pr_part} ${pr_build} ${pr_passed}/${pr_total}"
                fi
            fi

            local label="${wt_name}  (${age_str})"
            [[ -n "$pr_part" ]] && label="${label} ${pr_part}"
            ((is_current)) && label="${label} <- current"

            age_entries+=("${age}	${wt_name}	${label}")
            ((i++))
        done

        # Sort by age
        while IFS=$'\t' read -r _age val label; do
            entries+=("${val}	${label}")
        done < <(printf '%s\n' "${age_entries[@]}" | sort -t$'\t' -k1 -n)

        rm -rf "$tmpdir"
    fi

    # Present with fzf
    local display_lines=()
    local values=()
    for entry in "${entries[@]}"; do
        local val="${entry%%	*}"
        local label="${entry#*	}"
        values+=("$val")
        display_lines+=("$label")
    done

    local selection
    selection=$(printf '%s\n' "${display_lines[@]}" | fzf --ansi --prompt="${project_name} [esc=back]: " --no-multi)

    if [[ -z "$selection" ]]; then
        _WORK_MENU_RESULT="back"
        return 0
    fi

    # Find matching value
    local selected_value=""
    for idx in "${!display_lines[@]}"; do
        if [[ "${display_lines[$idx]}" == "$selection" ]]; then
            selected_value="${values[$idx]}"
            break
        fi
    done

    if [[ "$selected_value" == "__main__" ]]; then
        cd "$project_path" || return 1
        command -v mise &>/dev/null && mise trust --quiet 2>/dev/null
        _WORK_MENU_RESULT="done"
        return 0
    fi

    local path="$WORK_WORKTREES_DIR/$project_name/$selected_value"
    if [[ -d "$path" ]]; then
        cd "$path" || return 1
        command -v mise &>/dev/null && mise trust --quiet 2>/dev/null
        _WORK_MENU_RESULT="done"
    else
        echo "${_C_RED}Worktree not found: ${path}${_C_RESET}"
        _WORK_MENU_RESULT=""
    fi
}

# =============================================================================
# INTERACTIVE: project switcher
# =============================================================================

_work_switch() {
    local projects
    projects=$(_work_load_projects)

    if [[ -z "$projects" ]]; then
        echo "${_C_YELLOW}No projects registered${_C_RESET}"
        echo "Use ${_C_CYAN}work add${_C_RESET} to register a project"
        return 0
    fi

    _work_get_current_project
    local selected_name="$_WORK_PROJECT_NAME"
    local selected_path="$_WORK_PROJECT_PATH"

    while true; do
        if [[ -n "$selected_name" ]]; then
            _work_show_worktree_menu "$selected_name" "$selected_path"
            if [[ "$_WORK_MENU_RESULT" == "done" ]]; then
                break
            elif [[ "$_WORK_MENU_RESULT" == "back" ]]; then
                selected_name=""
                selected_path=""
            else
                break
            fi
        else
            # Build project list
            local -a proj_entries=()
            while IFS=: read -r name path; do
                [[ -z "$name" ]] && continue
                local count
                count=$(_work_get_worktree_count "$name")
                local display_path="${path/#$HOME/~}"

                local count_str
                if ((count == 0)); then
                    count_str="no worktrees"
                elif ((count == 1)); then
                    count_str="1 worktree"
                else
                    count_str="${count} worktrees"
                fi

                local is_current=0
                [[ "$_WORK_PROJECT_NAME" == "$name" ]] && is_current=1

                local label="${name}  ${count_str}  ${display_path}"
                ((is_current)) && label="${label} <- current"

                proj_entries+=("${name}:${path}	${label}")
            done <<< "$projects"

            local selection
            selection=$(printf '%s\n' "${proj_entries[@]}" | cut -f2 | fzf --ansi --prompt="Select project: " --no-multi)

            if [[ -z "$selection" ]]; then
                break
            fi

            # Find matching project
            for entry in "${proj_entries[@]}"; do
                local label="${entry#*	}"
                if [[ "$label" == "$selection" ]]; then
                    local val="${entry%%	*}"
                    selected_name="${val%%:*}"
                    selected_path="${val#*:}"
                    break
                fi
            done
        fi
    done
}

# =============================================================================
# COMMAND: work <branch> (create/switch to worktree)
# =============================================================================

_work_go() {
    local branch="$1"

    _work_get_current_project
    local project_name="$_WORK_PROJECT_NAME"
    local project_path="$_WORK_PROJECT_PATH"

    # Auto-register if in a git repo
    if [[ -z "$project_name" ]]; then
        if ! git rev-parse --git-dir &>/dev/null; then
            echo "${_C_RED}Error: Not in a git repository${_C_RESET}"
            return 1
        fi

        local repo_root
        repo_root=$(git rev-parse --show-toplevel)
        local name
        name=$(basename "$repo_root")

        echo "${_C_YELLOW}Registering '${name}'...${_C_RESET}"
        _work_ensure_config
        echo "${name}:${repo_root}" >> "$WORK_PROJECTS_FILE"

        project_name="$name"
        project_path="$repo_root"
    fi

    local main_repo="$project_path"
    local worktrees_dir="$WORK_WORKTREES_DIR/$project_name"
    local worktree_path="$worktrees_dir/$branch"

    if [[ ! -d "$worktree_path" ]]; then
        echo "${_C_BLUE}${project_name}${_C_RESET} > ${branch}"
        echo "Fetching origin/main..."
        if ! git -C "$main_repo" fetch origin main 2>/dev/null; then
            echo "${_C_RED}Error: Failed to fetch${_C_RESET}"
            return 1
        fi

        _work_ensure_worktrees_dir
        [[ -d "$worktrees_dir" ]] || mkdir -p "$worktrees_dir"

        local branch_exists
        branch_exists=$(git -C "$main_repo" branch --list "$branch" | tr -d ' ')

        if [[ -n "$branch_exists" ]]; then
            echo "Creating from existing branch..."
            if ! git -C "$main_repo" worktree add --no-checkout "$worktree_path" "$branch" 2>/dev/null; then
                echo "${_C_RED}Error: Failed to create worktree${_C_RESET}"
                return 1
            fi
        else
            echo "Creating new branch from origin/main..."
            if ! git -C "$main_repo" worktree add --no-checkout -b "$branch" "$worktree_path" origin/main 2>/dev/null; then
                echo "${_C_RED}Error: Failed to create worktree${_C_RESET}"
                return 1
            fi
        fi

        mkdir -p "$worktree_path/.claude"
        echo "{\"name\": \"${branch}\"}" > "$worktree_path/.claude/settings.local.json"

        git -C "$worktree_path" checkout HEAD 2>/dev/null
    fi

    cd "$worktree_path" || return 1

    command -v mise &>/dev/null && mise trust --quiet 2>/dev/null
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

work() {
    _work_check_deps || return 1

    local arg="$1"
    shift 2>/dev/null

    if [[ -z "$arg" ]]; then
        _work_switch
        return
    fi

    case "$arg" in
        ls)    _work_ls ;;
        rm)    _work_rm "$@" ;;
        prune) _work_prune ;;
        add)   _work_add "$@" ;;
        *)     _work_go "$arg" ;;
    esac
}
