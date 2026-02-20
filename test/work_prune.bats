#!/usr/bin/env bats

setup() {
    load helpers/setup
    setup
    create_test_repo "myproject"
    register_project "myproject" "$TEST_REPO_CLONE"
}

teardown() {
    load helpers/setup
    teardown
}

@test "prune: removes worktree when branch deleted from remote" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success

    # Commit untracked files so worktree appears clean
    local wt_path="$HOME/workspace/worktrees/myproject/my-feature"
    git -C "$wt_path" add -A
    git -C "$wt_path" commit -m "setup" >/dev/null 2>&1

    # Push the branch then delete it from remote
    git -C "$wt_path" push origin my-feature >/dev/null 2>&1
    git -C "$TEST_REPO_REMOTE" branch -D my-feature >/dev/null 2>&1

    cd "$TEST_REPO_CLONE"
    run work prune
    assert_success
    assert_output --partial "removed"
    assert [ ! -d "$wt_path" ]
}

@test "prune: skips worktree with uncommitted changes" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success

    # Branch was never pushed to remote, so it won't exist on remote
    # Add uncommitted changes
    local wt_path="$HOME/workspace/worktrees/myproject/my-feature"
    echo "dirty" > "$wt_path/dirty.txt"

    cd "$TEST_REPO_CLONE"
    run work prune
    assert_success
    assert_output --partial "has local changes - skipped"
    assert [ -d "$wt_path" ]
}

@test "prune: skips worktree with unpushed commits" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success

    # Branch not on remote. Add a commit to the worktree.
    local wt_path="$HOME/workspace/worktrees/myproject/my-feature"
    echo "new" > "$wt_path/new.txt"
    git -C "$wt_path" add new.txt
    git -C "$wt_path" commit -m "unpushed" >/dev/null 2>&1

    cd "$TEST_REPO_CLONE"
    run work prune
    assert_success
    assert_output --partial "has local changes - skipped"
    assert [ -d "$wt_path" ]
}

@test "prune: shows no projects registered with empty config" {
    clear_projects
    run work prune
    assert_success
    assert_output --partial "No projects registered"
}

@test "prune: works across multiple projects" {
    # Save first project references
    local clone1="$TEST_REPO_CLONE"
    local remote1="$TEST_REPO_REMOTE"

    create_test_repo "project2"
    register_project "project2" "$TEST_REPO_CLONE"
    local clone2="$TEST_REPO_CLONE"
    local remote2="$TEST_REPO_REMOTE"

    # Create worktree in project 1, commit, push, then delete from remote
    cd "$clone1"
    run work feat-a
    assert_success
    local wt1="$HOME/workspace/worktrees/myproject/feat-a"
    git -C "$wt1" add -A
    git -C "$wt1" commit -m "setup" >/dev/null 2>&1
    git -C "$wt1" push origin feat-a >/dev/null 2>&1
    git -C "$remote1" branch -D feat-a >/dev/null 2>&1

    # Create worktree in project 2, commit, push, then delete from remote
    cd "$clone2"
    run work feat-b
    assert_success
    local wt2="$HOME/workspace/worktrees/project2/feat-b"
    git -C "$wt2" add -A
    git -C "$wt2" commit -m "setup" >/dev/null 2>&1
    git -C "$wt2" push origin feat-b >/dev/null 2>&1
    git -C "$remote2" branch -D feat-b >/dev/null 2>&1

    cd "$clone1"
    run work prune
    assert_success
    assert_output --partial "removed"
}
