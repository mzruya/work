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

@test "rm: deletes worktree directory and shows Removed" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success
    cd "$TEST_REPO_CLONE"
    run work rm my-feature
    assert_success
    assert_output --partial "Removed my-feature"
    assert [ ! -d "$HOME/workspace/worktrees/myproject/my-feature" ]
}

@test "rm: deletes git branch from repo" {
    cd "$TEST_REPO_CLONE"
    run work my-feature
    assert_success
    cd "$TEST_REPO_CLONE"
    run work rm my-feature
    assert_success
    run git -C "$TEST_REPO_CLONE" branch --list my-feature
    assert_output ""
}

@test "rm: fails for nonexistent worktree" {
    cd "$TEST_REPO_CLONE"
    run work rm nonexistent
    assert_output --partial "not found"
    if [[ "$WORK_SHELL" != "nu" ]]; then
        assert_failure
    fi
}
