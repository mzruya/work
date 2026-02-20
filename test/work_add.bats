#!/usr/bin/env bats

setup() {
    load helpers/setup
    setup
    create_test_repo "myproject"
}

teardown() {
    load helpers/setup
    teardown
}

@test "add: registers a git repo from inside it" {
    cd "$TEST_REPO_CLONE"
    run work add
    assert_success
    assert_output --partial "Registered 'myproject'"
    assert [ -f "$(projects_file_path)" ]
    project_is_registered "myproject"
}

@test "add: registers with explicit path argument" {
    run work add "$TEST_REPO_CLONE"
    assert_success
    assert_output --partial "Registered 'myproject'"
    project_is_registered "myproject"
}

@test "add: rejects non-git directory" {
    local not_git="$TEST_TMPDIR/not-a-repo"
    mkdir -p "$not_git"
    run work add "$not_git"
    assert_output --partial "Not a git repository"
    # bash returns non-zero exit code; nushell prints error but exits 0
    if [[ "$WORK_SHELL" != "nu" ]]; then
        assert_failure
    fi
}

@test "add: duplicate registration shows already registered" {
    cd "$TEST_REPO_CLONE"
    run work add
    assert_success
    run work add
    assert_success
    assert_output --partial "already registered"
}
