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

@test "go: creates worktree directory at expected path" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success
    assert [ -d "$HOME/workspace/worktrees/myproject/my-feature" ]
}

@test "go: creates .claude/settings.local.json in worktree" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success
    local settings="$HOME/workspace/worktrees/myproject/my-feature/.claude/settings.local.json"
    assert [ -f "$settings" ]
    run cat "$settings"
    assert_output --partial '"name"'
    assert_output --partial 'my-feature'
}

@test "go: creates git branch in main repo" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success
    run git -C "$TEST_REPO_CLONE" branch --list my-feature
    assert_output --partial "my-feature"
}

@test "go: existing worktree is a no-op" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success
    # Second call should succeed without error
    run work my-feature
    assert_success
    assert [ -d "$HOME/workspace/worktrees/myproject/my-feature" ]
}

@test "go: auto-registers unregistered repo" {
    clear_projects

    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success
    assert_output --partial "Registering 'myproject'"
    project_is_registered "myproject"
}

@test "go: reuses existing local branch and preserves commits" {
    cd "$TEST_REPO_CLONE"

    # Create branch with a commit
    git checkout -b my-feature >/dev/null 2>&1
    echo "extra" > extra.txt
    git add extra.txt
    git commit -m "extra commit" >/dev/null 2>&1
    local commit_sha
    commit_sha=$(git rev-parse HEAD)
    git checkout main >/dev/null 2>&1

    run work my-feature
    assert_success
    local wt_path="$HOME/workspace/worktrees/myproject/my-feature"
    local wt_sha
    wt_sha=$(git -C "$wt_path" rev-parse HEAD)
    assert [ "$commit_sha" = "$wt_sha" ]
}

@test "go: fails outside git repo" {
    local no_git="$TEST_TMPDIR/empty"
    mkdir -p "$no_git"
    cd "$no_git"

    clear_projects

    run work my-feature
    assert_output --partial "Not in a git repository"
    if [[ "$WORK_SHELL" != "nu" ]]; then
        assert_failure
    fi
}

@test "go: cd's into the worktree" {
    if [[ "$WORK_SHELL" == "nu" ]]; then
        cd "$TEST_REPO_CLONE"
        local result
        result="$(work_and_pwd my-feature)"
        assert [ "$result" = "$HOME/workspace/worktrees/myproject/my-feature" ]
    else
        cd "$TEST_REPO_CLONE"
        work my-feature
        assert [ "$(pwd)" = "$HOME/workspace/worktrees/myproject/my-feature" ]
    fi
}
