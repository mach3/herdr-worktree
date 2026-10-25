#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
WORKTREE_COMMAND=$PROJECT_DIR/bin/worktree
FIXTURE_BIN=$SCRIPT_DIR/fixtures
ORIGINAL_PATH=$PATH
TEST_PARENT=$(cd "${TMPDIR:-/tmp}" && pwd -P)
TEST_ROOT=$(mktemp -d "$TEST_PARENT/worktree-test.XXXXXX")

passed=0
failed=0

cleanup() {
  case "$TEST_ROOT" in
    "$TEST_PARENT"/worktree-test.*)
      rm -rf -- "$TEST_ROOT"
      ;;
  esac
}
trap cleanup EXIT

pass() {
  passed=$((passed + 1))
  printf 'ok %d - %s\n' "$((passed + failed))" "$1"
}

fail() {
  failed=$((failed + 1))
  printf 'not ok %d - %s\n' "$((passed + failed))" "$1"
  if [[ -n ${2:-} ]]; then
    printf '  %s\n' "$2"
  fi
}

assert_file_contains() {
  local file=$1
  local expected=$2
  grep -F -- "$expected" "$file" >/dev/null 2>&1
}

new_repo() {
  local name=$1
  local repo=$TEST_ROOT/$name/repo

  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.name "Worktree Test"
  git -C "$repo" config user.email "worktree-test@example.invalid"
  git -C "$repo" commit -q --allow-empty -m initial
  printf '%s\n' "$repo"
}

run_test() {
  local description=$1
  shift

  if "$@"; then
    pass "$description"
  else
    fail "$description"
  fi
}

test_help() {
  local output=$TEST_ROOT/help.out
  "$WORKTREE_COMMAND" --help >"$output"
  assert_file_contains "$output" "worktree [OPTIONS] NAME"
}

test_short_base_creates_new_branch_and_tab() {
  local repo
  local base
  local log
  local output

  repo=$(new_repo short-base)
  base=$TEST_ROOT/short-base/trees
  log=$TEST_ROOT/short-base/herdr.log
  output=$TEST_ROOT/short-base/output

  (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      FAKE_HERDR_LOG="$log" \
      "$WORKTREE_COMMAND" -b "$base" feature/login >"$output"
  )

  [[ -d "$base/feature/login" ]] || return 1
  git -C "$repo" show-ref --verify --quiet refs/heads/feature/login || return 1
  assert_file_contains "$log" "tab create --workspace w-test --cwd $base/feature/login --label feature/login --focus" || return 1
  assert_file_contains "$output" "Opened Herdr tab for: $base/feature/login"
}

test_environment_base() {
  local repo
  local base
  local log

  repo=$(new_repo environment-base)
  base=$TEST_ROOT/environment-base/trees
  log=$TEST_ROOT/environment-base/herdr.log

  (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      PROJECT_WORKTREE_DIR="$base" \
      FAKE_HERDR_LOG="$log" \
      "$WORKTREE_COMMAND" topic >/dev/null
  )

  [[ -d "$base/topic" ]]
}

test_option_base_overrides_environment() {
  local repo
  local option_base
  local env_base

  repo=$(new_repo base-precedence)
  option_base=$TEST_ROOT/base-precedence/option
  env_base=$TEST_ROOT/base-precedence/environment

  (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      PROJECT_WORKTREE_DIR="$env_base" \
      "$WORKTREE_COMMAND" --base="$option_base" topic >/dev/null
  )

  [[ -d "$option_base/topic" && ! -e "$env_base/topic" ]]
}

test_existing_branch_is_used() {
  local repo
  local base

  repo=$(new_repo existing-branch)
  base=$TEST_ROOT/existing-branch/trees
  git -C "$repo" branch existing

  (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" --base "$base" existing >/dev/null
  )

  [[ $(git -C "$base/existing" branch --show-current) == existing ]]
}

test_local_agent_configs_are_copied() {
  local repo
  local base
  local output

  repo=$(new_repo local-agent-configs)
  base=$TEST_ROOT/local-agent-configs/trees
  output=$TEST_ROOT/local-agent-configs/output
  mkdir -p "$repo/.claude" "$repo/.codex" "$repo/.zed"
  printf '{"permissions":{"allow":[]}}\n' >"$repo/.claude/settings.local.json"
  printf 'model = "test-model"\n' >"$repo/.codex/config.toml"
  printf '{"tab_size":2}\n' >"$repo/.zed/settings.json"

  (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" --base "$base" topic >"$output" 2>/dev/null
  )

  cmp "$repo/.claude/settings.local.json" "$base/topic/.claude/settings.local.json" || return 1
  cmp "$repo/.codex/config.toml" "$base/topic/.codex/config.toml" || return 1
  cmp "$repo/.zed/settings.json" "$base/topic/.zed/settings.json" || return 1
  assert_file_contains "$output" "Copied local config: .claude/settings.local.json" || return 1
  assert_file_contains "$output" "Copied local config: .codex/config.toml" || return 1
  assert_file_contains "$output" "Copied local config: .zed/settings.json"
}

test_tracked_agent_config_is_not_overwritten() {
  local repo
  local base

  repo=$(new_repo tracked-agent-config)
  base=$TEST_ROOT/tracked-agent-config/trees
  mkdir -p "$repo/.codex"
  printf 'model = "shared-model"\n' >"$repo/.codex/config.toml"
  git -C "$repo" add -- .codex/config.toml
  git -C "$repo" commit -q -m add-shared-config
  printf 'model = "local-override"\n' >"$repo/.codex/config.toml"

  (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" --base "$base" topic >/dev/null
  )

  assert_file_contains "$base/topic/.codex/config.toml" 'model = "shared-model"' || return 1
  [[ -z $(git -C "$base/topic" status --short) ]]
}

test_missing_base_fails_before_creation() {
  local repo
  local error_file

  repo=$(new_repo missing-base)
  error_file=$TEST_ROOT/missing-base/error

  if (
    cd "$repo" || exit
    env -u PROJECT_WORKTREE_DIR \
      PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" topic >/dev/null 2>"$error_file"
  ); then
    return 1
  fi

  assert_file_contains "$error_file" "No worktree base directory specified"
}

test_creation_outside_herdr_fails() {
  local repo
  local base
  local error_file

  repo=$(new_repo outside-herdr)
  base=$TEST_ROOT/outside-herdr/trees
  error_file=$TEST_ROOT/outside-herdr/error

  if (
    cd "$repo" || exit
    env -u HERDR_ENV -u HERDR_WORKSPACE_ID \
      PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      "$WORKTREE_COMMAND" --base "$base" topic >/dev/null 2>"$error_file"
  ); then
    return 1
  fi

  [[ ! -e "$base/topic" ]] || return 1
  assert_file_contains "$error_file" "Creation must be run inside a Herdr-managed pane"
}

test_herdr_failure_rolls_back_new_branch() {
  local repo
  local base
  local error_file

  repo=$(new_repo herdr-failure-new)
  base=$TEST_ROOT/herdr-failure-new/trees
  error_file=$TEST_ROOT/herdr-failure-new/error
  mkdir -p "$repo/.claude"
  printf '{"test":true}\n' >"$repo/.claude/settings.local.json"

  if (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      FAKE_HERDR_FAIL=1 \
      "$WORKTREE_COMMAND" --base "$base" topic >/dev/null 2>"$error_file"
  ); then
    return 1
  fi

  [[ ! -e "$base/topic" ]] || return 1
  if git -C "$repo" show-ref --verify --quiet refs/heads/topic; then
    return 1
  fi
  assert_file_contains "$error_file" "rolling back the worktree"
}

test_herdr_failure_keeps_existing_branch() {
  local repo
  local base

  repo=$(new_repo herdr-failure-existing)
  base=$TEST_ROOT/herdr-failure-existing/trees
  git -C "$repo" branch existing

  if (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      FAKE_HERDR_FAIL=1 \
      "$WORKTREE_COMMAND" --base "$base" existing >/dev/null 2>/dev/null
  ); then
    return 1
  fi

  [[ ! -e "$base/existing" ]] || return 1
  git -C "$repo" show-ref --verify --quiet refs/heads/existing
}

test_worktree_add_failure_rolls_back_side_effects() {
  local repo
  local base
  local target

  repo=$(new_repo worktree-add-failure)
  base=$TEST_ROOT/worktree-add-failure/trees
  target=$base/topic
  mkdir -p "$repo/.git/hooks"
  printf '#!/bin/sh\nexit 1\n' >"$repo/.git/hooks/post-checkout"
  chmod +x "$repo/.git/hooks/post-checkout"

  if (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" --base "$base" topic >/dev/null 2>/dev/null
  ); then
    return 1
  fi

  [[ ! -e "$target" ]] || return 1
  if git -C "$repo" show-ref --verify --quiet refs/heads/topic; then
    return 1
  fi
  if git -C "$repo" worktree list --porcelain | grep -F "worktree $target" >/dev/null; then
    return 1
  fi
}

test_invalid_invocations() {
  local repo
  local base

  repo=$(new_repo invalid-invocations)
  base=$TEST_ROOT/invalid-invocations/trees

  (
    cd "$repo" || exit
    if env -u PROJECT_WORKTREE_DIR "$WORKTREE_COMMAND" >/dev/null 2>&1; then return 1; fi
    if "$WORKTREE_COMMAND" --release topic >/dev/null 2>&1; then return 1; fi
    if "$WORKTREE_COMMAND" --release --base "$base" >/dev/null 2>&1; then return 1; fi
    if "$WORKTREE_COMMAND" --force topic >/dev/null 2>&1; then return 1; fi
    if "$WORKTREE_COMMAND" --unknown >/dev/null 2>&1; then return 1; fi
    if "$WORKTREE_COMMAND" -b >/dev/null 2>&1; then return 1; fi
    if "$WORKTREE_COMMAND" one two >/dev/null 2>&1; then return 1; fi
  )
}

test_invalid_name_and_existing_target_fail() {
  local repo
  local base

  repo=$(new_repo invalid-target)
  base=$TEST_ROOT/invalid-target/trees
  mkdir -p "$base/existing"

  (
    cd "$repo" || exit
    if PATH="$FIXTURE_BIN:$ORIGINAL_PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" --base "$base" '../escape' >/dev/null 2>&1; then return 1; fi
    if PATH="$FIXTURE_BIN:$ORIGINAL_PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" --base "$base" existing >/dev/null 2>&1; then return 1; fi
  )
}

test_branch_in_other_worktree_fails() {
  local repo
  local base

  repo=$(new_repo duplicate-branch)
  base=$TEST_ROOT/duplicate-branch/trees
  git -C "$repo" branch occupied
  git -C "$repo" worktree add -q "$TEST_ROOT/duplicate-branch/occupied" occupied

  if (
    cd "$repo" || exit
    PATH="$FIXTURE_BIN:$ORIGINAL_PATH" HERDR_ENV=1 HERDR_WORKSPACE_ID=w-test \
      "$WORKTREE_COMMAND" --base "$base" occupied >/dev/null 2>&1
  ); then
    return 1
  fi

  [[ ! -e "$base/occupied" ]]
}

test_release_from_subdirectory_keeps_branch() {
  local repo
  local target
  local output

  repo=$(new_repo release-subdirectory)
  target=$TEST_ROOT/release-subdirectory/topic
  output=$TEST_ROOT/release-subdirectory/output
  git -C "$repo" worktree add -q -b topic "$target"
  mkdir -p "$target/sub/directory"

  (
    cd "$target/sub/directory" || exit
    env -u HERDR_ENV -u HERDR_WORKSPACE_ID "$WORKTREE_COMMAND" -r >"$output"
  )

  [[ ! -e "$target" ]] || return 1
  git -C "$repo" show-ref --verify --quiet refs/heads/topic || return 1
  assert_file_contains "$output" "Removed worktree: $target" || return 1
  assert_file_contains "$output" "Press Control-D to close this tab" || return 1
  assert_file_contains "$output" "cd $repo"
}

test_release_long_option() {
  local repo
  local target

  repo=$(new_repo release-long)
  target=$TEST_ROOT/release-long/topic
  git -C "$repo" worktree add -q -b topic "$target"

  (
    cd "$target" || exit
    "$WORKTREE_COMMAND" --release >/dev/null
  )

  [[ ! -e "$target" ]]
}

test_release_refuses_main_worktree() {
  local repo
  local error_file

  repo=$(new_repo release-main)
  error_file=$TEST_ROOT/release-main/error

  if (
    cd "$repo" || exit
    "$WORKTREE_COMMAND" -r >/dev/null 2>"$error_file"
  ); then
    return 1
  fi

  [[ -d "$repo" ]] || return 1
  assert_file_contains "$error_file" "Refusing to remove the main Git worktree"
}

test_release_force_refuses_main_worktree() {
  local repo

  repo=$(new_repo release-force-main)

  if (
    cd "$repo" || exit
    "$WORKTREE_COMMAND" --release --force >/dev/null 2>/dev/null
  ); then
    return 1
  fi

  [[ -d "$repo" ]]
}

test_release_refuses_dirty_worktree() {
  local repo
  local target
  local error_file

  repo=$(new_repo release-dirty)
  target=$TEST_ROOT/release-dirty/topic
  error_file=$TEST_ROOT/release-dirty/error
  git -C "$repo" worktree add -q -b topic "$target"
  printf 'untracked\n' >"$target/untracked.txt"

  if (
    cd "$target" || exit
    "$WORKTREE_COMMAND" -r >/dev/null 2>"$error_file"
  ); then
    return 1
  fi

  [[ -d "$target" ]] || return 1
  assert_file_contains "$error_file" "Could not remove worktree"
}

test_release_force_removes_dirty_worktree() {
  local repo
  local target

  repo=$(new_repo release-force-dirty)
  target=$TEST_ROOT/release-force-dirty/topic
  printf 'original\n' >"$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -q -m add-tracked-file
  git -C "$repo" worktree add -q -b topic "$target"
  printf 'modified\n' >"$target/tracked.txt"
  printf 'untracked\n' >"$target/untracked.txt"

  (
    cd "$target" || exit
    "$WORKTREE_COMMAND" --release --force >/dev/null
  )

  [[ ! -e "$target" ]] || return 1
  git -C "$repo" show-ref --verify --quiet refs/heads/topic
}

test_release_short_force_removes_dirty_worktree() {
  local repo
  local target

  repo=$(new_repo release-short-force-dirty)
  target=$TEST_ROOT/release-short-force-dirty/topic
  git -C "$repo" worktree add -q -b topic "$target"
  printf 'untracked\n' >"$target/untracked.txt"

  (
    cd "$target" || exit
    "$WORKTREE_COMMAND" -r -f >/dev/null
  )

  [[ ! -e "$target" ]]
}

test_release_removes_ignored_files() {
  local repo
  local target

  repo=$(new_repo release-ignored)
  target=$TEST_ROOT/release-ignored/topic
  printf '.env.local\n' >"$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m ignore-local-env
  git -C "$repo" worktree add -q -b topic "$target"
  printf 'ignored local data\n' >"$target/.env.local"

  (
    cd "$target" || exit
    "$WORKTREE_COMMAND" -r >/dev/null
  )

  [[ ! -e "$target" ]]
}

test_release_refuses_unreferenced_detached_head() {
  local repo
  local target
  local error_file

  repo=$(new_repo release-unreferenced-detached)
  target=$TEST_ROOT/release-unreferenced-detached/topic
  error_file=$TEST_ROOT/release-unreferenced-detached/error
  git -C "$repo" worktree add -q --detach "$target"
  git -C "$target" commit -q --allow-empty -m detached-only

  if (
    cd "$target" || exit
    "$WORKTREE_COMMAND" -r >/dev/null 2>"$error_file"
  ); then
    return 1
  fi

  [[ -d "$target" ]] || return 1
  assert_file_contains "$error_file" "detached HEAD is not reachable from any ref"
}

test_release_force_refuses_unreferenced_detached_head() {
  local repo
  local target

  repo=$(new_repo release-force-unreferenced-detached)
  target=$TEST_ROOT/release-force-unreferenced-detached/topic
  git -C "$repo" worktree add -q --detach "$target"
  git -C "$target" commit -q --allow-empty -m detached-only

  if (
    cd "$target" || exit
    "$WORKTREE_COMMAND" --release --force >/dev/null 2>/dev/null
  ); then
    return 1
  fi

  [[ -d "$target" ]]
}

test_release_allows_referenced_detached_head() {
  local repo
  local target

  repo=$(new_repo release-referenced-detached)
  target=$TEST_ROOT/release-referenced-detached/topic
  git -C "$repo" worktree add -q --detach "$target" HEAD

  (
    cd "$target" || exit
    "$WORKTREE_COMMAND" -r >/dev/null
  )

  [[ ! -e "$target" ]]
}

test_release_outside_git_fails() {
  local directory=$TEST_ROOT/not-a-repo
  local error_file=$TEST_ROOT/not-a-repo.error

  mkdir -p "$directory"
  if (
    cd "$directory" || exit
    "$WORKTREE_COMMAND" -r >/dev/null 2>"$error_file"
  ); then
    return 1
  fi

  assert_file_contains "$error_file" "Not inside a Git worktree"
}

printf '1..27\n'
run_test "help describes the command" test_help
run_test "-b creates a nested branch worktree and focused Herdr tab" test_short_base_creates_new_branch_and_tab
run_test "PROJECT_WORKTREE_DIR supplies the base directory" test_environment_base
run_test "--base overrides PROJECT_WORKTREE_DIR" test_option_base_overrides_environment
run_test "an existing local branch is reused" test_existing_branch_is_used
run_test "local Claude, Codex, and Zed project settings are copied" test_local_agent_configs_are_copied
run_test "tracked agent configuration is not overwritten" test_tracked_agent_config_is_not_overwritten
run_test "creation fails when no base directory is configured" test_missing_base_fails_before_creation
run_test "creation fails outside Herdr before changing Git" test_creation_outside_herdr_fails
run_test "Herdr failure rolls back a new branch and worktree" test_herdr_failure_rolls_back_new_branch
run_test "Herdr failure preserves an existing branch" test_herdr_failure_keeps_existing_branch
run_test "worktree add failure rolls back partial Git side effects" test_worktree_add_failure_rolls_back_side_effects
run_test "invalid command-line combinations are rejected" test_invalid_invocations
run_test "invalid names and existing targets are rejected" test_invalid_name_and_existing_target_fail
run_test "a branch already used by another worktree is rejected" test_branch_in_other_worktree_fails
run_test "release works from a subdirectory and keeps the branch" test_release_from_subdirectory_keeps_branch
run_test "--release removes a clean linked worktree" test_release_long_option
run_test "release refuses the main worktree" test_release_refuses_main_worktree
run_test "--force still refuses the main worktree" test_release_force_refuses_main_worktree
run_test "release refuses a dirty worktree" test_release_refuses_dirty_worktree
run_test "--force removes a dirty worktree and keeps its branch" test_release_force_removes_dirty_worktree
run_test "-f removes a dirty worktree in short release mode" test_release_short_force_removes_dirty_worktree
run_test "release removes ignored files with the worktree" test_release_removes_ignored_files
run_test "release refuses an unreferenced detached HEAD" test_release_refuses_unreferenced_detached_head
run_test "--force still refuses an unreferenced detached HEAD" test_release_force_refuses_unreferenced_detached_head
run_test "release allows a detached HEAD reachable from a ref" test_release_allows_referenced_detached_head
run_test "release fails outside a Git worktree" test_release_outside_git_fails

if ((failed > 0)); then
  printf '%d test(s) failed; %d passed.\n' "$failed" "$passed" >&2
  exit 1
fi

printf 'All %d tests passed.\n' "$passed"
