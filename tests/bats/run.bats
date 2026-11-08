#!/usr/bin/env bats
# Unit tests for run.sh; docker, podman, gh, glab and git are stubbed as shell
# functions, so nothing here needs a container engine or network.
# Globals set here are read by the sourced run.sh functions (SC2034), and
# "~/cfg" is a deliberately literal tilde (SC2088).
# shellcheck disable=SC2034,SC2088

setup() {
  bats_require_minimum_version 1.5.0
  # shellcheck source=../../run.sh
  source "${BATS_TEST_DIRNAME}/../../run.sh"
  # What main does first: on macOS the open-file check is inode-only.
  init_shell
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  unset GH_TOKEN GITHUB_TOKEN GITLAB_TOKEN GITLAB_HOST VIBE_DOCKER_RUNTIME \
    VIBE_DOCKER_GH_POLICY VIBE_DOCKER_GLAB_POLICY VIBE_DOCKER_AZ_CA \
    VIBE_DOCKER_ADD_HOSTS VIBE_DOCKER_TMUX VIBE_DOCKER_TEST_ENTRY VIBE_DOCKER_FLAGS \
    MISTRAL_API_KEY VIBE_DOCKER_GLAB_UPSTREAM VIBE_DOCKER_GH_UPSTREAM VIBE_DOCKER_CONFIG_DIR
  # Computed when run.sh was sourced, before HOME moved above.
  VIBE_CONFIG_DIR="$HOME/.vibe"
  RUNTIME=docker
  # Knobs for the docker stub: STUB_FAIL names subcommands that fail ("run",
  # or "network:connect" for one sub-subcommand), STUB_PS is the
  # stopped-container list, STUB_ALIVE the running sidecar id, STUB_LOGS what
  # `logs` prints (what the sidecar has logged so far), STUB_LOGS_ERR what it
  # prints on stderr (the container's stderr).
  STUB_FAIL="" STUB_PS="" STUB_ALIVE="cid" STUB_IP="10.0.0.2"
  STUB_LOGS="serving initial configuration" STUB_LOGS_ERR=""
  docker() {
    echo "docker $*" >>"$CALLS"
    case " $STUB_FAIL " in *" $1 "*|*" $1:${2:-} "*) return 1 ;; esac
    case "$1" in
      ps)
        if [ "$2" = "-aq" ]; then [ -z "$STUB_PS" ] || printf '%s\n' $STUB_PS
        else echo "$STUB_ALIVE"; fi ;;
      network) [ "$2" = "ls" ] && echo "net1"; return 0 ;;
      cp) echo "CA" >"$3" ;;
      inspect) echo "$STUB_IP" ;;
      logs)
        printf '%s\n' "$STUB_LOGS"
        [ -z "$STUB_LOGS_ERR" ] || printf '%s\n' "$STUB_LOGS_ERR" >&2 ;;
    esac
    return 0
  }
  podman() { echo "podman $*" >>"$CALLS"; }
  gh() { echo "gh $*" >>"$CALLS"; echo "gho_stub"; }
  glab() { echo "glab $*" >>"$CALLS"; [ "$2" = "get" ] && [ "$3" = "token" ] && echo "glpat_stub"; return 0; }
  git() {
    case "$*" in
      "config --global --get user.name") echo "Ada Lovelace" ;;
      "config --global --get user.email") echo "ada@example.com" ;;
      *) return 1 ;;
    esac
  }
  sleep() { :; }
  WS="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WS"
}

# Race tests start a background swapper; never leave it running.
teardown() {
  [ -z "${SWAPPER:-}" ] || kill "$SWAPPER" 2>/dev/null || true
}

# Newline-joined array, for substring assertions.
lines_of() { printf '%s\n' "$@"; }

# `set -e` is ignored inside `run`, so paths that depend on it run in a fresh
# bash: run_script executes run.sh itself, run_script_fn sources it under
# `set -euo pipefail` and evals $1. The stubs reach the child as exported
# functions.
export_stubs() {
  export -f docker podman gh glab git sleep
  export CALLS STUB_FAIL STUB_PS STUB_ALIVE STUB_IP STUB_LOGS STUB_LOGS_ERR
}
run_script() {
  export_stubs
  run "${BATS_TEST_DIRNAME}/../../run.sh" "$@"
}
run_script_fn() {
  export_stubs
  run bash -c 'set -euo pipefail; source "$1"; RUNTIME=docker; eval "$2"' _ \
    "${BATS_TEST_DIRNAME}/../../run.sh" "$1"
}

# --- parse_args ---

@test "parse_args: unknown flag is rejected" {
  run parse_args --bogus
  [ "$status" -eq 1 ]
  [ "$output" = "vibe-docker: unknown flag '--bogus' (use -- to pass flags to vibe)" ]
}

@test "parse_args: --help prints usage and exits 0" {
  run parse_args --help --bogus
  [ "$status" -eq 0 ]
  [[ "$output" == Usage:* ]]
  [[ "$output" != *"unknown flag"* ]]
}

@test "parse_args: flags, workspaces and passthrough after --" {
  parse_args --yolo --gh --ro a b -- --resume --bogus
  [ "$WITH_GH" = 1 ] && [ "$RO_WORKSPACES" = 1 ]
  [ "$(lines_of "${WORKSPACES[@]}")" = "$(printf 'a\nb')" ]
  [ "$(lines_of "${VIBE_FLAGS[@]}")" = "$(printf -- '--auto-approve\n--resume\n--bogus')" ]
}

@test "parse_args: workspace defaults to PWD" {
  cd "$WS"
  parse_args
  [ "${WORKSPACES[0]}" = "$WS" ]
}

@test "parse_args: --ro=PATH marks only that workspace, in order" {
  parse_args a --ro=b c
  [ "$(lines_of "${WORKSPACES[@]}")" = "$(printf 'a\nb\nc')" ]
  [ "$(lines_of "${WORKSPACES_RO[@]}")" = "$(printf '0\n1\n0')" ]
  [ "$RO_WORKSPACES" = 0 ]
}

@test "parse_args: --ro=~/x expands the tilde" {
  parse_args a '--ro=~/x'
  [ "${WORKSPACES[1]}" = "$HOME/x" ]
}

@test "parse_args: --ro=PATH counts as a workspace, so PWD is not added" {
  cd "$WS"
  parse_args --ro=b --ro=c
  [ "$(lines_of "${WORKSPACES[@]}")" = "$(printf 'b\nc')" ]
  [ "$(lines_of "${WORKSPACES_RO[@]}")" = "$(printf '1\n1')" ]
}

@test "parse_args: --ro=. mounts PWD read-only as the working dir" {
  cd "$WS"
  parse_args --ro=.
  build_workspace_mounts
  [ "$CWD" = /workspaces/repo ]
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = "$(printf -- '-v\n%s:/workspaces/repo:ro' "$WS")" ]
}

@test "parse_args: empty --ro= is rejected" {
  run parse_args --ro= a
  [ "$status" -eq 1 ]
  [[ "$output" == *"--ro= needs a path"* ]]
}

@test "parse_args: --iterm and --tmux set VIBE_DOCKER_TMUX" {
  parse_args --iterm
  [ "$VIBE_DOCKER_TMUX" = cc ]
  parse_args --tmux
  [ "$VIBE_DOCKER_TMUX" = 1 ]
}

@test "parse_args: expands a leading ~/ in the config dir" {
  VIBE_CONFIG_DIR="~/cfg"
  parse_args
  [ "$VIBE_CONFIG_DIR" = "$HOME/cfg" ]
}

@test "parse_args: leaves ~user paths alone" {
  parse_args "--vibe-dir=~alice/cfg"
  [ "$VIBE_CONFIG_DIR" = "~alice/cfg" ]
}

@test "parse_args: --vibe-dir=PATH sets the config dir, and wins over the env var" {
  VIBE_CONFIG_DIR="$HOME/from-env"
  parse_args "--vibe-dir=~/.vibe-work"
  [ "$VIBE_CONFIG_DIR" = "$HOME/.vibe-work" ]
}

@test "parse_args: VIBE_DOCKER_CONFIG_DIR sets the config dir, default ~/.vibe" {
  run_script_fn 'printf "%s\n" "$VIBE_CONFIG_DIR"'
  [ "$output" = "$HOME/.vibe" ]
  export VIBE_DOCKER_CONFIG_DIR='~/.vibe-work'
  run_script_fn 'parse_args; printf "%s\n" "$VIBE_CONFIG_DIR"'
  [ "$output" = "$HOME/.vibe-work" ]
}

@test "parse_args: --mistral sets WITH_MISTRAL" {
  parse_args --mistral
  [ "$WITH_MISTRAL" = 1 ]
}

@test "parse_args: removed flags are unknown-flag errors" {
  local f upstream_dir
  # The upstream project's config-dir flag, spelled so this file names no
  # other agent.
  upstream_dir="--$(printf 'cl%sude' a)-dir=x"
  for f in --api --api-direct --egress-lock --egress-allowlist --egress-allowlist=x "$upstream_dir"; do
    run parse_args "$f" a
    [ "$status" -eq 1 ] || { echo "$f was accepted"; return 1; }
    [ "$output" = "vibe-docker: unknown flag '$f' (use -- to pass flags to vibe)" ]
  done
}

@test "parse_args: removed flags after -- reach vibe unchanged" {
  parse_args a -- --api --egress-lock
  [ "$(lines_of "${VIBE_FLAGS[@]}")" = "$(printf -- '--api\n--egress-lock')" ]
}

# --- print_help ---

@test "print_help: documents every wrapper flag and variable, none of the removed ones" {
  run print_help
  [ "$status" -eq 0 ]
  local item upstream_dir
  upstream_dir="--$(printf 'cl%sude' a)-dir"
  for item in --yolo --ephemeral --ro --ro=PATH --aws --gh --gh-direct --glab --glab-direct \
    --tfe --az --registry --mistral --iterm --tmux --vibe-dir -h --help -- \
    VIBE_DOCKER_TMUX VIBE_DOCKER_CONFIG_DIR VIBE_DOCKER_AZ_CA VIBE_DOCKER_ADD_HOSTS \
    VIBE_DOCKER_IMAGE VIBE_DOCKER_RUNTIME VIBE_DOCKER_PROXY_IMAGE VIBE_DOCKER_GH_POLICY \
    VIBE_DOCKER_GLAB_POLICY MISTRAL_API_KEY config.docker.toml; do
    [[ "$output" == *"$item"* ]] || { echo "help lacks $item"; return 1; }
  done
  for item in --api --egress-lock --egress-allowlist "$upstream_dir" statusline settings.docker.json; do
    [[ "$output" != *"$item"* ]] || { echo "help still has $item"; return 1; }
  done
  [[ "$output" == "Usage: vibe-docker "* ]]
  [[ "$output" == *"Hardened Docker wrapper for Mistral Vibe"* ]]
  [[ "$output" == *"1  → plain tmux"* ]] && [[ "$output" == *"cc → tmux -CC"* ]]
}

@test "print_help: --yolo names --auto-approve, --mistral says the session can read the key" {
  run print_help
  local yolo mistral
  yolo=$(sed -n '/^  --yolo/,/^  --ephemeral/p' <<<"$output")
  [[ "$yolo" == *"--auto-approve"* ]]
  mistral=$(sed -n '/^  --mistral/,/^  --aws/p' <<<"$output")
  [[ "$mistral" == *MISTRAL_API_KEY* ]]
  [[ "$mistral" == *"session can read"* ]]
}

@test "print_help: config.docker.toml is copied to config.toml, volumes named" {
  run print_help
  [[ "$output" == *"config.docker.toml exists it is copied to config.toml"* ]]
  [[ "$output" == *"vibe-root/vibe-home"* ]]
}

# --- validate_opts ---

@test "validate_opts: --gh with --gh-direct is rejected" {
  WITH_GH=1 WITH_GH_DIRECT=1
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"--gh and --gh-direct are mutually exclusive"* ]]
}

@test "validate_opts: --glab with --glab-direct is rejected" {
  WITH_GLAB=1 WITH_GLAB_DIRECT=1
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"--glab and --glab-direct are mutually exclusive"* ]]
}

@test "validate_opts: --mistral needs a non-empty MISTRAL_API_KEY" {
  WITH_MISTRAL=1
  run validate_opts
  [ "$status" -eq 1 ]
  [ "$output" = "vibe-docker: --mistral needs MISTRAL_API_KEY set (non-empty) in the host environment" ]
  MISTRAL_API_KEY=""
  run validate_opts
  [ "$status" -eq 1 ]
  MISTRAL_API_KEY=sk-mistral
  run validate_opts
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "validate_opts: MISTRAL_API_KEY is not required without --mistral" {
  run validate_opts
  [ "$status" -eq 0 ]
}

@test "validate_opts: missing VIBE_DOCKER_GLAB_POLICY is fatal under --glab only" {
  WITH_GLAB=1 VIBE_DOCKER_GLAB_POLICY="$BATS_TEST_TMPDIR/nope.caddy"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIBE_DOCKER_GLAB_POLICY '$BATS_TEST_TMPDIR/nope.caddy' is not a readable file"* ]]
  WITH_GLAB=0 WITH_GLAB_DIRECT=1
  run validate_opts
  [ "$status" -eq 0 ]
}

@test "validate_opts: missing VIBE_DOCKER_AZ_CA is fatal" {
  WITH_AZ=1 VIBE_DOCKER_AZ_CA="$BATS_TEST_TMPDIR/nope.pem"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIBE_DOCKER_AZ_CA '$BATS_TEST_TMPDIR/nope.pem' is not a file"* ]]
}

@test "validate_opts: missing VIBE_DOCKER_GH_POLICY is fatal under --gh" {
  WITH_GH=1 VIBE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/nope.caddy"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIBE_DOCKER_GH_POLICY '$BATS_TEST_TMPDIR/nope.caddy' is not a readable file"* ]]
}

@test "validate_opts: a directory as VIBE_DOCKER_GH_POLICY is fatal" {
  WITH_GH=1 VIBE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a readable file"* ]]
}

@test "validate_opts: an unreadable VIBE_DOCKER_GH_POLICY is fatal" {
  [ "$(id -u)" != 0 ] || skip "root can read any file"
  WITH_GH=1 VIBE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/p.caddy"
  : >"$VIBE_DOCKER_GH_POLICY"
  chmod 000 "$VIBE_DOCKER_GH_POLICY"
  run validate_opts
  [ "$status" -eq 1 ]
}

@test "validate_opts: VIBE_DOCKER_GH_POLICY is ignored without --gh" {
  VIBE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/nope.caddy"
  run validate_opts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate_opts: VIBE_DOCKER_ADD_HOSTS splits IPv4 and IPv6 entries" {
  VIBE_DOCKER_ADD_HOSTS="gitlab.example.com:10.1.2.3,v6.example.com:fd00::1"
  validate_opts
  [ "$(lines_of "${ADD_HOSTS[@]}")" = $'gitlab.example.com:10.1.2.3\nv6.example.com:fd00::1' ]
}

@test "validate_opts: a VIBE_DOCKER_ADD_HOSTS entry without an ip is fatal" {
  VIBE_DOCKER_ADD_HOSTS="ok.example.com:10.0.0.1,gitlab.example.com"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"entry 'gitlab.example.com' is not host:ip"* ]]
}

@test "validate_opts: a VIBE_DOCKER_ADD_HOSTS entry with a space is fatal" {
  VIBE_DOCKER_ADD_HOSTS="a.example.com:10.0.0.1, b.example.com:10.0.0.2"
  run validate_opts
  [ "$status" -eq 1 ]
}

# --- select_runtime ---

@test "select_runtime: VIBE_DOCKER_RUNTIME outside the allowlist is rejected" {
  VIBE_DOCKER_RUNTIME=evil
  run select_runtime
  [ "$status" -eq 1 ]
  [ "$output" = "vibe-docker: VIBE_DOCKER_RUNTIME must be 'docker' or 'podman', got 'evil'" ]
}

@test "select_runtime: podman is accepted" {
  VIBE_DOCKER_RUNTIME=podman
  select_runtime
  [ "$RUNTIME" = podman ]
}

@test "select_runtime: auto-detect prefers docker" {
  RUNTIME=""
  select_runtime
  [ "$RUNTIME" = docker ]
}

@test "select_runtime: no engine on PATH fails" {
  unset -f docker podman
  PATH="$BATS_TEST_TMPDIR/empty" run select_runtime
  [ "$status" -eq 1 ]
  [[ "$output" == *"no container runtime found"* ]]
}

@test "select_runtime: requested engine missing from PATH fails" {
  unset -f podman
  VIBE_DOCKER_RUNTIME=podman
  PATH="$BATS_TEST_TMPDIR/empty" run select_runtime
  [ "$status" -eq 1 ]
  [[ "$output" == *"requested runtime 'podman' not found on PATH"* ]]
}

# --- prune_stale_auth_proxy ---

@test "prune_stale_auth_proxy: removes stopped sidecars and stale networks" {
  STUB_PS="old1 old2"
  prune_stale_auth_proxy
  grep -qx "docker rm -f old1" "$CALLS"
  grep -qx "docker rm -f old2" "$CALLS"
  grep -qx "docker network rm net1" "$CALLS"
}

@test "prune_stale_auth_proxy: sweeps only vibe-auth names, stopped only" {
  prune_stale_auth_proxy
  grep -qx "docker ps -aq --filter name=^vibe-auth-proxy- --filter status=exited --filter status=created --filter status=dead" "$CALLS"
  grep -qx "docker network ls -q --filter name=^vibe-auth-" "$CALLS"
  [ "$(grep -c "^docker ps -aq" "$CALLS")" -eq 1 ]
  [ "$(grep -c "^docker network ls" "$CALLS")" -eq 1 ]
  run ! grep -q "status=running" "$CALLS"
}

@test "prune_stale_auth_proxy: failures never abort the run" {
  STUB_PS="old1" STUB_FAIL="rm ps network"
  run prune_stale_auth_proxy
  [ "$status" -eq 0 ]
}

# --- detect_msys / hostpath ---

@test "detect_msys: Git Bash disables argv path conversion" {
  uname() { echo MINGW64_NT-10.0; }
  detect_msys
  [ "$IS_MSYS" = 1 ]
  [ "$MSYS_NO_PATHCONV" = 1 ]
  [ "$MSYS2_ARG_CONV_EXCL" = '*' ]
}

@test "detect_msys: Linux leaves IS_MSYS off" {
  uname() { echo Linux; }
  detect_msys
  [ "$IS_MSYS" = 0 ]
}

@test "detect_msys: Git Bash uses UID 1000 and passes no git config" {
  uname() { echo MINGW64_NT-10.0; }
  detect_msys
  [ "$HOST_UID" = 1000 ] && [ "$HOST_GID" = 1000 ]
  [ "${#GIT_CFG[@]}" -eq 0 ]
}

@test "detect_msys: Linux keeps id -u and adds no git config" {
  uname() { echo Linux; }
  detect_msys
  [ "$HOST_UID" = "$(id -u)" ] && [ "$HOST_GID" = "$(id -g)" ]
  [ "${#GIT_CFG[@]}" -eq 0 ]
}

@test "hostpath: identity off MSYS" {
  run hostpath "/c/Users/me dir"
  [ "$output" = "/c/Users/me dir" ]
}

@test "hostpath: cygpath -m under MSYS" {
  IS_MSYS=1
  cygpath() { echo "cygpath $*"; }
  run hostpath /c/Users/me
  [ "$output" = "cygpath -m /c/Users/me" ]
}

# --- build_workspace_mounts ---

@test "build_workspace_mounts: mounts each workspace and sets CWD" {
  mkdir -p "$BATS_TEST_TMPDIR/other"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/other") RO_WORKSPACES=1
  build_workspace_mounts
  [ "$CWD" = /workspaces/repo ]
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = "$(printf -- '-v\n%s:/workspaces/repo:ro\n-v\n%s:/workspaces/other:ro' "$WS" "$BATS_TEST_TMPDIR/other")" ]
}

@test "build_workspace_mounts: --ro=PATH mounts only that workspace :ro" {
  mkdir -p "$BATS_TEST_TMPDIR/other"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/other") WORKSPACES_RO=(0 1)
  build_workspace_mounts
  [ "$CWD" = /workspaces/repo ]
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = "$(printf -- '-v\n%s:/workspaces/repo\n-v\n%s:/workspaces/other:ro' "$WS" "$BATS_TEST_TMPDIR/other")" ]
}

@test "build_workspace_mounts: warns when a read-only workspace is inside a writable one" {
  mkdir -p "$WS/vendor"
  WORKSPACES=("$WS" "$WS/vendor") WORKSPACES_RO=(0 1)
  run build_workspace_mounts
  [ "$status" -eq 0 ]
  [ "$output" = "vibe-docker: warning: read-only workspace '$WS/vendor' is inside writable workspace '$WS', so it stays writable under /workspaces/repo" ]
}

@test "build_workspace_mounts: the nesting warning sees through symlinks" {
  mkdir -p "$WS/vendor"
  ln -s "$WS/vendor" "$BATS_TEST_TMPDIR/vendor-link"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/vendor-link") WORKSPACES_RO=(0 1)
  run build_workspace_mounts
  [ "$status" -eq 0 ]
  [[ "$output" == *"read-only workspace '$BATS_TEST_TMPDIR/vendor-link' is inside writable workspace '$WS'"* ]]
}

@test "build_workspace_mounts: one directory through a symlink as both rw and ro is refused" {
  ln -s "$WS" "$BATS_TEST_TMPDIR/repo-link"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/repo-link") WORKSPACES_RO=(0 1)
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  # After the notice that the second workspace is a symlink.
  [ "${lines[-1]}" = "vibe-docker: workspaces '$WS' and '$BATS_TEST_TMPDIR/repo-link' are the same directory, one read-write and one read-only; pass it once" ]
}

@test "build_workspace_mounts: one directory through a symlink in the same mode is refused" {
  # Workspaces are mounted by their physical path, so both would be one mount.
  ln -s "$WS" "$BATS_TEST_TMPDIR/repo-link"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/repo-link")
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "vibe-docker: workspaces '$WS' and '$BATS_TEST_TMPDIR/repo-link' are the same directory; pass it once" ]
}

@test "build_workspace_mounts: the same path twice gets its own error" {
  WORKSPACES=("$WS" "$WS") WORKSPACES_RO=(0 1)
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [ "$output" = "vibe-docker: workspace '$WS' is given more than once; pass it once, as PATH (read-write) or --ro=PATH (read-only)" ]
}

@test "build_workspace_mounts: no nesting warning when the outer one is read-only too" {
  mkdir -p "$WS/vendor" "$BATS_TEST_TMPDIR/repo-b"
  WORKSPACES=("$WS/vendor" "$WS" "$BATS_TEST_TMPDIR/repo-b") WORKSPACES_RO=(1 1 0)
  run build_workspace_mounts
  [ "$status" -eq 0 ] && [ -z "$output" ]
  WORKSPACES=("$WS" "$WS/vendor") WORKSPACES_RO=(1 0)
  run build_workspace_mounts
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "build_workspace_mounts: a missing workspace gets a prefixed error" {
  WORKSPACES=("$BATS_TEST_TMPDIR/missing")
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [ "$output" = "vibe-docker: workspace '$BATS_TEST_TMPDIR/missing' is not a directory" ]
}

@test "build_workspace_mounts: / is rejected" {
  WORKSPACES=(/)
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace '/' is the filesystem root"* ]]
}

@test "build_workspace_mounts: a ':' in the basename is rejected" {
  mkdir -p "$BATS_TEST_TMPDIR/a:b"
  WORKSPACES=("$BATS_TEST_TMPDIR/a:b")
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"basename 'a:b' cannot contain ':'"* ]]
}

@test "build_workspace_mounts: basename collisions are rejected" {
  mkdir -p "$BATS_TEST_TMPDIR/x/repo"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/x/repo")
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace basename collision"* ]]
}

# --- build_git_trust ---

# Two workspaces, both repos; FOREIGN lists the host paths another user owns.
setup_git_trust() {
  mkdir -p "$WS/.git" "$BATS_TEST_TMPDIR/other/.git"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/other")
  build_workspace_mounts
  FOREIGN=""
  owned_by_me() { [[ " $FOREIGN " != *" $1 "* ]]; }
  IS_MSYS=0
}
# The VIBE_DOCKER_TRUSTED_WORKSPACES value build_git_trust passed.
trusted_value() {
  local a
  for a in "${ENV_ARGS[@]}"; do
    case "$a" in VIBE_DOCKER_TRUSTED_WORKSPACES=*) printf '%s\n' "${a#*=}" ;; esac
  done
}

@test "build_git_trust: workspaces you own, with .git you own, are trusted" {
  setup_git_trust
  build_git_trust
  [ "$(trusted_value)" = /workspaces/repo:/workspaces/other ]
}

@test "build_git_trust: a workspace another user owns is not trusted, and said so" {
  setup_git_trust
  FOREIGN="$BATS_TEST_TMPDIR/other"
  build_git_trust 2>"$BATS_TEST_TMPDIR/err"
  [ "$(trusted_value)" = /workspaces/repo ]
  grep -q "'$BATS_TEST_TMPDIR/other' or its git directory belongs to another user, so git in the container won't trust it" "$BATS_TEST_TMPDIR/err"
}

@test "build_git_trust: a workspace whose .git another user owns is not trusted" {
  setup_git_trust
  FOREIGN="$WS/.git"
  build_git_trust 2>/dev/null
  [ "$(trusted_value)" = /workspaces/other ]
}

@test "build_git_trust: a workspace without .git is trusted when you own it" {
  setup_git_trust
  rm -rf "$WS/.git"
  build_git_trust
  [ "$(trusted_value)" = /workspaces/repo:/workspaces/other ]
}

@test "build_git_trust: no workspace you own passes an empty list" {
  setup_git_trust
  FOREIGN="$WS $BATS_TEST_TMPDIR/other"
  build_git_trust 2>/dev/null
  [ "$(trusted_value)" = "" ] && [ "$(trusted_value | wc -l)" -eq 1 ]
}

@test "build_git_trust: on Windows every workspace is trusted, without a notice" {
  setup_git_trust
  FOREIGN="$WS $BATS_TEST_TMPDIR/other"
  IS_MSYS=1
  build_git_trust 2>"$BATS_TEST_TMPDIR/err"
  [ "$(trusted_value)" = /workspaces/repo:/workspaces/other ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "build_git_trust: a worktree whose gitdir another user owns is not trusted" {
  setup_git_trust
  rm -rf "$WS/.git"
  mkdir -p "$BATS_TEST_TMPDIR/main/.git/worktrees/repo"
  printf 'gitdir: %s\n' "$BATS_TEST_TMPDIR/main/.git/worktrees/repo" >"$WS/.git"
  FOREIGN="$BATS_TEST_TMPDIR/main/.git/worktrees/repo"
  build_git_trust 2>/dev/null
  [ "$(trusted_value)" = /workspaces/other ]
}

@test "build_git_trust: a worktree whose commondir another user owns is not trusted" {
  setup_git_trust
  rm -rf "$WS/.git"
  mkdir -p "$BATS_TEST_TMPDIR/main/.git/worktrees/repo"
  printf '../..\n' >"$BATS_TEST_TMPDIR/main/.git/worktrees/repo/commondir"
  printf 'gitdir: %s\n' "$BATS_TEST_TMPDIR/main/.git/worktrees/repo" >"$WS/.git"
  FOREIGN="$BATS_TEST_TMPDIR/main/.git/worktrees/repo/../.."
  build_git_trust 2>/dev/null
  [ "$(trusted_value)" = /workspaces/other ]
  FOREIGN=""
  ENV_ARGS=()
  build_git_trust
  [ "$(trusted_value)" = /workspaces/repo:/workspaces/other ]
}

@test "build_git_trust: a relative gitdir resolves against the workspace" {
  setup_git_trust
  rm -rf "$WS/.git"
  mkdir -p "$WS/../main/.git/worktrees/repo"
  printf 'gitdir: ../main/.git/worktrees/repo\n' >"$WS/.git"
  FOREIGN="$WS/../main/.git/worktrees/repo"
  build_git_trust 2>/dev/null
  [ "$(trusted_value)" = /workspaces/other ]
}

@test "build_git_trust: a .git file without a gitdir line is not trusted" {
  setup_git_trust
  rm -rf "$WS/.git"
  printf 'not a pointer\n' >"$WS/.git"
  build_git_trust 2>/dev/null
  [ "$(trusted_value)" = /workspaces/other ]
}

@test "build_git_trust: a .git symlink is not trusted" {
  setup_git_trust
  rm -rf "$WS/.git"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$WS/.git"
  build_git_trust 2>/dev/null
  [ "$(trusted_value)" = /workspaces/other ]
}

@test "build_git_trust: a foreign workspace inside a trusted one is named as trusted anyway" {
  mkdir -p "$WS/.git" "$WS/vendor/.git"
  WORKSPACES=("$WS" "$WS/vendor") WORKSPACES_RO=(0 1)
  build_workspace_mounts 2>/dev/null
  FOREIGN="$WS/vendor"
  owned_by_me() { [[ " $FOREIGN " != *" $1 "* ]]; }
  IS_MSYS=0
  build_git_trust 2>"$BATS_TEST_TMPDIR/err"
  [ "$(trusted_value)" = /workspaces/repo ]
  grep -q "'$WS/vendor' or its git directory belongs to another user, but it sits inside '$WS', so git in the container trusts it anyway; pass it on its own, or leave it out" "$BATS_TEST_TMPDIR/err"
}

@test "owned_by_me: a directory you created is yours" {
  owned_by_me "$WS"
}

# --- build_cred_mounts ---

@test "build_cred_mounts: --aws mounts config and sso read-only" {
  mkdir -p "$HOME/.aws/sso"
  : >"$HOME/.aws/config"
  WITH_AWS=1
  build_cred_mounts
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$HOME/.aws/config:/root/.aws/config:ro"* ]]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$HOME/.aws/sso:/root/.aws/sso:ro"* ]]
}

@test "build_cred_mounts: --registry honours a relocated npmrc" {
  npm_config_userconfig="$BATS_TEST_TMPDIR/npmrc"
  : >"$npm_config_userconfig"
  WITH_REGISTRY=1
  build_cred_mounts
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$BATS_TEST_TMPDIR/npmrc:/root/.npmrc:ro"* ]]
}

# --- build_env_args ---

@test "build_env_args: forwards set opt-in vars by name only" {
  WITH_AWS=1
  export AWS_PROFILE=dev AWS_REGION=""
  build_env_args
  [ "$(lines_of "${ENV_ARGS[@]}")" = "$(printf -- '-e\nTERM\n-e\nCOLORTERM\n-e\nAWS_PROFILE')" ]
}

@test "build_env_args: UV_INDEX scan forwards only non-empty _USERNAME/_PASSWORD" {
  WITH_REGISTRY=1
  export UV_INDEX_CORP_PASSWORD=secret UV_INDEX_CORP_USERNAME="" UV_CACHE_DIR=/host/cache UV_INDEX_CORP_URL=https://x
  build_env_args
  local got
  got=$(lines_of "${ENV_ARGS[@]}")
  [[ "$got" == *UV_INDEX_CORP_PASSWORD* ]]
  [[ "$got" != *UV_INDEX_CORP_USERNAME* ]]
  [[ "$got" != *UV_CACHE_DIR* ]]
  [[ "$got" != *UV_INDEX_CORP_URL* ]]
}

@test "build_env_args: the UV_INDEX scan is off without --registry" {
  export UV_INDEX_CORP_PASSWORD=secret
  build_env_args
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *UV_INDEX_CORP_PASSWORD* ]]
}

@test "build_env_args: --mistral forwards MISTRAL_API_KEY by name, never its value" {
  export MISTRAL_API_KEY=sk-mistral-secret
  WITH_MISTRAL=1
  build_env_args
  [ "$(lines_of "${ENV_ARGS[@]}")" = "$(printf -- '-e\nTERM\n-e\nCOLORTERM\n-e\nMISTRAL_API_KEY')" ]
  [[ "${ENV_ARGS[*]}" != *sk-mistral-secret* ]]
}

@test "build_env_args: MISTRAL_API_KEY is never forwarded without --mistral" {
  export MISTRAL_API_KEY=sk-mistral-secret
  WITH_AWS=1 WITH_GH_DIRECT=1 WITH_GLAB_DIRECT=1 WITH_TFE=1 WITH_AZ=1 WITH_REGISTRY=1
  build_env_args
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *MISTRAL* ]]
}

@test "build_env_args: --glab forwards GITLAB_HOST but never GITLAB_TOKEN" {
  export GITLAB_TOKEN=glpat GITLAB_HOST=gl.example.com
  WITH_GLAB=1
  build_env_args
  [ "$(lines_of "${ENV_ARGS[@]}")" = "$(printf -- '-e\nTERM\n-e\nCOLORTERM\n-e\nGITLAB_HOST')" ]
  ENV_ARGS=() WITH_GLAB=0 WITH_GLAB_DIRECT=1
  build_env_args
  [ "$(lines_of "${ENV_ARGS[@]}")" = "$(printf -- '-e\nGITLAB_TOKEN\n-e\nGITLAB_HOST')" ]
}

# --- discover_tokens ---

@test "glab_host_of: host[:port] from a URL or a bare host" {
  local in want
  while IFS='|' read -r in want; do
    [ "$(glab_host_of "$in")" = "$want" ] || { echo "glab_host_of '$in' = '$(glab_host_of "$in")', want '$want'"; return 1; }
  done <<'TABLE'
gitlab.example.com|gitlab.example.com
gitlab.example.com:8443|gitlab.example.com:8443
https://gitlab.example.com|gitlab.example.com
https://gitlab.example.com/|gitlab.example.com
https://gitlab.example.com:8443/group/p.git|gitlab.example.com:8443
https://user@gitlab.example.com/g/p|gitlab.example.com
https://user:p@ss@gitlab.example.com/g|gitlab.example.com
https://gitlab.example.com/g/a@b|gitlab.example.com
ssh://git@gitlab.example.com:2222/g/p.git|gitlab.example.com:2222
http://gitlab.internal/x|gitlab.internal
https://|
|
TABLE
}

@test "discover_tokens: --gh-direct forwards the gh CLI token by name" {
  WITH_GH_DIRECT=1
  discover_tokens
  [ "$GH_TOKEN" = gho_stub ]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *$'-e\nGH_TOKEN'* ]]
}

@test "discover_tokens: --gh keeps the token out of the agent env" {
  WITH_GH=1
  discover_tokens
  [ "$GH_HOST_TOKEN" = gho_stub ]
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GH_TOKEN* ]]
}

@test "discover_tokens: host GH_TOKEN wins over the gh CLI" {
  WITH_GH=1 GH_TOKEN=from_env
  discover_tokens
  [ "$GH_HOST_TOKEN" = from_env ]
  run ! grep -q "^gh " "$CALLS"
}

@test "discover_tokens: no gh flag means no gh call" {
  discover_tokens
  [ -z "$GH_HOST_TOKEN" ]
  run ! grep -q "^gh " "$CALLS"
}

@test "discover_tokens: --glab-direct asks glab for GITLAB_HOST's token and forwards it" {
  WITH_GLAB_DIRECT=1 GITLAB_HOST=https://gitlab.example.com/
  SEEN_PATHS=("$WS")
  discover_tokens
  [ "$GITLAB_TOKEN" = glpat_stub ]
  grep -q "glab config get token --host gitlab.example.com" "$CALLS"
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *$'-e\nGITLAB_TOKEN'* ]]
  [ -z "$GLAB_HOST_TOKEN" ]
}

@test "discover_tokens: --glab keeps the discovered token for the sidecar" {
  WITH_GLAB=1 GITLAB_HOST=https://gitlab.example.com:8443/
  SEEN_PATHS=("$WS")
  discover_tokens
  [ "$GLAB_HOST_TOKEN" = glpat_stub ]
  [ "$GLAB_PROXY_HOST" = gitlab.example.com:8443 ]
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GITLAB_TOKEN* ]]
}

@test "discover_tokens: --glab with an explicit token proxies glab's default host, not the origin" {
  command git init -q "$WS"
  command git -C "$WS" remote add origin git@github.com:org/repo.git
  git() { command git "$@"; }
  WITH_GLAB=1 GITLAB_TOKEN=glpat_explicit
  SEEN_PATHS=("$WS")
  discover_tokens
  [ "$GLAB_HOST_TOKEN" = glpat_explicit ]
  [ "$GLAB_PROXY_HOST" = gitlab.com ]
  [ "$GITLAB_HOST" = gitlab.com ]
  run ! grep -q "glab config get token" "$CALLS"
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *$'-e\nGITLAB_TOKEN'* ]]
}

@test "discover_tokens: --glab with an explicit token and no host glab proxies gitlab.com" {
  # An empty PATH, so there is no glab and the gitlab.com fallback is taken.
  # discover_tokens calls nothing else here; a copy of the host's bin dirs
  # would make the test depend on what the runner image ships.
  unset -f glab
  local saved_path=$PATH
  PATH="$BATS_TEST_TMPDIR/empty-bin"
  [ -z "$(command -v glab)" ]
  WITH_GLAB=1 GITLAB_TOKEN=glpat_explicit
  SEEN_PATHS=("$WS")
  discover_tokens
  PATH=$saved_path
  [ "$GLAB_HOST_TOKEN" = glpat_explicit ]
  [ "$GLAB_PROXY_HOST" = gitlab.com ]
  [ "$GITLAB_HOST" = gitlab.com ]
}

@test "discover_tokens: --glab-direct with an explicit token asks glab nothing" {
  WITH_GLAB_DIRECT=1 GITLAB_TOKEN=glpat_explicit
  SEEN_PATHS=("$WS")
  discover_tokens
  [ ! -s "$CALLS" ]
  [ -z "${GITLAB_HOST:-}" ]
}

@test "discover_tokens: --glab refuses hosts the proxy can't serve" {
  for h in http://gitlab.internal 10.0.0.5 10.0.0.5:8443 "[::1]:8443" fe80::1; do
    WITH_GLAB=1 GITLAB_HOST="$h"
    SEEN_PATHS=("$WS")
    run discover_tokens
    [ "$status" -eq 1 ]
    [[ "$output" == *"use --glab-direct"* ]]
  done
}

@test "discover_tokens: --glab refuses a plain-http origin" {
  command git init -q "$WS"
  command git -C "$WS" remote add origin http://gitlab.internal/g/p.git
  git() { command git "$@"; }
  glab() { echo "glab $*" >>"$CALLS"; [ "$3 $5" = "token gitlab.internal" ] && echo "glpat_stub"; return 0; }
  WITH_GLAB=1
  SEEN_PATHS=("$WS")
  run discover_tokens
  [ "$status" -eq 1 ]
  [[ "$output" == *"'http://gitlab.internal/g/p.git' is plain http"*"use --glab-direct"* ]]
}

@test "discover_tokens: --glab never ties a host-agnostic token to the origin" {
  # The default stub answers every host, as glab does for GITLAB_ACCESS_TOKEN,
  # OAUTH_TOKEN or a legacy top-level token.
  command git init -q "$WS"
  command git -C "$WS" remote add origin https://github.com/org/repo.git
  git() { command git "$@"; }
  WITH_GLAB=1
  SEEN_PATHS=("$WS")
  discover_tokens
  grep -q "glab config get token --host vibe-docker.invalid" "$CALLS"
  [ "$GLAB_HOST_TOKEN" = glpat_stub ]
  [ "$GLAB_PROXY_HOST" = gitlab.com ]
  [ "$GITLAB_HOST" = gitlab.com ]
}

@test "discover_tokens: --glab keeps a token stored for the origin host" {
  command git init -q "$WS"
  command git -C "$WS" remote add origin git@gitlab.example.com:g/p.git
  git() { command git "$@"; }
  glab() { echo "glab $*" >>"$CALLS"; [ "$3 $5" = "token gitlab.example.com" ] && echo "glpat_origin"; return 0; }
  WITH_GLAB=1
  SEEN_PATHS=("$WS")
  discover_tokens
  [ "$GLAB_HOST_TOKEN" = glpat_origin ]
  [ "$GLAB_PROXY_HOST" = gitlab.example.com ]
}

@test "discover_tokens: --glab refuses a host that isn't host[:port]" {
  for h in 'gitlab_example.com' 'gl.example.com:abc' 'gl.example.com{' 'gl example.com'; do
    WITH_GLAB=1 GITLAB_HOST="$h"
    SEEN_PATHS=("$WS")
    run discover_tokens
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a valid host[:port]"* ]]
  done
}

@test "discover_tokens: --glab with no token warns" {
  glab() { return 0; }
  WITH_GLAB=1 GITLAB_HOST=gitlab.example.com
  SEEN_PATHS=("$WS")
  run discover_tokens
  [ "$status" -eq 0 ]
  [[ "$output" == *"--glab: no GitLab token found for gitlab.example.com"* ]]
}

@test "discover_tokens: --glab-direct with no token names --glab-direct" {
  glab() { return 0; }
  WITH_GLAB_DIRECT=1 GITLAB_HOST=gitlab.example.com
  SEEN_PATHS=("$WS")
  run discover_tokens
  [ "$status" -eq 0 ]
  [[ "$output" == *"--glab-direct: no GitLab token found for gitlab.example.com"* ]]
}

# --- build_git_config ---

@test "build_git_config: proxied forges add no git config" {
  WITH_GH=1 WITH_GLAB=1 GITLAB_HOST=gitlab.example.com
  build_git_config
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GIT_CONFIG_* ]]
}

@test "build_git_config: one credential helper per forge host" {
  WITH_GH_DIRECT=1 WITH_GLAB_DIRECT=1 WITH_AZ=1
  GITLAB_HOST=https://gitlab.example.com:8443/ AZURE_DEVOPS_ORG_URL=https://ado.example.com/tfs/Coll
  # An entry already on the list keeps its place in front of the helpers.
  GIT_CFG=(credential.https://git.example.com.helper "!true")
  build_git_config
  env=$(lines_of "${ENV_ARGS[@]}")
  [[ "$env" == *$'GIT_CONFIG_KEY_0=credential.https://git.example.com.helper\n-e\nGIT_CONFIG_VALUE_0=!true'* ]]
  [[ "$env" == *$'GIT_CONFIG_KEY_1=credential.https://github.com.helper\n-e\nGIT_CONFIG_VALUE_1=!gh auth git-credential'* ]]
  [[ "$env" == *$'GIT_CONFIG_KEY_2=credential.https://gitlab.example.com:8443.helper\n-e\nGIT_CONFIG_VALUE_2=!glab auth git-credential'* ]]
  [[ "$env" == *"GIT_CONFIG_KEY_3=credential.https://ado.example.com.helper"* ]]
  [[ "$env" == *'password=$AZURE_DEVOPS_EXT_PAT'* ]]
  [[ "$env" == *"GIT_CONFIG_COUNT=4"* ]]
  [[ "$env" != *insteadOf* ]]
}

@test "build_git_config: Azure DevOps PAT is offered only to its own host" {
  unset -f git
  WITH_AZ=1
  build_git_config
  # ENV_ARGS is (-e K=V)...: export every K=V and ask git for credentials.
  for a in "${ENV_ARGS[@]}"; do [ "$a" = -e ] || export "$a"; done
  export AZURE_DEVOPS_EXT_PAT=s3cret GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=
  run git credential fill <<<$'protocol=https\nhost=dev.azure.com\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"password=s3cret"* ]]
  run git credential fill <<<$'protocol=https\nhost=evil.example.com\n'
  [ "$status" -ne 0 ]
  [[ "$output" != *s3cret* ]]
}

@test "build_git_config: a URL with no usable host gets no credential helper" {
  for url in 'https://' 'https:///' 'https://*.example.com' 'https:// evil'; do
    ENV_ARGS=() GIT_CFG=()
    WITH_AZ=1 WITH_GLAB_DIRECT=1 AZURE_DEVOPS_ORG_URL=$url GITLAB_HOST=$url
    run build_git_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"--az: AZURE_DEVOPS_ORG_URL has no usable host"* ]]
    [[ "$output" == *"--glab-direct: GITLAB_HOST has no usable host"* ]]
    build_git_config 2>/dev/null
    [[ "$(lines_of "${ENV_ARGS[@]}")" != *credential.* ]]
  done
}

@test "build_git_config: an empty-host Azure DevOps URL never offers the PAT" {
  unset -f git
  WITH_AZ=1 AZURE_DEVOPS_ORG_URL=https://
  build_git_config 2>/dev/null
  for a in "${ENV_ARGS[@]}"; do [ "$a" = -e ] || export "$a"; done
  export AZURE_DEVOPS_EXT_PAT=s3cret GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=
  run git credential fill <<<$'protocol=https\nhost=evil.example.com\n'
  [[ "$output" != *s3cret* ]]
}

# --- forward_git_identity / build_flags_env ---

@test "forward_git_identity: forwards name and email" {
  forward_git_identity
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"GIT_AUTHOR_NAME=Ada Lovelace"* ]]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"GIT_COMMITTER_EMAIL=ada@example.com"* ]]
}

@test "forward_git_identity: unset identity forwards nothing" {
  git() { return 1; }
  forward_git_identity
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GIT_* ]]
}

@test "build_flags_env: tags the opt-ins in opt-in table order" {
  WITH_AWS=1 WITH_GH=1 EPHEMERAL=1
  build_flags_env
  [ "${ENV_ARGS[*]: -1}" = "VIBE_DOCKER_FLAGS=aws,gh,ephemeral" ]
}

@test "build_flags_env: -direct modes get their own tags" {
  WITH_GH_DIRECT=1 WITH_GLAB_DIRECT=1
  build_flags_env
  [ "${ENV_ARGS[*]: -1}" = "VIBE_DOCKER_FLAGS=gh-direct,glab-direct" ]
}

@test "build_flags_env: mistral follows registry and precedes ephemeral" {
  WITH_TFE=1 WITH_AZ=1 WITH_REGISTRY=1 WITH_MISTRAL=1 EPHEMERAL=1
  build_flags_env
  [ "${ENV_ARGS[*]: -1}" = "VIBE_DOCKER_FLAGS=tfe,az,registry,mistral,ephemeral" ]
}

@test "build_flags_env: some --ro=PATH workspaces tag ro-partial" {
  WORKSPACES=(a b) WORKSPACES_RO=(0 1)
  build_flags_env
  [ "${ENV_ARGS[*]: -1}" = "VIBE_DOCKER_FLAGS=ro-partial" ]
}

@test "build_flags_env: all workspaces read-only tag ro" {
  WORKSPACES=(a b) WORKSPACES_RO=(1 1)
  build_flags_env
  [ "${ENV_ARGS[*]: -1}" = "VIBE_DOCKER_FLAGS=ro" ]
  WORKSPACES_RO=(0 1) RO_WORKSPACES=1
  build_flags_env
  [ "${ENV_ARGS[*]: -1}" = "VIBE_DOCKER_FLAGS=ro" ]
}

@test "build_flags_env: no opt-ins, no tag" {
  build_flags_env
  [[ "${ENV_ARGS[*]}" != *VIBE_DOCKER_FLAGS* ]]
}

# --- create_stage ---

@test "create_stage: stage dir under HOME, removed by the EXIT trap" {
  (
    create_stage
    echo "$stage" >"$BATS_TEST_TMPDIR/stage"
    [ -d "$stage" ]
    [ "$AUTH_PROXY_SIDECAR" = "vibe-auth-proxy-${stage##*.}" ]
    [ "$AUTH_PROXY_NETWORK" = "vibe-auth-${stage##*.}" ]
  )
  local s
  s=$(cat "$BATS_TEST_TMPDIR/stage")
  [[ "$s" == "$HOME/.cache/vibe-docker/host."* ]]
  [ ! -e "$s" ]
  grep -q "docker rm -f vibe-auth-proxy-" "$CALLS"
  grep -q "docker network rm vibe-auth-" "$CALLS"
}

@test "create_stage: an unwritable cache dir aborts" {
  : >"$HOME/.cache"
  run create_stage
  [ "$status" -eq 1 ]
}

# --- start_auth_sidecar ---

sidecar_setup() {
  WITH_GH=1 GH_HOST_TOKEN=gho_secret
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage"
  AUTH_PROXY_NETWORK=vibe-auth-x AUTH_PROXY_SIDECAR=vibe-auth-proxy-x
}

@test "start_auth_sidecar: no-op without a proxied credential" {
  WITH_GH=1 WITH_GLAB=1
  start_auth_sidecar
  [ "$GH_SIDECAR_ACTIVE" = 0 ] && [ "$GLAB_SIDECAR_ACTIVE" = 0 ]
  [ ! -s "$CALLS" ]
}

@test "start_auth_sidecar: wires the agent to the gh sidecar" {
  sidecar_setup
  VIBE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/policy.caddy"
  echo "# user policy" >"$VIBE_DOCKER_GH_POLICY"
  start_auth_sidecar 2>/dev/null
  [ "$GH_SIDECAR_ACTIVE" = 1 ]
  [ "$(cat "$stage/auth-proxy/caddy/policy.caddy")" = "# user policy" ]
  [ -f "$stage/auth-proxy/caddy/sites/gh.caddy" ]
  [ "$(ls "$stage/auth-proxy/caddy/sites")" = gh.caddy ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *$'--add-host\napi.github.com:10.0.0.2'* ]]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"auth-proxy/root.crt:/usr/local/share/ca-certificates/vibe-docker-auth-proxy.crt:ro"* ]]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"GH_TOKEN=vibe-docker-proxy"* ]]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"UV_SYSTEM_CERTS=1"* ]]
  grep -q "^docker run -d --name vibe-auth-proxy-x --network vibe-auth-x .* -v $stage/auth-proxy/caddy:/etc/caddy:ro" "$CALLS"
  # The real token is passed by name, never on argv.
  run ! grep -q gho_secret "$CALLS"
  run ! grep -rq gho_secret "$stage"
}

@test "start_auth_sidecar: passes VIBE_DOCKER_ADD_HOSTS to the sidecar" {
  sidecar_setup
  ADD_HOSTS=(github.com:140.82.121.4)
  start_auth_sidecar 2>/dev/null
  grep -q "^docker run -d .*--add-host github.com:140.82.121.4" "$CALLS"
}

@test "start_auth_sidecar: no policy stages an empty one" {
  sidecar_setup
  start_auth_sidecar 2>/dev/null
  [ -f "$stage/auth-proxy/caddy/policy.caddy" ] && [ ! -s "$stage/auth-proxy/caddy/policy.caddy" ]
}

@test "start_auth_sidecar: --glab redirects only the token's host" {
  WITH_GLAB=1 GLAB_HOST_TOKEN=glpat_secret GLAB_PROXY_HOST=gl.example.com:8443
  VIBE_DOCKER_GLAB_POLICY="$BATS_TEST_TMPDIR/glab-policy.caddy"
  echo "# user glab policy" >"$VIBE_DOCKER_GLAB_POLICY"
  stage="$BATS_TEST_TMPDIR/stage"; mkdir -p "$stage"
  AUTH_PROXY_NETWORK=vibe-auth-x AUTH_PROXY_SIDECAR=vibe-auth-proxy-x
  start_auth_sidecar 2>/dev/null
  [ "$GLAB_SIDECAR_ACTIVE" = 1 ] && [ "$GH_SIDECAR_ACTIVE" = 0 ]
  [ -f "$stage/auth-proxy/caddy/sites/glab.caddy" ]
  [ "$(cat "$stage/auth-proxy/caddy/glab-policy.caddy")" = "# user glab policy" ]
  [ "$GLAB_PROXY_SITE" = gl.example.com:8443 ]
  [ "$GLAB_PROXY_UPSTREAM" = https://gl.example.com:8443 ]
  [ "$GLAB_PROXY_BASIC" = "Basic $(printf 'oauth2:glpat_secret' | base64)" ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *$'--add-host\ngl.example.com:10.0.0.2'* ]]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" != *github.com* ]]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"GITLAB_TOKEN=vibe-docker-proxy"* ]]
  grep -q -- "-e GLAB_PROXY_BEARER -e GLAB_PROXY_BASIC" "$CALLS"
  run ! grep -q glpat_secret "$CALLS"
  run ! grep -rq glpat_secret "$stage"
}

@test "start_auth_sidecar: one sidecar serves gh and glab" {
  sidecar_setup
  WITH_GLAB=1 GLAB_HOST_TOKEN=glpat GLAB_PROXY_HOST=gl.example.com
  run start_auth_sidecar
  [ "$status" -eq 0 ]
  [[ "$output" == *"auth-proxy sidecar 'vibe-auth-proxy-x' is active for gh, glab"* ]]
  [ "$(grep -c "^docker run -d" "$CALLS")" -eq 1 ]
  [ "$(grep -c "^docker network create" "$CALLS")" -eq 1 ]
}

@test "start_auth_sidecar: network create failure aborts" {
  sidecar_setup
  STUB_FAIL="network"
  run start_auth_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to create network 'vibe-auth-x'"* ]]
  run ! grep -q "^docker run" "$CALLS"
}

@test "start_auth_sidecar: sidecar start failure aborts and names the -direct flags" {
  sidecar_setup
  WITH_GLAB=1 GLAB_HOST_TOKEN=glpat GLAB_PROXY_HOST=gl.example.com
  STUB_FAIL="run"
  run start_auth_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to start the auth-proxy sidecar"* ]]
  [[ "$output" == *"--gh-direct / --glab-direct"* ]]
  run ! grep -q "^docker cp" "$CALLS"
}

@test "start_auth_sidecar: an exited sidecar reports Caddy's logs" {
  sidecar_setup
  STUB_LOGS="caddy: bad policy" STUB_ALIVE=""
  run start_auth_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"sidecar exited during startup"* ]]
  [[ "$output" == *"  | caddy: bad policy"* ]]
  run ! grep -q "^docker inspect" "$CALLS"
}

@test "start_auth_sidecar: no CA within the budget aborts" {
  sidecar_setup
  STUB_FAIL="cp"
  run start_auth_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not produce a CA certificate within 15s"* ]]
  [ "$(grep -c "^docker cp" "$CALLS")" -eq 15 ]
}

@test "start_auth_sidecar: a config that never loads aborts, without trying the CA" {
  sidecar_setup
  STUB_LOGS="still starting"
  run start_auth_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not load its config within 15s"* ]]
  run ! grep -q "^docker cp" "$CALLS"
}

@test "start_auth_sidecar: a failing inspect reaches the address error" {
  STUB_FAIL="inspect"
  # Under set -e, which `run` would ignore: without `|| true` on the inspect
  # the shell aborts before this message prints.
  run_script_fn 'WITH_GH=1 GH_HOST_TOKEN=t stage=$HOME/st; mkdir -p "$stage"; start_auth_sidecar'
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not determine the auth-proxy sidecar's network address"* ]]
  [[ "$output" != *"is active"* ]]
}

# --- build_host_args ---

@test "build_host_args: adds each entry to the agent container" {
  ADD_HOSTS=(gitlab.example.com:10.1.2.3 github.com:140.82.121.4)
  build_host_args
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = $'--add-host\ngitlab.example.com:10.1.2.3\n--add-host\ngithub.com:140.82.121.4' ]
}

@test "build_host_args: under --gh the sidecar's hosts are skipped with a warning" {
  ADD_HOSTS=(GitHub.com:140.82.121.4 gitlab.example.com:10.1.2.3)
  GH_SIDECAR_ACTIVE=1
  run build_host_args
  [[ "$output" == *"entry 'GitHub.com:140.82.121.4' skipped"* ]]
  build_host_args 2>/dev/null
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = $'--add-host\ngitlab.example.com:10.1.2.3' ]
}

@test "build_host_args: under --glab the proxied GitLab host is skipped" {
  ADD_HOSTS=(GL.example.com:10.1.2.3 registry.gl.example.com:10.1.2.4)
  GLAB_SIDECAR_ACTIVE=1 GLAB_PROXY_HOST=gl.example.com:8443
  build_host_args 2>/dev/null
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = $'--add-host\nregistry.gl.example.com:10.1.2.4' ]
}

@test "build_host_args: nothing set adds nothing" {
  build_host_args
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

@test "start_auth_sidecar: the agent joins the auth network, no other network is attached" {
  sidecar_setup
  start_auth_sidecar 2>/dev/null
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *$'--network\nvibe-auth-x'* ]]
  run ! grep -q "^docker network connect" "$CALLS"
}

# --- stage_host_config ---

@test "stage_host_config: follows one symlink to the real dir" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage" "$BATS_TEST_TMPDIR/real/skills"
  echo hi >"$BATS_TEST_TMPDIR/real/skills/s.md"
  ln -s ../real/skills "$VIBE_CONFIG_DIR/skills"
  stage_host_config
  [ "$(cat "$stage/skills/s.md")" = hi ]
  [ ! -L "$stage/skills" ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$stage/skills:/root/.vibe/skills:ro"* ]]
}

@test "stage_host_config: a symlink chain is refused with a warning" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage" "$BATS_TEST_TMPDIR/real/skills"
  echo hi >"$BATS_TEST_TMPDIR/real/skills/s.md"
  ln -s real/skills "$BATS_TEST_TMPDIR/hop"
  ln -s ../hop "$VIBE_CONFIG_DIR/skills"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipping $VIBE_CONFIG_DIR/skills"* ]]
  [ ! -e "$stage/skills" ]
}

# A skill linked from a repo the user also opens as a workspace: the session
# can plant links in that repo, so only links that stay inside it survive.
setup_linked_skill() {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  SECRET="$BATS_TEST_TMPDIR/secret"
  REPO="$BATS_TEST_TMPDIR/repo-skills/foo"
  mkdir -p "$VIBE_CONFIG_DIR/skills" "$stage" "$REPO/lib" "$SECRET"
  echo key >"$SECRET/id_ed25519"
  echo body >"$REPO/SKILL.md"
  printf '#!/bin/sh\n' >"$REPO/lib/run.sh"
  chmod +x "$REPO/lib/run.sh"
  ln -s "$REPO" "$VIBE_CONFIG_DIR/skills/foo"
}

@test "stage_host_config: a linked skill is copied, internal links kept" {
  setup_linked_skill
  ln -s lib/run.sh "$REPO/entry"
  ln -s ../SKILL.md "$REPO/lib/up"
  stage_host_config
  [ "$(cat "$stage/skills/foo/SKILL.md")" = body ]
  [ -x "$stage/skills/foo/lib/run.sh" ]
  [ "$(readlink "$stage/skills/foo/entry")" = lib/run.sh ]
  [ "$(cat "$stage/skills/foo/lib/up")" = body ]
}

@test "stage_host_config: a linked skill's .git is not copied" {
  setup_linked_skill
  mkdir -p "$REPO/.git/objects"
  echo obj >"$REPO/.git/objects/x"
  echo hidden >"$REPO/.hidden"
  stage_host_config
  [ ! -e "$stage/skills/foo/.git" ]
  [ "$(cat "$stage/skills/foo/.hidden")" = hidden ]
}

@test "stage_host_config: links planted inside a linked skill are not followed" {
  setup_linked_skill
  ln -s "$SECRET/id_ed25519" "$REPO/abs"
  ln -s ../../secret/id_ed25519 "$REPO/rel"
  ln -s ../.. "$REPO/lib/root"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  ! grep -rq key "$stage"
  [ ! -e "$stage/skills/foo/abs" ] && [ ! -e "$stage/skills/foo/rel" ] && [ ! -e "$stage/skills/foo/lib/root" ]
  [[ "$stderr" == *"$REPO/abs"* ]]
  [ "$(cat "$stage/skills/foo/SKILL.md")" = body ]
}

@test "stage_host_config: an item that is a link gives its entries no hop" {
  # skills -> a dotfiles repo the user also opens as a workspace: a link the
  # session plants in there must not reach a host directory.
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  SECRET="$BATS_TEST_TMPDIR/secret"
  DOT="$BATS_TEST_TMPDIR/dotfiles/skills"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage" "$SECRET" "$DOT/foo"
  echo key >"$SECRET/id_ed25519"
  echo body >"$DOT/foo/SKILL.md"
  ln -s "$DOT" "$VIBE_CONFIG_DIR/skills"
  ln -s "$SECRET" "$DOT/x"
  ln -s foo "$DOT/alias"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  ! grep -rq key "$stage"
  [ ! -e "$stage/skills/x" ]
  [[ "$stderr" == *"skipping $DOT/x"* ]]
  [ "$(cat "$stage/skills/foo/SKILL.md")" = body ]
  [ "$(readlink "$stage/skills/alias")" = foo ]
}

@test "stage_host_config: a kept link whose target starts with - is recreated" {
  setup_linked_skill
  echo notes >"$REPO/-notes.md"
  ln -s -- -notes.md "$REPO/dash"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  [ "$(readlink "$stage/skills/foo/dash")" = -notes.md ]
  [ "$(cat "$stage/skills/foo/SKILL.md")" = body ]
}

@test "stage_host_config: a trailing-slash link to a skill swapped for a link is refused" {
  setup_linked_skill
  rm "$VIBE_CONFIG_DIR/skills/foo"
  ln -s "$REPO/" "$VIBE_CONFIG_DIR/skills/foo"
  rm -rf "$REPO"
  ln -s "$SECRET" "$REPO"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  ! grep -rq key "$stage"
  [[ "$stderr" == *"skipping"*"skills/foo"* ]]
}

@test "stage_host_config: identity checks that never match skip items, not the launch" {
  # Stands in for a platform whose stat reports inodes differently (Git Bash).
  setup_linked_skill
  echo rules >"$VIBE_CONFIG_DIR/AGENTS.md"
  file_id() { echo 0:0; }
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipping"* ]]
  [ ! -e "$stage/skills" ] && [ ! -e "$stage/AGENTS.md" ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" != *"/root/.vibe/skills"* ]]
}

@test "one_hop: strips trailing slashes, refuses . and .. targets" {
  mkdir -p "$BATS_TEST_TMPDIR/t"
  ln -s "$BATS_TEST_TMPDIR/t//" "$BATS_TEST_TMPDIR/slash"
  [ "$(one_hop "$BATS_TEST_TMPDIR/slash")" = "$BATS_TEST_TMPDIR/t" ]
  ln -s "$BATS_TEST_TMPDIR/t/." "$BATS_TEST_TMPDIR/dot"
  ln -s "$BATS_TEST_TMPDIR/t/.." "$BATS_TEST_TMPDIR/dotdot"
  ! one_hop "$BATS_TEST_TMPDIR/dot"
  ! one_hop "$BATS_TEST_TMPDIR/dotdot"
}

@test "stage_host_config: a linked skill swapped for a link is refused" {
  setup_linked_skill
  rm -rf "$REPO"
  ln -s "$SECRET" "$REPO"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  ! grep -rq key "$stage"
  [[ "$stderr" == *"skipping"*"skills/foo"* ]]
}

@test "stage_host_config: AGENTS.md and config.docker.toml are staged copies, one hop" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage" "$BATS_TEST_TMPDIR/dotfiles"
  echo rules >"$BATS_TEST_TMPDIR/dotfiles/AGENTS.md"
  ln -s ../dotfiles/AGENTS.md "$VIBE_CONFIG_DIR/AGENTS.md"
  echo 'theme = "mistral-dark"' >"$VIBE_CONFIG_DIR/config.docker.toml"
  stage_host_config
  [ "$(cat "$stage/AGENTS.md")" = rules ]
  [ ! -L "$stage/AGENTS.md" ]
  [ "$(cat "$stage/config.docker.toml")" = 'theme = "mistral-dark"' ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$stage/AGENTS.md:/root/.vibe/AGENTS.md:ro"* ]]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$stage/config.docker.toml:/run/vibe-docker/config.toml:ro"* ]]
}

@test "stage_host_config: agents, skills and prompts mount under /root/.vibe" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR/agents" "$VIBE_CONFIG_DIR/skills/review" "$VIBE_CONFIG_DIR/prompts" "$stage"
  echo a >"$VIBE_CONFIG_DIR/agents/plan.toml"
  echo s >"$VIBE_CONFIG_DIR/skills/review/SKILL.md"
  echo p >"$VIBE_CONFIG_DIR/prompts/cli.md"
  stage_host_config
  [ "$(cat "$stage/agents/plan.toml")" = a ]
  [ "$(cat "$stage/skills/review/SKILL.md")" = s ]
  [ "$(cat "$stage/prompts/cli.md")" = p ]
  local got
  got=$(lines_of "${MOUNT_ARGS[@]}")
  [[ "$got" == *"$stage/agents:/root/.vibe/agents:ro"* ]]
  [[ "$got" == *"$stage/skills:/root/.vibe/skills:ro"* ]]
  [[ "$got" == *"$stage/prompts:/root/.vibe/prompts:ro"* ]]
}

@test "stage_host_config: host config.toml, hooks.toml and other items are never forwarded" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR/commands" "$VIBE_CONFIG_DIR/themes" "$VIBE_CONFIG_DIR/logs" "$stage"
  echo 'active_model = "host"' >"$VIBE_CONFIG_DIR/config.toml"
  echo '[[hooks]]' >"$VIBE_CONFIG_DIR/hooks.toml"
  echo 'MISTRAL_API_KEY=k' >"$VIBE_CONFIG_DIR/.env"
  echo x >"$VIBE_CONFIG_DIR/commands/c.md"
  echo x >"$VIBE_CONFIG_DIR/themes/t.json"
  stage_host_config
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
  [ -z "$(ls -A "$stage")" ]
}

@test "stage_host_config: nothing in the config dir mounts nothing" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage"
  stage_host_config
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

@test "stage_host_config: AGENTS.md through a second link is refused" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage" "$BATS_TEST_TMPDIR/dotfiles"
  echo key >"$BATS_TEST_TMPDIR/secret"
  ln -s ../secret "$BATS_TEST_TMPDIR/dotfiles/AGENTS.md"
  ln -s ../dotfiles/AGENTS.md "$VIBE_CONFIG_DIR/AGENTS.md"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  [ ! -e "$stage/AGENTS.md" ]
  [[ "$stderr" == *"skipping $VIBE_CONFIG_DIR/AGENTS.md"* ]]
}

@test "stage_host_config: config.docker.toml through a second link is refused" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage" "$BATS_TEST_TMPDIR/dotfiles"
  echo key >"$BATS_TEST_TMPDIR/secret"
  ln -s ../secret "$BATS_TEST_TMPDIR/dotfiles/config.docker.toml"
  ln -s ../dotfiles/config.docker.toml "$VIBE_CONFIG_DIR/config.docker.toml"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  [ ! -e "$stage/config.docker.toml" ]
  [[ "$stderr" == *"skipping $VIBE_CONFIG_DIR/config.docker.toml"* ]]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" != *"/run/vibe-docker/config.toml"* ]]
}

# ~/.agents/skills: read from $HOME, not the config dir.
setup_agents_skills() {
  stage="$BATS_TEST_TMPDIR/stage"
  SECRET="$BATS_TEST_TMPDIR/secret"
  mkdir -p "$HOME/.agents/skills/review" "$stage" "$SECRET"
  echo key >"$SECRET/id_ed25519"
  echo body >"$HOME/.agents/skills/review/SKILL.md"
}

@test "stage_host_config: ~/.agents/skills mounts at /root/.agents/skills for the default config dir" {
  setup_agents_skills
  VIBE_CONFIG_DIR="$HOME/.vibe"
  [ ! -e "$VIBE_CONFIG_DIR" ]
  stage_host_config
  [ "$(cat "$stage/agents-skills/review/SKILL.md")" = body ]
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = "$(printf -- '-v\n%s:/root/.agents/skills:ro' "$stage/agents-skills")" ]
}

@test "stage_host_config: ~/.agents/skills comes from HOME for an alternate config dir that exists" {
  setup_agents_skills
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/work"
  mkdir -p "$VIBE_CONFIG_DIR/.agents/skills/other"
  stage_host_config
  [ "$(cat "$stage/agents-skills/review/SKILL.md")" = body ]
  [ ! -e "$stage/agents-skills/other" ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$stage/agents-skills:/root/.agents/skills:ro"* ]]
}

@test "stage_host_config: ~/.agents/skills is not forwarded for a --vibe-dir that doesn't exist" {
  setup_agents_skills
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/missing"
  stage_host_config
  [ ! -e "$stage/agents-skills" ]
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

@test "stage_host_config: a linked ~/.agents/skills entry is copied, links planted in it are not followed" {
  setup_agents_skills
  REPO="$BATS_TEST_TMPDIR/repo-skills/foo"
  mkdir -p "$REPO"
  echo body >"$REPO/SKILL.md"
  ln -s ../SKILL.md "$REPO/up" 2>/dev/null || true
  ln -s "$SECRET/id_ed25519" "$REPO/abs"
  ln -s "$REPO" "$HOME/.agents/skills/foo"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  [ "$(cat "$stage/agents-skills/foo/SKILL.md")" = body ]
  ! grep -rq key "$stage"
  [[ "$stderr" == *"skipping $REPO/abs"* ]]
}

@test "stage_host_config: a ~/.agents/skills that is a link gives its entries no hop" {
  setup_agents_skills
  DOT="$BATS_TEST_TMPDIR/dotfiles/skills"
  mkdir -p "$DOT/foo"
  echo body >"$DOT/foo/SKILL.md"
  rm -rf "$HOME/.agents/skills"
  ln -s "$DOT" "$HOME/.agents/skills"
  ln -s "$SECRET" "$DOT/x"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  ! grep -rq key "$stage"
  [ ! -e "$stage/agents-skills/x" ]
  [[ "$stderr" == *"skipping $DOT/x"* ]]
  [ "$(cat "$stage/agents-skills/foo/SKILL.md")" = body ]
}

@test "stage_host_config: a ~/.agents/skills symlink chain is refused with a warning" {
  setup_agents_skills
  rm -rf "$HOME/.agents/skills"
  mkdir -p "$BATS_TEST_TMPDIR/real/skills"
  ln -s real/skills "$BATS_TEST_TMPDIR/hop"
  ln -s "$BATS_TEST_TMPDIR/hop" "$HOME/.agents/skills"
  run --separate-stderr stage_host_config
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipping $HOME/.agents/skills"* ]]
  [ ! -e "$stage/agents-skills" ]
}

@test "stage_host_config: a symlink cycle is skipped, not looped on" {
  VIBE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$VIBE_CONFIG_DIR" "$stage"
  ln -s agents2 "$VIBE_CONFIG_DIR/agents"
  ln -s agents "$VIBE_CONFIG_DIR/agents2"
  run stage_host_config
  [ "$status" -eq 0 ]
  [ ! -e "$stage/agents" ]
}

# --- stage_git_overlays ---

@test "stage_git_overlays: overlays a real .git/config" {
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$WS/.git"
  echo "[core]" >"$WS/.git/config"
  SEEN_NAMES=(repo) SEEN_PATHS=("$WS")
  stage_git_overlays
  grep -q "relativeWorktrees = true" "$stage/git-config-repo"
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$stage/git-config-repo:/workspaces/repo/.git/config"* ]]
}

@test "stage_git_overlays: a symlinked .git/config is skipped" {
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$WS/.git"
  ln -s /etc/hostname "$WS/.git/config"
  SEEN_NAMES=(repo) SEEN_PATHS=("$WS")
  stage_git_overlays
  [ ! -e "$stage/git-config-repo" ]
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

@test "stage_git_overlays: a refused .git/config warns; no repo stays quiet" {
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$WS/.git" "$BATS_TEST_TMPDIR/norepo"
  ln -s /etc/hostname "$WS/.git/config"
  SEEN_NAMES=(repo norepo) SEEN_PATHS=("$WS" "$BATS_TEST_TMPDIR/norepo")
  run --separate-stderr stage_git_overlays
  [ "$status" -eq 0 ]
  [ "$stderr" = "vibe-docker: no .git/config overlay for $WS: it is a symlink, or changed while being read; git in the container uses the host file" ]
}

@test "stage_git_overlays: a stage write error stops the launch, without the symlink warning" {
  [ "$(id -u)" != 0 ] || skip "root can write a read-only directory"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$WS/.git"
  echo "[core]" >"$WS/.git/config"
  chmod 500 "$stage"
  SEEN_NAMES=(repo) SEEN_PATHS=("$WS")
  run --separate-stderr stage_git_overlays
  chmod 700 "$stage"
  [ "$status" -eq 1 ]
  [[ "$stderr" != *"no .git/config overlay"* ]]
}

@test "stage_git_overlays: a .git dir that is a link to a dir is skipped" {
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$BATS_TEST_TMPDIR/elsewhere"
  echo key >"$BATS_TEST_TMPDIR/elsewhere/config"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$WS/.git"
  SEEN_NAMES=(repo) SEEN_PATHS=("$WS")
  stage_git_overlays
  [ ! -e "$stage/git-config-repo" ]
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

@test "stage_git_overlays: only a valid host core.autocrlf is carried" {
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$WS/.git"
  echo "[core]" >"$WS/.git/config"
  SEEN_NAMES=(repo) SEEN_PATHS=("$WS") IS_MSYS=1
  git() { printf 'true\n[alias]\n\tx = !id\n'; }
  stage_git_overlays
  ! grep -q autocrlf "$stage/git-config-repo"
  ! grep -q alias "$stage/git-config-repo"
}

# --- cat_nofollow / link_stays_inside ---

@test "cat_nofollow: reads a regular file below the root" {
  mkdir -p "$WS/.git"
  echo cfg >"$WS/.git/config"
  run cat_nofollow "$WS" .git/config
  [ "$status" -eq 0 ] && [ "$output" = cfg ]
}

@test "cat_nofollow: an exported CDPATH adds nothing to a relative dir's file" {
  # A relative --vibe-dir reaches cat_nofollow as a relative directory; with
  # CDPATH set, cd would print it into the staged file. run.sh unsets it.
  mkdir -p "$BATS_TEST_TMPDIR/myvibe"
  echo body >"$BATS_TEST_TMPDIR/myvibe/AGENTS.md"
  export CDPATH=.
  run_script_fn "init_shell; cd '$BATS_TEST_TMPDIR' && cat_nofollow myvibe AGENTS.md"
  unset CDPATH
  [ "$status" -eq 0 ] && [ "$output" = body ]
}

@test "main: init_shell runs first, before anything reads a host file" {
  [ "$(declare -f main | sed -n '4p' | tr -d ' ;')" = init_shell ]
}

@test "cat_nofollow: refuses a link at the file or at a directory" {
  mkdir -p "$BATS_TEST_TMPDIR/sec"
  echo key >"$BATS_TEST_TMPDIR/sec/config"
  mkdir -p "$WS/a"
  ln -s "$BATS_TEST_TMPDIR/sec/config" "$WS/a/config"
  run cat_nofollow "$WS" a/config
  [ "$status" -ne 0 ] && [ -z "$output" ]
  ln -s "$BATS_TEST_TMPDIR/sec" "$WS/b"
  run cat_nofollow "$WS" b/config
  [ "$status" -ne 0 ] && [ -z "$output" ]
}

# The #211 race: a writer keeps swapping $2 between the real thing and a link
# to the secret's counterpart. The real one is restored by hard link, so its
# inode holds and reads in between legitimately succeed; none may return the
# secret. Against the old [ ! -L ] then cp, this leaked in ~half the reads.
race_reads() {
  local sec="$BATS_TEST_TMPDIR/sec" target=$1
  (
    cd "$WS" || exit 1
    while :; do
      ln -s "$sec/config" "$target.l" && mv -f "$target.l" "$target"
      ln -f "$target.keep" "$target.r" && mv -f "$target.r" "$target"
    done
  ) 3>&- &
  SWAPPER=$!
  read_while_swapping "$target"
}

# Read .git/config through cat_nofollow while $SWAPPER runs, then stop it.
# None of the reads may return the secret, and at least one must succeed, or
# the race was never exercised. At least 600 attempts and 5 successful
# reads, up to 6000 attempts: reads succeed only between swaps (~2% of
# attempts for the .git swap on an idle machine), and on a busy one the
# swapper won all of a fixed 600 (CI saw reads=0).
read_while_swapping() {
  local label=$1 leaks=0 reads=0 tries=0 out
  while { [ "$tries" -lt 600 ] || [ "$reads" -lt 5 ]; } && [ "$tries" -lt 6000 ]; do
    tries=$((tries + 1))
    if out=$(cat_nofollow "$WS" .git/config); then
      reads=$((reads + 1))
      [ "$out" = cfg ] || leaks=$((leaks + 1))
    fi
  done
  kill "$SWAPPER"; wait "$SWAPPER" 2>/dev/null || true
  echo "# $label: reads=$reads/$tries leaks=$leaks" >&3
  [ "$leaks" -eq 0 ] && [ "$reads" -gt 0 ]
}

@test "cat_nofollow: never returns a .git/config swapped for a link mid-read" {
  mkdir -p "$BATS_TEST_TMPDIR/sec" "$WS/.git"
  echo key >"$BATS_TEST_TMPDIR/sec/config"
  echo cfg >"$WS/.git/config"
  ln "$WS/.git/config" "$WS/.git/config.keep"
  race_reads .git/config
}

@test "cat_nofollow: never reads through a .git swapped for a link mid-read" {
  sec="$BATS_TEST_TMPDIR/sec"
  mkdir -p "$sec" "$WS/.git"
  echo key >"$sec/config"
  echo cfg >"$WS/.git/config"
  # A directory can't be hard-linked: rename it aside and back (same inode).
  (
    cd "$WS" || exit 1
    while :; do
      mv .git .git.keep && ln -s "$sec" .git
      rm .git && mv .git.keep .git
    done
  ) 3>&- &
  SWAPPER=$!
  read_while_swapping .git
}

@test "link_stays_inside: relative links that stay in the copy root" {
  link_stays_inside lib/run.sh 0
  link_stays_inside ../SKILL.md 1
  ! link_stays_inside ../x 0
  ! link_stays_inside ../../x 1
  ! link_stays_inside /etc/passwd 3
  ! link_stays_inside a/../../x 2
  ! link_stays_inside ./x 0
  ! link_stays_inside .. 0
}

# --- build_workspace_mounts: symlinked workspace ---

@test "build_workspace_mounts: a symlinked workspace given with trailing slashes is announced" {
  mkdir -p "$BATS_TEST_TMPDIR/real-target"
  ln -s "$BATS_TEST_TMPDIR/real-target" "$BATS_TEST_TMPDIR/link-ws"
  WORKSPACES=("$BATS_TEST_TMPDIR/link-ws//")
  run --separate-stderr build_workspace_mounts
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"is a symlink; mounting '$BATS_TEST_TMPDIR/real-target'"* ]]
}

@test "build_workspace_mounts: a symlinked workspace mounts its target, announced" {
  mkdir -p "$BATS_TEST_TMPDIR/real-target"
  ln -s "$BATS_TEST_TMPDIR/real-target" "$BATS_TEST_TMPDIR/link-ws"
  WORKSPACES=("$BATS_TEST_TMPDIR/link-ws")
  build_workspace_mounts 2>"$BATS_TEST_TMPDIR/err"
  grep -q "is a symlink; mounting '$BATS_TEST_TMPDIR/real-target'" "$BATS_TEST_TMPDIR/err"
  [ "${SEEN_NAMES[0]}" = real-target ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$BATS_TEST_TMPDIR/real-target:/workspaces/real-target"* ]]
}

# --- build_cmd ---

@test "build_cmd: extra workspaces become --add-dir" {
  CONTAINER_PATHS=(/workspaces/a /workspaces/b) VIBE_FLAGS=(--resume)
  build_cmd
  [ "${CMD[*]}" = "vibe --add-dir /workspaces/b --resume" ]
}

@test "build_cmd: VIBE_DOCKER_TMUX=1 wraps in plain tmux" {
  CONTAINER_PATHS=(/workspaces/a) VIBE_DOCKER_TMUX=1
  build_cmd
  [ "${CMD[*]:0:6}" = "tmux -u new-session -A -s vibe" ]
  [ "${CMD[*]: -1}" = vibe ]
}

@test "build_cmd: VIBE_DOCKER_TMUX=cc uses control mode" {
  CONTAINER_PATHS=(/workspaces/a) VIBE_DOCKER_TMUX=cc
  build_cmd
  [ "${CMD[*]:0:7}" = "tmux -u -CC new-session -A -s vibe" ]
}

@test "build_cmd: --yolo passes --auto-approve to vibe" {
  parse_args --yolo a -- --continue
  CONTAINER_PATHS=(/workspaces/a)
  build_cmd
  [ "${CMD[*]}" = "vibe --auto-approve --continue" ]
}

@test "build_cmd: no flags, just vibe" {
  CONTAINER_PATHS=(/workspaces/a)
  build_cmd
  [ "${CMD[*]}" = vibe ]
}

@test "build_cmd: the tmux hold keeps a non-zero exit visible" {
  CONTAINER_PATHS=(/workspaces/a) VIBE_DOCKER_TMUX=1 VIBE_FLAGS=()
  build_cmd
  # CMD[7..] is: sh -c HOLD_ON_ERR _ vibe; run it with `false` as vibe.
  run sh -c "${CMD[8]}" _ false </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"[false exited 1"* ]]
}

# --- build_volume_mounts ---

@test "build_volume_mounts: --ephemeral mounts no volumes or masks" {
  EPHEMERAL=1
  build_volume_mounts
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

@test "build_volume_mounts: masks every credential dir with no opt-ins" {
  build_volume_mounts
  [ "${MOUNT_ARGS[*]:0:4}" = "-v vibe-root:/root -v vibe-home:/root/.vibe" ]
  local got
  got=$(lines_of "${MOUNT_ARGS[@]}")
  for p in /root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.azure /root/.aws; do
    [[ "$got" == *$'--tmpfs\n'"$p"$'\n'* || "$got" == *$'--tmpfs\n'"$p" ]]
  done
}

@test "build_volume_mounts: gh stays masked while the sidecar is active" {
  WITH_GH=1 GH_SIDECAR_ACTIVE=1
  build_volume_mounts
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *$'--tmpfs\n/root/.config/gh'* ]]
}

@test "build_volume_mounts: glab state is unmasked under either glab flag" {
  for f in WITH_GLAB WITH_GLAB_DIRECT; do
    WITH_GLAB=0 WITH_GLAB_DIRECT=0 MOUNT_ARGS=()
    printf -v "$f" 1
    build_volume_mounts
    [[ "$(lines_of "${MOUNT_ARGS[@]}")" != *glab-cli* ]]
  done
}

# --- stage_glab_config ---

glab_config_setup() {
  GLAB_SRC="$BATS_TEST_TMPDIR/glab-cli"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$GLAB_SRC" "$stage"
  cat >"$GLAB_SRC/config.yml" <<'YML'
git_protocol: https
hosts:
    # glab writes hosts four spaces deep and their keys eight.
    gl.example.com:
        token: glpat-one
        oauth2_refresh_token: refresh-one
        api_host: gl.example.com
        use_keyring: true
    gitlab.com:
        job_token: "glcbt-two"
        api_host: gitlab.com
YML
}

@test "stage_glab_config: proxied copy blanks every token value" {
  glab_config_setup
  WITH_GLAB=1 GLAB_SIDECAR_ACTIVE=1 GLAB_PROXY_HOST=gl.example.com
  run stage_glab_config
  [ "$status" -eq 0 ] && [ -z "$output" ]
  stage_glab_config 2>/dev/null
  run ! grep -Eq 'glpat-one|refresh-one|glcbt-two' "$stage/glab-config.yml"
  grep -qx '        token: ""' "$stage/glab-config.yml"
  grep -qx '        use_keyring: false' "$stage/glab-config.yml"
  grep -qx '        api_host: gl.example.com' "$stage/glab-config.yml"
  [ "$(wc -l <"$stage/glab-config.yml")" -eq "$(wc -l <"$GLAB_SRC/config.yml")" ]
}

@test "stage_glab_config: --glab without a found token still blanks them" {
  glab_config_setup
  WITH_GLAB=1 GLAB_SIDECAR_ACTIVE=0
  stage_glab_config
  run ! grep -Eq 'glpat-one|refresh-one|glcbt-two' "$stage/glab-config.yml"
}

@test "stage_glab_config: --glab-direct keeps the tokens" {
  glab_config_setup
  stage_glab_config
  grep -q glpat-one "$stage/glab-config.yml"
  grep -qx '        use_keyring: false' "$stage/glab-config.yml"
}

@test "stage_glab_config: warns when api_host is not the proxied host" {
  glab_config_setup
  sed 's/        api_host: gl.example.com/        api_host: api.gl.example.com/' "$GLAB_SRC/config.yml" >"$BATS_TEST_TMPDIR/c.yml"
  mv "$BATS_TEST_TMPDIR/c.yml" "$GLAB_SRC/config.yml"
  GLAB_SIDECAR_ACTIVE=1 GLAB_PROXY_HOST=gl.example.com
  run stage_glab_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"api_host for gl.example.com is 'api.gl.example.com'"* ]]
}

@test "stage_glab_config: warns for a two-space hand-written config too" {
  glab_config_setup
  printf 'hosts:\n  gl.example.com:\n    api_host: api.gl.example.com\n  gitlab.com:\n    api_host: gitlab.com\n' >"$GLAB_SRC/config.yml"
  GLAB_SIDECAR_ACTIVE=1 GLAB_PROXY_HOST=gl.example.com
  run stage_glab_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"api_host for gl.example.com is 'api.gl.example.com'"* ]]
}

@test "stage_glab_config: no warning when another host has a different api_host" {
  glab_config_setup
  printf 'hosts:\n    gitlab.com:\n        api_host: api.gitlab.com\n    gl.example.com:\n        api_host: gl.example.com\n' >"$GLAB_SRC/config.yml"
  GLAB_SIDECAR_ACTIVE=1 GLAB_PROXY_HOST=gl.example.com
  run stage_glab_config
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

# --- run_container / main ---

@test "run_container: hands everything to the runtime" {
  MOUNT_ARGS=(-v a:b) ENV_ARGS=(-e TERM) CWD=/workspaces/repo CMD=(vibe)
  run_container
  grep -q "^docker run --rm -it --init .* -v a:b -e TERM -w /workspaces/repo mistral-vibe:local vibe$" "$CALLS"
}

@test "main: end to end with stubs" {
  run_script --ephemeral --aws "$WS" -- --resume
  [ "$status" -eq 0 ]
  grep -q "^docker run --rm -it .*-v $WS:/workspaces/repo .*VIBE_DOCKER_FLAGS=aws,ephemeral -w /workspaces/repo mistral-vibe:local vibe --resume$" "$CALLS"
}

@test "main: -- --resume <session-id> reaches vibe unchanged" {
  run_script "$WS" -- --resume 0b5c1e2a-6f3d-4c8e-9a71-2d4f6b8e0c13
  [ "$status" -eq 0 ]
  grep -q "^docker run --rm -it .* -w /workspaces/repo mistral-vibe:local vibe --resume 0b5c1e2a-6f3d-4c8e-9a71-2d4f6b8e0c13$" "$CALLS"
}

@test "main: a bad workspace stops before any docker call" {
  run_script "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 1 ]
  [ "$output" = "vibe-docker: workspace '$BATS_TEST_TMPDIR/missing' is not a directory" ]
  run ! grep -q "^docker run" "$CALLS"
}

@test "main: a failing sidecar stops before the agent starts" {
  STUB_FAIL="inspect"
  run_script --ephemeral --gh "$WS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not determine"* ]]
  run ! grep -q "^docker run --rm" "$CALLS"
}

@test "main: --mistral forwards the key by name into the agent container only" {
  export MISTRAL_API_KEY=sk-mistral-secret
  run_script --ephemeral --mistral "$WS"
  [ "$status" -eq 0 ]
  grep -q "^docker run --rm -it .* -e MISTRAL_API_KEY .*VIBE_DOCKER_FLAGS=mistral,ephemeral -w /workspaces/repo mistral-vibe:local vibe$" "$CALLS"
  run ! grep -q sk-mistral-secret "$CALLS"
}

@test "main: without --mistral a host MISTRAL_API_KEY stays on the host" {
  export MISTRAL_API_KEY=sk-mistral-secret
  run_script --ephemeral "$WS"
  [ "$status" -eq 0 ]
  run ! grep -q MISTRAL "$CALLS"
}

@test "main: --mistral without a key stops before any docker call" {
  run_script --mistral "$WS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--mistral needs MISTRAL_API_KEY"* ]]
  [ ! -s "$CALLS" ]
}

@test "main: --api is an unknown flag and starts nothing" {
  run_script --api "$WS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown flag '--api'"* ]]
  [ ! -s "$CALLS" ]
}

@test "main: the persistent volumes are vibe-root and vibe-home" {
  run_script "$WS"
  [ "$status" -eq 0 ]
  grep -q "^docker run --rm -it .* -v vibe-root:/root -v vibe-home:/root/.vibe " "$CALLS"
}
