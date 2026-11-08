#!/usr/bin/env bats
# Unit tests for entrypoint.sh; every privileged command is stubbed.

setup() {
  # shellcheck source=../../entrypoint.sh
  source "${BATS_TEST_DIRNAME}/../../entrypoint.sh"
  SEED_CONFIG="$BATS_TEST_TMPDIR/seed.toml"
  ROOT_HOME="$BATS_TEST_TMPDIR/root"
  CA_DIR="$BATS_TEST_TMPDIR/ca"
  GIT_SYSTEM_CONFIG="$BATS_TEST_TMPDIR/gitconfig"
  mkdir -p "$ROOT_HOME" "$CA_DIR"
  unset HOST_UID HOST_GID VIBE_DOCKER_TRUSTED_WORKSPACES
  # Each stub echoes its call so tests can assert on what ran.
  chown() { echo "chown $*"; }
  groupadd() { echo "groupadd $*"; }
  useradd() { echo "useradd $*"; }
  # Its output is discarded by install_cas, so it logs to a file.
  update-ca-certificates() { echo ran >> "$BATS_TEST_TMPDIR/ca.log"; }
  find() { :; }
  xargs() { :; }
  # Entries getent knows about, e.g. "passwd vibe" or "group 1000".
  KNOWN=""
  getent() { [[ " $KNOWN " == *" $1 $2 "* ]]; }
  # UID `id -u vibe` reports for a pre-existing vibe user.
  VIBE_UID=1000
  id() { echo "$VIBE_UID"; }
  # exec bypasses shell functions, so runuser is a PATH stub.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "runuser $*"\n' > "$BATS_TEST_TMPDIR/bin/runuser"
  chmod +x "$BATS_TEST_TMPDIR/bin/runuser"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "HOST_UID unset execs the command as root" {
  run main echo hello
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "HOST_UID=0 execs the command without creating a user" {
  HOST_UID=0 run main echo hello
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "non-root HOST_UID creates vibe and drops via runuser" {
  HOST_UID=1000 HOST_GID=1000 run main vibe --flag
  [ "$status" -eq 0 ]
  [[ "$output" == *"groupadd -o -g 1000 vibe"* ]]
  [[ "$output" == *"useradd -o -K UID_MIN=1 -u 1000 -g 1000 -d /root -s /bin/bash -M -N vibe"* ]]
  [[ "$output" == *"runuser -u vibe -- vibe --flag"* ]]
}

@test "existing GID is reused, no groupadd" {
  KNOWN="group 20"
  run ensure_user 501 20
  [ "$status" -eq 0 ]
  [[ "$output" != *groupadd* ]]
  [[ "$output" == *"useradd -o -K UID_MIN=1 -u 501 -g 20"* ]]
}

@test "HOST_UID colliding with an image user still creates vibe" {
  KNOWN="passwd 1000 group 1000"
  run ensure_user 1000 1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"useradd -o -K UID_MIN=1 -u 1000 -g 1000"* ]]
}

@test "existing vibe user with HOST_UID is left alone" {
  KNOWN="passwd vibe"
  run ensure_user 1000 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "existing vibe user with another UID is refused" {
  KNOWN="passwd vibe"
  VIBE_UID=0
  run ensure_user 1000 1000
  [ "$status" -ne 0 ]
  [ "$output" = "entrypoint: ERROR existing vibe user has UID 0, expected HOST_UID 1000" ]
}

@test "existing vibe user with another UID stops main before runuser" {
  KNOWN="passwd vibe"
  VIBE_UID=1001
  HOST_UID=1000 HOST_GID=1000 run main vibe
  [ "$status" -ne 0 ]
  [[ "$output" == *"existing vibe user has UID 1001, expected HOST_UID 1000"* ]]
  [[ "$output" != *runuser* ]]
}

@test "EROFS chown errors are filtered out" {
  xargs() { echo "chown: changing ownership of '/root/.aws/config': Read-only file system" >&2; return 1; }
  run chown_volumes 1000 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "other chown errors are reported as WARN" {
  xargs() {
    echo "chown: changing ownership of '/root/.aws/config': Read-only file system" >&2
    echo "chown: changing ownership of '/root/x': Operation not permitted" >&2
    return 1
  }
  run chown_volumes 1000 1000
  [ "$status" -eq 0 ]
  [ "$output" = "entrypoint: WARN chown: chown: changing ownership of '/root/x': Operation not permitted" ]
}

@test "find errors are reported as WARN" {
  find() { echo "find: '/root/y': Permission denied" >&2; return 1; }
  run chown_volumes 1000 1000
  [ "$status" -eq 0 ]
  [ "$output" = "entrypoint: WARN chown: find: '/root/y': Permission denied" ]
}

@test "chown walk skips a missing /root/.vibe" {
  find() { printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/find.args"; }
  chown_volumes 1000 1000
  [ "$(head -2 "$BATS_TEST_TMPDIR/find.args")" = "$ROOT_HOME"$'\n'"-xdev" ]
  mkdir "$ROOT_HOME/.vibe"
  chown_volumes 1000 1000
  [ "$(head -2 "$BATS_TEST_TMPDIR/find.args")" = "$ROOT_HOME"$'\n'"$ROOT_HOME/.vibe" ]
}

@test "chown walk runs under LC_ALL=C" {
  xargs() { echo "LC_ALL=${LC_ALL-}" >&2; }
  HOST_UID=1000 HOST_GID=1000 run main true
  [[ "$output" == *"entrypoint: WARN chown: LC_ALL=C"* ]]
}

# --- trust_workspaces ---

# The safe.directory values written to the stand-in system config.
trusted() { command git config --file "$GIT_SYSTEM_CONFIG" --get-all safe.directory | paste -sd,; }

@test "trust_workspaces: each vouched-for workspace and its nested repos are trusted" {
  VIBE_DOCKER_TRUSTED_WORKSPACES=/workspaces/repo:/workspaces/other run trust_workspaces
  [ "$status" -eq 0 ] && [ -z "$output" ]
  [ "$(trusted)" = "/workspaces/repo,/workspaces/repo/*,/workspaces/other,/workspaces/other/*" ]
}

@test "trust_workspaces: no list writes nothing" {
  run trust_workspaces
  [ "$status" -eq 0 ]
  [ ! -e "$GIT_SYSTEM_CONFIG" ]
}

@test "trust_workspaces: anything but /workspaces/<name> is refused with a WARN" {
  VIBE_DOCKER_TRUSTED_WORKSPACES='*:/workspaces/*:/workspaces/a/b:/workspaces/..:/workspaces/:/etc:/workspaces/ok' \
    run trust_workspaces
  [ "$status" -eq 0 ]
  [ "$(trusted)" = "/workspaces/ok,/workspaces/ok/*" ]
  [ "$(grep -c 'entrypoint: WARN not trusting' <<<"$output")" -eq 6 ]
}

@test "trust_workspaces: also runs when the session stays root" {
  # Container root is not the host owner either, so git still needs the entry.
  VIBE_DOCKER_TRUSTED_WORKSPACES=/workspaces/repo run main echo hello
  [ "$status" -eq 0 ] && [ "$output" = hello ]
  [ "$(trusted)" = "/workspaces/repo,/workspaces/repo/*" ]
}

@test "trust_workspaces: a failed write stops main before the exec" {
  git() { return 1; }
  VIBE_DOCKER_TRUSTED_WORKSPACES=/workspaces/repo run main echo should-not-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"entrypoint: ERROR could not trust /workspaces/repo for git"* ]]
  [[ "$output" != *should-not-run* ]]
}

@test "no vibe-docker CA skips update-ca-certificates" {
  run install_cas
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ca.log" ]
}

@test "vibe-docker CA present runs update-ca-certificates" {
  touch "$CA_DIR/vibe-docker-gh.crt"
  run install_cas
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ca.log")" = ran ]
}

@test "CA refresh failure warns and the entrypoint continues" {
  touch "$CA_DIR/vibe-docker-gh.crt"
  update-ca-certificates() { return 1; }
  HOST_UID=0 run main echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"entrypoint: WARN update-ca-certificates failed"* ]]
  [[ "$output" == *"hello"* ]]
}

@test "config seed replaces config.toml with mode 600" {
  echo 'theme = "mistral-dark"' > "$SEED_CONFIG"
  mkdir -p "$ROOT_HOME/.vibe"
  echo stale > "$ROOT_HOME/.vibe/config.toml"
  run seed_config
  [ "$status" -eq 0 ]
  [ "$output" = "chown root $ROOT_HOME/.vibe" ]
  [ "$(cat "$ROOT_HOME/.vibe/config.toml")" = 'theme = "mistral-dark"' ]
  [ "$(stat -c %a "$ROOT_HOME/.vibe/config.toml")" = 600 ]
  # A regular file, not a link to the seed: vibe renames over it in-session.
  [ -f "$ROOT_HOME/.vibe/config.toml" ] && [ ! -L "$ROOT_HOME/.vibe/config.toml" ]
}

@test "config seed creates ~/.vibe when the volume is fresh" {
  echo 'active_model = "devstral"' > "$SEED_CONFIG"
  run seed_config
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT_HOME/.vibe/config.toml")" = 'active_model = "devstral"' ]
}

@test "absent config seed touches nothing" {
  run seed_config
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ROOT_HOME/.vibe" ]
}

@test "absent config seed keeps the config.toml an earlier session saved" {
  mkdir -p "$ROOT_HOME/.vibe"
  echo 'theme = "saved"' > "$ROOT_HOME/.vibe/config.toml"
  run seed_config
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$ROOT_HOME/.vibe/config.toml")" = 'theme = "saved"' ]
}

@test "failed config seed aborts before the exec" {
  echo '' > "$SEED_CONFIG"
  chown() { return 7; }
  run main echo hello
  [ "$status" -eq 7 ]
  [[ "$output" != *hello* ]]
}

@test "the seed path is fixed, not taken from the environment" {
  # Re-source with a hostile environment: the globals are plain assignments.
  export SEED_CONFIG=/etc/shadow
  source "${BATS_TEST_DIRNAME}/../../entrypoint.sh"
  [ "$SEED_CONFIG" = /run/vibe-docker/config.toml ]
}

@test "failed groupadd aborts before useradd and runuser" {
  groupadd() { return 9; }
  HOST_UID=1000 HOST_GID=1000 run main vibe
  [ "$status" -eq 9 ]
  [[ "$output" != *useradd* ]]
  [[ "$output" != *runuser* ]]
}

@test "failed useradd aborts before runuser" {
  useradd() { return 9; }
  HOST_UID=1000 HOST_GID=1000 run main vibe
  [ "$status" -eq 9 ]
  [[ "$output" != *runuser* ]]
}
