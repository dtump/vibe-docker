#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# Drop from container root to the host user's UID/GID before exec'ing vibe
# so that files written through bind-mounts match host ownership. With
# HOST_UID unset or 0, falls through to the legacy "run as root" behavior so
# the image still works in environments that don't forward the host UID.

# Fixed paths. Plain globals, not env, so the container environment can't
# redirect them; the BATS suite reassigns them after sourcing.
SEED_CONFIG=/run/vibe-docker/config.toml
ROOT_HOME=/root
CA_DIR=/usr/local/share/ca-certificates
GIT_SYSTEM_CONFIG=/etc/gitconfig

# Seed /root/.vibe/config.toml from the host config.docker.toml that run.sh
# forwards at the seed path. A copy, not a bind mount at the real path: vibe
# saves settings (/config, /theme, /model) by renaming a temporary file over
# config.toml, and rename() over a mountpoint fails with EBUSY — a direct
# single-file mount breaks every in-session settings change. The copy lives
# on the container filesystem, so those writes work; they last for this run
# only and are overwritten from the host file on the next start. Without a
# seed nothing happens, and a config.toml an earlier session saved in the
# vibe-home volume is kept.
# Ownership dance: on a warm volume the dir/file are HOST_UID-owned from a
# prior run's chown walk, and container root has no CAP_DAC_OVERRIDE — take
# ownership (CAP_CHOWN) before writing; the chown walk below hands everything
# back to HOST_UID. rm+cp instead of cp -f for the same reason: overwriting a
# HOST_UID-owned 0600 file in place would be denied.
seed_config() {
  [ -f "$SEED_CONFIG" ] || return 0
  mkdir -p "$ROOT_HOME/.vibe" || return
  chown root "$ROOT_HOME/.vibe" || return
  rm -f "$ROOT_HOME/.vibe/config.toml" || return
  cp "$SEED_CONFIG" "$ROOT_HOME/.vibe/config.toml" || return
  chmod 600 "$ROOT_HOME/.vibe/config.toml"
}

# Auth-proxy sidecar CA (run.sh --gh / --glab with a sidecar active): install
# it into the system trust store so git (libcurl), gh and glab (Go) trust the
# sidecar's TLS termination for the redirected forge hostnames. Must run as
# root, before the UID drop below — update-ca-certificates writes under
# /etc/ssl/certs. Silent when no such file is mounted (no proxied opt-in, a
# --*-direct one, or the no-token fallback); a refresh failure is a warning,
# not fatal, so it doesn't block the session over a CA problem the user can't
# fix here. The same step installs the --az private CA (VIBE_DOCKER_AZ_CA).
# vibe itself trusts the OS store because the image sets
# VIBE_ENABLE_SYSTEM_TRUST_STORE=true.
install_cas() {
  compgen -G "$CA_DIR/vibe-docker-*.crt" >/dev/null || return 0
  update-ca-certificates >/dev/null 2>&1 \
    || printf 'entrypoint: WARN update-ca-certificates failed for a vibe-docker CA\n' >&2
}

# Synthesize a passwd entry so getpwuid / $HOME / shell expansions resolve
# cleanly inside the container. Guarded on the `vibe` name, not on
# HOST_UID: a HOST_UID that collides with a baked-in Ubuntu system user
# still needs a `vibe` entry for `runuser -u vibe`, and -o
# (--non-unique) lets useradd create it with the duplicate UID. HOME=/root
# is deliberate — keeps the existing /root/.vibe, /root/.aws, /root/.config
# mount paths intact instead of forcing a layout migration.
# -K UID_MIN=1 overrides the login.defs floor per-call so macOS UIDs (≥501,
# below Ubuntu's default 1000) don't trigger a warning.
# An existing `vibe` (e.g. one a child image added) must already have
# HOST_UID: otherwise the session would run as that UID — wrong owner on the
# workspace mounts, and no privilege drop at all if it is 0 — so refuse.
ensure_user() {
  local uid=$1 gid=$2 existing
  if getent passwd vibe >/dev/null 2>&1; then
    existing="$(id -u vibe)" || return
    [ "$existing" = "$uid" ] && return 0
    printf 'entrypoint: ERROR existing vibe user has UID %s, expected HOST_UID %s\n' \
      "$existing" "$uid" >&2
    return 1
  fi
  getent group "$gid" >/dev/null 2>&1 \
    || groupadd -o -g "$gid" vibe \
    || return
  useradd -o -K UID_MIN=1 -u "$uid" -g "$gid" -d /root -s /bin/bash -M -N vibe
}

# Chown the persistent /root volumes (vibe-root, vibe-home)
# so the dropped-privilege user can write its own HOME. -xdev prunes the
# :ro credential and config bind-mounts under /root on Linux (they have
# distinct st_dev), but Docker Desktop's virtiofs on macOS collapses
# st_dev across bind mounts so the walk descends into them anyway. chown
# on a :ro mount returns EROFS, which would abort the entrypoint under
# set -e — so we capture stderr, drop the expected EROFS lines, and
# surface anything else as a warning. Pruning by /proc/self/mountinfo
# would also skip the *writable* tmpfs masks (which we do want to chown),
# so the post-hoc filter is the simpler-correct option. Two start points
# because /root and /root/.vibe are separate volumes. Requires
# CAP_CHOWN to chown to a different UID, and CAP_DAC_READ_SEARCH so
# container root can traverse HOST_UID-owned, mode-0700 directories
# under /root (vibe makes ~/.vibe 0700 itself). stderr is captured for the
# whole pipeline, so a failing find warns too; LC_ALL=C pins the EROFS
# message the filter matches.
chown_volumes() {
  local uid=$1 gid=$2 chown_errs roots=("$ROOT_HOME")
  # /root/.vibe is its own volume, absent under --ephemeral until something
  # (a seeded config.toml, a host config mount) creates it.
  [ -d "$ROOT_HOME/.vibe" ] && roots+=("$ROOT_HOME/.vibe")
  chown_errs="$( { find "${roots[@]}" -xdev -print0 \
    | xargs -0 --no-run-if-empty chown -h "$uid:$gid"; } 2>&1 >/dev/null || true)"
  chown_errs="$(grep -v 'Read-only file system' <<<"$chown_errs" || true)"
  if [ -n "$chown_errs" ]; then
    printf 'entrypoint: WARN chown: %s\n' "$chown_errs" >&2
  fi
}

# Trust the workspaces run.sh vouched for (VIBE_DOCKER_TRUSTED_WORKSPACES,
# colon-separated container paths; see build_git_trust) in git's system
# config, so git's ownership check accepts them, and the worktrees nested in
# them, whatever owner the mount reports. System scope, written as root before
# the drop: the session can't edit it, and a GIT_CONFIG_* export or a cleaned
# environment doesn't remove it. Only a /workspaces/<name> path is written;
# anything else, a * included (git reads "*" as "trust every repository"), is
# refused with a WARN.
trust_workspaces() {
  local p list="${VIBE_DOCKER_TRUSTED_WORKSPACES:-}" paths=()
  [ -n "$list" ] || return 0
  # read -a, not an unquoted $list: the shell would expand a * in an entry
  # against the filesystem before the check below could refuse it.
  IFS=: read -ra paths <<<"$list"
  for p in "${paths[@]}"; do
    case "$p" in
      '') continue ;;
      /workspaces/*/* | */. | */.. | *'*'* | *'?'* | *'['* ) ;;
      /workspaces/?*)
        git config --file "$GIT_SYSTEM_CONFIG" --add safe.directory "$p" \
          && git config --file "$GIT_SYSTEM_CONFIG" --add safe.directory "$p/*" \
          || { printf 'entrypoint: ERROR could not trust %s for git\n' "$p" >&2; return 1; }
        continue ;;
    esac
    printf 'entrypoint: WARN not trusting %s for git: not a /workspaces/<name> path\n' "$p" >&2
  done
}

main() {
  set -euo pipefail
  local uid="${HOST_UID:-0}" gid="${HOST_GID:-0}"
  # Explicit || return on every step: set -e is ignored when main runs in
  # an ||/if context or under bats `run`, and a failed step must not
  # fall through to the exec.
  seed_config || return
  install_cas || return
  trust_workspaces || return
  if [ "$uid" = 0 ]; then
    exec "$@"
  fi
  ensure_user "$uid" "$gid" || return
  # Scoped to the walk: the session itself keeps the caller's locale.
  LC_ALL=C chown_volumes "$uid" "$gid" || return
  # runuser uses setresuid()/setresgid() — needs CAP_SETUID and CAP_SETGID
  # at this point (we're still UID 0). The kernel clears effective,
  # permitted, and ambient caps on the UID→non-zero transition; the bounding
  # set retains the setup caps but is inert under `no-new-privileges`. So
  # vibe itself, and every shell command or MCP server it starts, runs with
  # no usable capabilities.
  exec runuser -u vibe -- "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
