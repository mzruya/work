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

@test "ls: shows no worktrees when none exist" {
    cd "$TEST_REPO_CLONE"
    run work ls
    assert_success
    assert_output --partial "No worktrees"
}

@test "ls: lists created worktrees by branch name" {
    cd "$TEST_REPO_CLONE"
    run work feat-one
    assert_success
    cd "$TEST_REPO_CLONE"
    run work ls
    assert_success
    assert_output --partial "feat-one"
}

@test "ls: works after creating multiple worktrees" {
    cd "$TEST_REPO_CLONE"
    run work feat-one
    assert_success
    cd "$TEST_REPO_CLONE"
    run work feat-two
    assert_success
    cd "$TEST_REPO_CLONE"
    run work ls
    assert_success
    assert_output --partial "feat-one"
    assert_output --partial "feat-two"
}
