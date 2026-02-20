#!/usr/bin/env bash
# Shared setup/teardown for work.sh and work.nu BATS tests
#
# Set WORK_SHELL=nu to test the nushell variant (default: bash)

# Locate project root (two levels up from this file)
WORK_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Save real HOME before any test overrides it
REAL_HOME="$HOME"

# Which implementation to test
WORK_SHELL="${WORK_SHELL:-bash}"

load_bats_libs() {
    load "${BATS_LIB_PATH:-/tmp}/bats-support/load"
    load "${BATS_LIB_PATH:-/tmp}/bats-assert/load"
}

setup() {
    load_bats_libs

    # Create isolated temp HOME
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR"

    # Prepend mocks to PATH so gh/fzf resolve to our stubs
    export PATH="$WORK_PROJECT_ROOT/test/mocks:$PATH"

    # Git config needed for commits
    git config --global user.email "test@test.com"
    git config --global user.name "Test User"
    git config --global init.defaultBranch main

    if [[ "$WORK_SHELL" == "nu" ]]; then
        _setup_nu
    else
        _setup_bash
    fi
}

_setup_bash() {
    # Source work.sh — it reads HOME to set its paths
    source "$WORK_PROJECT_ROOT/work.sh"
}

_setup_nu() {
    # Define a bash wrapper function that invokes nushell for each command.
    # We build a nu script that sources work.nu, cd's to the right directory,
    # then runs the command.
    work() {
        local caller_dir
        caller_dir="$(pwd)"
        # Build the nushell command
        local nu_cmd="source $WORK_PROJECT_ROOT/work.nu; cd '$caller_dir'; work $*"
        nu --no-config-file -c "$nu_cmd"
    }

    # For tests that need cd to propagate, we provide a helper that returns
    # the final pwd from the nu process.
    work_and_pwd() {
        local caller_dir
        caller_dir="$(pwd)"
        local nu_cmd="source $WORK_PROJECT_ROOT/work.nu; cd '$caller_dir'; work $*; pwd"
        nu --no-config-file -c "$nu_cmd" | tail -1
    }
}

teardown() {
    export HOME="$REAL_HOME"
    if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Create a test repo with a bare remote and a clone.
# Sets: TEST_REPO_REMOTE, TEST_REPO_CLONE
# Usage: create_test_repo "myproject"
create_test_repo() {
    local name="$1"
    local base="$TEST_TMPDIR/repos"
    mkdir -p "$base"

    # Bare remote
    TEST_REPO_REMOTE="$base/${name}.git"
    git init --bare "$TEST_REPO_REMOTE" >/dev/null 2>&1

    # Clone
    TEST_REPO_CLONE="$base/${name}"
    git clone "$TEST_REPO_REMOTE" "$TEST_REPO_CLONE" >/dev/null 2>&1

    # Initial commit on main
    echo "initial" > "$TEST_REPO_CLONE/README.md"
    git -C "$TEST_REPO_CLONE" add README.md
    git -C "$TEST_REPO_CLONE" commit -m "Initial commit" >/dev/null 2>&1
    git -C "$TEST_REPO_CLONE" push origin main >/dev/null 2>&1
}

# Register a test repo with work (handles both bash and nu config formats)
register_project() {
    local name="$1"
    local path="$2"
    mkdir -p "$HOME/.config/work"

    if [[ "$WORK_SHELL" == "nu" ]]; then
        local projects_file="$HOME/.config/work/projects.nuon"
        if [[ -f "$projects_file" ]]; then
            # Append to existing nuon list — read, strip trailing ], append, re-close
            local content
            content=$(cat "$projects_file")
            # Remove trailing ]
            content="${content%]}"
            # Add comma if not empty list
            if [[ "$content" != "[" ]]; then
                content="${content},"
            fi
            echo "${content} {name: \"${name}\", path: \"${path}\"}]" > "$projects_file"
        else
            echo "[{name: \"${name}\", path: \"${path}\"}]" > "$projects_file"
        fi
    else
        echo "${name}:${path}" >> "$HOME/.config/work/projects.txt"
    fi
}

# Get the projects config file path for the current shell
projects_file_path() {
    if [[ "$WORK_SHELL" == "nu" ]]; then
        echo "$HOME/.config/work/projects.nuon"
    else
        echo "$HOME/.config/work/projects.txt"
    fi
}

# Clear the projects config file
clear_projects() {
    local pf
    pf="$(projects_file_path)"
    if [[ "$WORK_SHELL" == "nu" ]]; then
        echo "[]" > "$pf"
    else
        echo -n > "$pf"
    fi
}

# Check if a project is registered (by name substring in config)
project_is_registered() {
    local name="$1"
    local pf
    pf="$(projects_file_path)"
    [[ -f "$pf" ]] && grep -q "$name" "$pf"
}
