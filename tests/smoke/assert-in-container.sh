#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# assert-in-container.sh — runs INSIDE the container as the dropped user.
# Invoked as the container command: entrypoint.sh calls
#   exec runuser -u vibe -- /workspaces/smoke/assert-in-container.sh
# Reads expectations from env vars set by smoke.sh (via VIBE_DOCKER_TEST_ENTRY):
#   EXPECT_UID        expected numeric UID (matches HOST_UID forwarded by smoke.sh)
#   EXPECT_GID        expected primary GID (HOST_GID); checked when EXPECT_UID != 0
#   EXPECT_EPHEMERAL  1 = --ephemeral run: no volumes, so no AWS tmpfs mask to assert
#   EXPECT_OPTINS     comma-separated list of granted opt-ins (aws glab tfe mistral az), or empty
#   WORKSPACE         path to the bind-mounted workspace inside the container
#   EXPECT_RO         1 = workspace is :ro (skip write probe, only test entrypoint startup)
#   EXPECT_CONFIG     1 = a config.docker.toml fixture was mounted at the seed path;
#                     assert the entrypoint copied it to /root/.vibe/config.toml (mode
#                     600) and the copy is atomically replaceable. 0 = no seed on fresh
#                     volumes; assert nothing was seeded. keep = no seed this run, but a
#                     previous run persisted a config.toml in the warm volume; assert it
#                     survived.
#   EXPECT_CONFIG_SENTINEL
#                     sentinel string the config.toml content must carry. Passed by
#                     smoke.sh rather than hardcoded here: the warm cell changes it
#                     between passes to prove re-seeding overwrites the previous copy.
#   EXPECT_VIBE_VERSION
#                     the pinned vibe version (pins/vibe.env) `vibe --version` must report.
# Accumulates per-check PASS/FAIL and exits non-zero at the end if any failed
# (so one regression doesn't hide the rest of the report).
#
# Filesystem locations, overridable so tests/bats can point them at fixtures.
# smoke.sh never sets them; the defaults are the real in-container paths.
PROC_STATUS="${PROC_STATUS:-/proc/self/status}"
PROC_MOUNTS="${PROC_MOUNTS:-/proc/self/mounts}"
ROOT_HOME="${ROOT_HOME:-/root}"
SEED_CONFIG="${SEED_CONFIG:-/run/vibe-docker/config.toml}"
AZ_CA="${AZ_CA:-/usr/local/share/ca-certificates/vibe-docker-az.crt}"
AUTH_PROXY_CA="${AUTH_PROXY_CA:-/usr/local/share/ca-certificates/vibe-docker-auth-proxy.crt}"
CA_BUNDLE="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$label: got '$got'"
  else
    fail "$label: expected '$want', got '$got'"
  fi
}

# True when the mount at exactly $1 carries the `ro` option (field 6 of
# /proc/self/mountinfo, the per-mount options; the superblock options in the
# last field say nothing about a read-only bind mount).
mount_is_ro() {
  awk -v p="$1" '$5 == p && $6 ~ /(^|,)ro(,|$)/ { found = 1 } END { exit !found }' \
    /proc/self/mountinfo
}

# Run a command and assert it fails with a substring matching the read-only
# filesystem error (uutils coreutils on ubuntu:26.04 emits "Read-only file
# system"; GNU coreutils emits the same string — match the common substring).
# Handles both directory paths (creates a sentinel file inside) and file paths
# (attempts to overwrite the file with tee).
# A file the session does not own answers "Permission denied" instead: the
# kernel checks the file's mode before the mount's read-only flag when opening
# for write, while creating a file in a directory hits the mount flag first.
# The staged copies are owned by the host user, so a cell whose HOST_UID differs
# from the runner's (uid 501 in CI) gets EACCES on every file item. That is
# accepted only when /proc/self/mountinfo shows the mount itself is `ro`.
assert_write_fails_ro() {
  local label="$1" path="$2"
  local out
  # Choose a write operation depending on whether path is a directory or file.
  if [ -d "$path" ]; then
    # Directory: try to create a sentinel file inside it.
    # Redirect stderr to stdout so we can grep the combined output.
    if out=$(touch "${path}/__smoke_write_test" 2>&1); then
      fail "$label: write to dir '${path}' succeeded (expected EROFS)"
      rm -f "${path}/__smoke_write_test"
    else
      if echo "$out" | grep -q "Read-only file system"; then
        pass "$label: write to dir blocked with read-only-filesystem error"
      else
        fail "$label: write to dir blocked but not by EROFS ('$out')"
      fi
    fi
  else
    # File: try to append to it.
    if out=$(tee -a "${path}" </dev/null 2>&1); then
      fail "$label: write to file '${path}' succeeded (expected EROFS)"
    else
      if echo "$out" | grep -q "Read-only file system"; then
        pass "$label: write to file blocked with read-only-filesystem error"
      elif echo "$out" | grep -q "Permission denied" && mount_is_ro "$path"; then
        pass "$label: write to file blocked by EACCES (not the owner) on a mount listed ro"
      else
        fail "$label: write to file blocked but not by EROFS ('$out')"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# 1. Identity checks
# ---------------------------------------------------------------------------

check_identity() {
  local actual_uid actual_gids home_val

  actual_uid=$(id -u)
  assert_eq "UID=EXPECT_UID" "$actual_uid" "${EXPECT_UID:-0}"

  # The process should have exactly ONE GID (no inherited sudo/adm/plugdev).
  # `id -G` returns space-separated list of all gids.
  actual_gids=$(id -G)
  local gid_count
  gid_count=$(printf '%s' "$actual_gids" | wc -w)
  if [ "$gid_count" -eq 1 ]; then
    pass "single-group: only primary GID present (id -G='$actual_gids')"
  else
    fail "single-group: expected exactly 1 GID, got $gid_count ('$actual_gids')"
  fi

  # And it must be the EXPECTED primary GID — a regression assigning vibe to
  # gid 0 (root) as its single group would pass the count check above. Skip for
  # the root-legacy cell, where the process keeps gid 0 (not HOST_GID).
  if [ "${EXPECT_UID:-0}" != "0" ]; then
    assert_eq "primary-GID=EXPECT_GID" "$(id -g)" "${EXPECT_GID:-0}"
  fi

  # HOME must be /root regardless of HOST_UID (kept for mount-path compatibility).
  home_val="${HOME:-}"
  assert_eq "HOME=/root" "$home_val" "/root"
}

# ---------------------------------------------------------------------------
# 2. Security posture — capabilities and no-new-privs
# ---------------------------------------------------------------------------

check_security() {
  local status_file="$PROC_STATUS"

  if [ ! -f "$status_file" ]; then
    fail "security: $status_file not found"
    return
  fi

  # awk alone, not grep | awk: a missing field yields an empty value (which
  # the assertions below report) instead of a pipefail abort of the run.
  local cap_eff cap_prm cap_amb cap_bnd nnp
  cap_eff=$(awk '/^CapEff:/{print $2}' "$status_file")
  cap_prm=$(awk '/^CapPrm:/{print $2}' "$status_file")
  cap_amb=$(awk '/^CapAmb:/{print $2}' "$status_file")
  cap_bnd=$(awk '/^CapBnd:/{print $2}' "$status_file")
  nnp=$(awk '/^NoNewPrivs:/{print $2}' "$status_file")

  # Universal invariants — these hold regardless of HOST_UID (including the
  # root-legacy path), so assert them BEFORE the uid=0 branch below.
  # no-new-privileges and the absence of setuid-root binaries are exactly the
  # controls that bound blast radius if the root path is ever entered, so the
  # root cell is the one place we most want them confirmed.
  assert_eq "NoNewPrivs=1" "$nnp" "1"

  # Setuid-root binaries: the base Ubuntu image ships the usual set (su, mount,
  # passwd, chsh, chfn, gpasswd, ssh-keysign, …). Under no-new-privileges
  # (asserted above) the kernel ignores the setuid bit, so NONE of them can
  # escalate — NoNewPrivs is the real control, not their absence. We therefore
  # don't fail on the inert base set (that would just track Ubuntu's package
  # list); we assert the one thing that WOULD matter: `sudo` must not be present,
  # since a sudo install is a deliberate escalation path the cap-drop model
  # forbids and a clear regression. The inventory is logged for visibility.
  local setuid_files
  setuid_files=$(find / -xdev -perm -4000 -type f 2>/dev/null | tr '\n' ' ' || true)
  echo "  (info) setuid-root binaries present (inert under NoNewPrivs): ${setuid_files:-<none>}"
  if command -v sudo >/dev/null 2>&1; then
    fail "no-sudo: sudo is present on PATH — an escalation path the cap-drop model forbids"
  else
    pass "no-sudo: sudo not installed (no escalation path beyond the inert base setuid set)"
  fi

  # Root-legacy path: with HOST_UID=0 the entrypoint execs directly as root
  # (entrypoint.sh :11-13) and never drops privileges, so root legitimately
  # retains effective caps. The dropped-privilege posture below does NOT apply;
  # asserting CapEff==0 here would wrongly fail a correct image.
  if [ "${EXPECT_UID:-0}" = "0" ]; then
    pass "security: HOST_UID=0 root-legacy path — cap-drop posture N/A (runs as root by design)"
    return
  fi

  # Dropped-privilege posture: CapEff/CapPrm/CapAmb must all be zero after
  # runuser drops UID 0. CapBnd retains the --cap-add set but is inert under
  # NoNewPrivs. Bit decomposition of the expected 0xc5 bounding set:
  #   CAP_CHOWN          (0) → bit 0 → 0x001
  #   CAP_DAC_READ_SEARCH(2) → bit 2 → 0x004
  #   CAP_SETGID         (6) → bit 6 → 0x040
  #   CAP_SETUID         (7) → bit 7 → 0x080   sum = 0xc5 = 197
  assert_eq "CapEff=0" "$cap_eff" "0000000000000000"
  assert_eq "CapPrm=0" "$cap_prm" "0000000000000000"
  assert_eq "CapAmb=0" "$cap_amb" "0000000000000000"

  # CapBnd and NoNewPrivs are a joint assertion: a non-empty bounding set is
  # only safe when no-new-privileges is also set.
  if [ "$cap_bnd" = "00000000000000c5" ] && [ "$nnp" = "1" ]; then
    pass "CapBnd+NoNewPrivs: bounding set=0x${cap_bnd} is inert under NoNewPrivs=${nnp}"
  else
    fail "CapBnd+NoNewPrivs: expected CapBnd=00000000000000c5 and NoNewPrivs=1, got CapBnd=${cap_bnd} NoNewPrivs=${nnp}"
  fi
}

# ---------------------------------------------------------------------------
# 3. PATH ordering and the exported Go environment
# ---------------------------------------------------------------------------

# Index of an entry in the colon-separated PATH, or -1 when absent. Matches
# whole entries only, so /root/go/bin never matches inside /root/go/bin/foo.
path_index() {
  local want="$1" i=0 entry
  local IFS=:
  for entry in $PATH; do
    if [ "$entry" = "$want" ]; then
      printf '%s' "$i"
      return
    fi
    i=$((i + 1))
  done
  printf '%s' "-1"
}

assert_path_before() {
  local first="$1" second="$2"
  local a b
  a=$(path_index "$first")
  b=$(path_index "$second")
  if [ "$a" = "-1" ]; then
    fail "path-order: $first is not on PATH (PATH=$PATH)"
  elif [ "$b" = "-1" ]; then
    fail "path-order: $second is not on PATH (PATH=$PATH)"
  elif [ "$a" -lt "$b" ]; then
    pass "path-order: $first (#$a) precedes $second (#$b)"
  else
    fail "path-order: expected $first before $second, got #$a and #$b (PATH=$PATH)"
  fi
}

check_path_order() {
  # The image PATH survives the privilege drop — entrypoint.sh execs
  # `runuser -u vibe` (not -l), so what this script sees IS the shipped
  # ordering. /root is the persistent vibe-root volume, so both
  # /root/.local/bin (pip --user / uv tool install prefix) and /root/go/bin
  # (GOPATH default, `go install` target) are agent-writable and survive the
  # session. Neither may precede a system path: a binary one session leaves
  # there must not shadow git/gh/aws on a later run, in an unrelated workspace.
  # /usr/bin stands in for "the system paths" — it is where git and gh live.
  assert_path_before /usr/local/go/bin /usr/bin
  assert_path_before /usr/bin /root/.local/bin
  assert_path_before /usr/bin /root/go/bin

  # And the resolution actually lands on the system copy, not merely earlier in
  # a string — this is the invariant the ordering exists to buy.
  assert_eq "path-git-resolves-system" "$(command -v git)" "/usr/bin/git"

  # Go environment exported by the image (ENV), so it holds for docker run,
  # docker exec, and non-login shells alike rather than relying on `go env`
  # defaults. Spelled against a literal /root: Docker does not define HOME at
  # build time.
  assert_eq "GOROOT=/usr/local/go" "${GOROOT:-}" "/usr/local/go"
  assert_eq "GOPATH=/root/go" "${GOPATH:-}" "/root/go"
  assert_eq "GOBIN=/root/go/bin" "${GOBIN:-}" "/root/go/bin"
}

# ---------------------------------------------------------------------------
# 3b. git ownership check — only the workspaces run.sh vouched for are trusted
# ---------------------------------------------------------------------------

# Print "ok" when git opens the repo at $1, else git's error. The remaining
# args are extra env (e.g. a GIT_CONFIG_* set a session might export).
# GIT_TEST_ASSUME_DIFFERENT_OWNER makes git treat every path as foreign-owned,
# which is the mismatch the safe.directory entry has to absorb.
git_opens() {
  local dir="$1" out
  shift
  if out=$(env GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$@" git -C "$dir" rev-parse --show-toplevel 2>&1); then
    echo ok
  else
    printf '%s\n' "$out" | head -1
  fi
}

# Each setup step is a condition, so a failed mktemp or git init is a FAIL
# under main's set -e rather than an abort, and the temp repos are removed on
# every path.
check_git_trust() {
  local ws="${WORKSPACE:-/workspaces/smoke}" outside="" repo=""
  # The smoke workspace is the runner's own directory, so run.sh vouches for it.
  assert_eq "git-safe-directory-system" \
    "$(git config --system --get-all safe.directory | paste -sd,)" "$ws,$ws/*"

  if outside=$(mktemp -d) && git init -q "$outside"; then
    case "$(git_opens "$outside")" in
      *"dubious ownership"*) pass "git-trust: foreign-owned repo outside /workspaces refused" ;;
      *) fail "git-trust: foreign-owned repo outside /workspaces was not refused" ;;
    esac
  else
    fail "git-trust: could not create a repo outside /workspaces"
  fi
  [ -z "$outside" ] || rm -rf "$outside"

  if [ "${EXPECT_RO:-0}" = "1" ]; then
    pass "git-trust-workspace: skipped (EXPECT_RO=1, workspace is :ro)"
    return 0
  fi
  # Nested two levels, like a <repo>/.worktrees/<name> checkout.
  if repo=$(mktemp -d "$ws/.git-trust.XXXXXX") && git init -q "$repo/nested/repo"; then
    assert_eq "git-trust: foreign-owned repo under a trusted workspace opens" \
      "$(git_opens "$repo/nested/repo")" "ok"
    assert_eq "git-trust: survives an exported GIT_CONFIG_* set" \
      "$(git_opens "$repo/nested/repo" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/elsewhere)" "ok"
  else
    fail "git-trust: could not create a repo under $ws"
  fi
  [ -z "$repo" ] || rm -rf "$repo"
}

# ---------------------------------------------------------------------------
# 4. File ownership — write into the workspace, smoke.sh checks host ownership
# ---------------------------------------------------------------------------

check_workspace_write() {
  # Skip the write probe when the workspace is mounted :ro (RO cell).
  # The RO cell tests entrypoint EROFS robustness, not workspace writability.
  if [ "${EXPECT_RO:-0}" = "1" ]; then
    pass "workspace-write: skipped (EXPECT_RO=1, workspace is :ro)"
    return
  fi

  local ws="${WORKSPACE:-/workspaces/smoke}"
  local probe_file="${ws}/smoke-probe.txt"

  if printf '%s\n' "smoke-write-$$" > "$probe_file"; then
    pass "workspace-write: created $probe_file"
  else
    fail "workspace-write: could not write to $probe_file"
  fi
}

# ---------------------------------------------------------------------------
# 5. Credential plumbing
# ---------------------------------------------------------------------------

# Mapping: opt-in name → container config path + env var to check.
# Format: "config_path:env_var" (env_var may be empty if not applicable)
optin_config_path() {
  case "$1" in
    aws)  echo "${ROOT_HOME}/.aws/config:AWS_PROFILE" ;;
    glab) echo "${ROOT_HOME}/.config/glab-cli:GITLAB_TOKEN" ;;
    tfe)  echo "${ROOT_HOME}/.terraform.d/credentials.tfrc.json:TF_TOKEN_app_terraform_io" ;;
    az)   echo "${ROOT_HOME}/.azure:AZURE_DEVOPS_EXT_PAT" ;;
    *)    echo "" ;;
  esac
}

# All known opt-ins in declaration order.
ALL_OPTINS=(aws glab tfe az)

check_credentials() {
  local optin g
  local -a granted_list=()
  IFS=',' read -ra granted_list <<< "${EXPECT_OPTINS:-}"

  for optin in "${ALL_OPTINS[@]}"; do
    local spec config_path env_var
    spec=$(optin_config_path "$optin")
    config_path="${spec%%:*}"
    env_var="${spec##*:}"

    # Determine whether this opt-in was granted.
    local granted=0
    for g in "${granted_list[@]}"; do
      if [ "$g" = "$optin" ]; then
        granted=1
        break
      fi
    done

    if [ "$granted" = "1" ] && [ "$optin" = "az" ]; then
      # --az mounts no host file (/root/.azure is plain volume state), so the
      # forwarded PAT is the fixture: it must be OUR sentinel.
      case "${AZURE_DEVOPS_EXT_PAT:-}" in
        *SMOKE-SENTINEL*) pass "optin-az-env: AZURE_DEVOPS_EXT_PAT carries the smoke sentinel" ;;
        *)                fail "optin-az-env: AZURE_DEVOPS_EXT_PAT missing or not the smoke fixture" ;;
      esac
    elif [ "$granted" = "1" ]; then
      # Config path must exist and be read-only (mounted :ro by run.sh).
      if [ -e "$config_path" ]; then
        pass "optin-${optin}: config path exists: $config_path"
      else
        fail "optin-${optin}: config path missing: $config_path"
      fi
      assert_write_fails_ro "optin-${optin}-ro" "$config_path"

      # The mounted content must be OUR fixture (carries the SMOKE-SENTINEL
      # string). This proves the EXPECTED file was mounted, not merely that
      # *some* file is present — a regression bind-mounting a different host
      # file (e.g. ~/.aws/credentials instead of ~/.aws/config) is caught here.
      if grep -rqI "SMOKE-SENTINEL" "$config_path" 2>/dev/null; then
        pass "optin-${optin}-content: mounted fixture carries the smoke sentinel"
      else
        fail "optin-${optin}-content: SMOKE-SENTINEL not found under $config_path (wrong file mounted?)"
      fi

      # Forward env var must be present — smoke.sh always exports it for a
      # granted opt-in, so absence is a forwarding regression (fail-closed).
      if [ -n "$env_var" ]; then
        if [ -n "${!env_var:-}" ]; then
          pass "optin-${optin}-env: ${env_var} is forwarded"
        else
          fail "optin-${optin}-env: ${env_var} expected but not set (forwarding regression)"
        fi
      fi
      # --glab keeps the token in the auth-proxy sidecar: the agent sees only
      # the placeholder, and the session CA it reaches GitLab through is trusted.
      if [ "$optin" = "glab" ]; then
        if [ "${GITLAB_TOKEN:-}" = "vibe-docker-proxy" ]; then
          pass "optin-glab-proxy: GITLAB_TOKEN is the auth-proxy placeholder"
        else
          fail "optin-glab-proxy: GITLAB_TOKEN is not the placeholder (real token forwarded?)"
        fi
        if [ -f "$AUTH_PROXY_CA" ]; then
          pass "optin-glab-proxy-ca: the auth-proxy session CA is mounted"
        else
          fail "optin-glab-proxy-ca: auth-proxy session CA missing"
        fi
      fi
    else
      # Config path must be absent or masked (empty tmpfs from run.sh).
      if [ ! -e "$config_path" ]; then
        pass "masked-${optin}: config path absent: $config_path"
      else
        # It may exist as an empty tmpfs mount — acceptable.
        local entry_count
        entry_count=$(find "$config_path" -maxdepth 1 2>/dev/null | wc -l)
        if [ "$entry_count" -le 1 ]; then
          pass "masked-${optin}: config path is present but empty (tmpfs mask): $config_path"
        else
          fail "masked-${optin}: config path unexpectedly populated when opt-in is off: $config_path"
        fi
      fi

      # The forward env var must NOT be set when the opt-in is off — a regression
      # forwarding a token without its opt-in flag would leak it (assume-breach).
      if [ -n "$env_var" ] && [ -n "${!env_var:-}" ]; then
        fail "leak-${optin}: ${env_var} is set but opt-in '${optin}' was not granted"
      else
        pass "leak-${optin}: ${env_var:-<none>} not forwarded (opt-in off)"
      fi
    fi
  done
}

# AWS needs its own check, and cannot be folded into the loop above.
# optin_config_path returns /root/.aws/config, and that value is shared with the
# granted branch, which asserts the path is read-only. /root/.aws is not — only
# the two entries mounted inside it are — so repointing the mapping at the
# directory would make the granted branch fail.
#
# The loop is also blind to what matters here: without --aws, /root/.aws/config
# is absent whether or not a mask exists, so the masked-aws assertion passed
# vacuously and the credential cache beside it went unexamined.
check_aws_state_masking() {
  local granted=0
  case ",${EXPECT_OPTINS:-}," in
    *,aws,*) granted=1 ;;
  esac

  # --ephemeral mounts no named volumes, so there is nothing to mask and run.sh
  # adds no tmpfs (the whole mask block is inside its EPHEMERAL=0 branch). The
  # property still worth asserting is the one the masks exist to provide: no
  # AWS state carried in from anywhere. Requiring a tmpfs here would fail the
  # ephemeral cell for doing exactly what it is supposed to do.
  if [ "${EXPECT_EPHEMERAL:-0}" = "1" ]; then
    local cache="${ROOT_HOME}/.aws/cli/cache"
    if [ ! -e "$cache" ] || [ "$(find "$cache" -mindepth 1 2>/dev/null | wc -l)" -eq 0 ]; then
      pass "ephemeral-aws: no AWS credential cache present (no volumes mounted)"
    else
      fail "ephemeral-aws: ${cache} is populated in an --ephemeral session"
    fi
    return
  fi

  local path label
  if [ "$granted" = "1" ]; then
    # Under --aws the mask narrows to the credential cache: the AWS CLI writes
    # assume-role/SSO-derived STS there, and /root is a shared persistent
    # volume, so it must not outlive this session.
    path="${ROOT_HOME}/.aws/cli/cache"
    label="aws-cache-masked"
  else
    path="${ROOT_HOME}/.aws"
    label="masked-aws-dir"
  fi

  if [ ! -e "$path" ]; then
    fail "${label}: ${path} does not exist (expected an empty tmpfs mask)"
    return
  fi

  local entry_count
  entry_count=$(find "$path" -mindepth 1 2>/dev/null | wc -l)
  if [ "$entry_count" -eq 0 ]; then
    pass "${label}: ${path} is present and empty (tmpfs mask)"
  else
    fail "${label}: ${path} unexpectedly populated ($entry_count entries)"
  fi

  # Under --aws the read-only host mounts must survive the narrower mask.
  if [ "$granted" = "1" ]; then
    if [ -f "${ROOT_HOME}/.aws/config" ]; then
      pass "aws-cache-masked-scope: ${ROOT_HOME}/.aws/config still visible under the cache mask"
    else
      fail "aws-cache-masked-scope: ${ROOT_HOME}/.aws/config hidden — mask is too broad"
    fi

    # This is the one mask that must stay WRITABLE. Every other mask exists to
    # deny access, but the AWS CLI writes its derived STS credentials into this
    # directory, so an unwritable mask would break `aws` under the very flag
    # that grants it. Nothing else guarantees it: entrypoint.sh's chown walk
    # runs `find /root ... -xdev`, which by design does not descend into a
    # tmpfs, so ownership here is whatever the mount gave us.
    if touch "${path}/__smoke_write_test" 2>/dev/null; then
      pass "aws-cache-writable: the cache mask accepts writes from the session user"
      rm -f "${path}/__smoke_write_test"
    else
      fail "aws-cache-writable: cannot write to ${path} as $(id -u):$(id -g) — the AWS CLI would fail to cache credentials under --aws"
    fi
  fi
}

# --mistral has no config path, so it can't ride check_credentials' shape.
# smoke.sh exports MISTRAL_API_KEY for every cell, so its absence without the
# flag proves run.sh forwards it only under --mistral; with the flag, the value
# must be smoke's own sentinel.
check_mistral() {
  case ",${EXPECT_OPTINS:-}," in
    *,mistral,*)
      case "${MISTRAL_API_KEY:-}" in
        *SMOKE-SENTINEL-MISTRAL*) pass "optin-mistral-env: MISTRAL_API_KEY carries the smoke sentinel" ;;
        *) fail "optin-mistral-env: MISTRAL_API_KEY missing or not the smoke fixture" ;;
      esac
      ;;
    *)
      if [ -n "${MISTRAL_API_KEY:-}" ]; then
        fail "leak-mistral: MISTRAL_API_KEY is set but opt-in 'mistral' was not granted"
      else
        pass "leak-mistral: MISTRAL_API_KEY not forwarded (opt-in off)"
      fi
      ;;
  esac
}

# --az with VIBE_DOCKER_AZ_CA: the mounted private CA must have made it into
# the system bundle (the entrypoint's update-ca-certificates step), which is
# where vibe (VIBE_ENABLE_SYSTEM_TRUST_STORE=true), git and az read it.
check_az_ca() {
  local ca="$AZ_CA" bundle="$CA_BUNDLE" ca_line=""
  case ",${EXPECT_OPTINS:-}," in
    *,az,*)
      # Line 2 is the first base64 line of the PEM body — unique to this CA.
      # It must be non-empty: grep -F "" matches any bundle.
      if [ -f "$ca" ]; then
        ca_line=$(sed -n 2p "$ca")
      fi
      if [ -n "$ca_line" ] && grep -qF -- "$ca_line" "$bundle" 2>/dev/null; then
        pass "optin-az-ca: mounted CA is in the system trust bundle"
      else
        fail "optin-az-ca: mounted CA missing from $bundle (update-ca-certificates not run?)"
      fi
      ;;
    *)
      if [ -e "$ca" ]; then
        fail "leak-az-ca: $ca present but opt-in 'az' was not granted"
      else
        pass "leak-az-ca: no --az CA mounted (opt-in off)"
      fi
      ;;
  esac
}

# The full tmpfs mask set under /root, by equality: a mask run.sh adds or drops
# without a matching update here (and a spec delta in external-cli-tools) fails
# the cell. Presence checks alone can't catch a dropped glab/tfe mask on a fresh
# volume — the path is empty either way.
check_mask_set() {
  local expected="" actual optins=",${EXPECT_OPTINS:-},"
  if [ "${EXPECT_EPHEMERAL:-0}" = "0" ]; then
    # smoke never passes --gh, so the gh mask is always on.
    expected="/root/.config/gh"
    case "$optins" in *,glab,*) ;; *) expected="$expected /root/.config/glab-cli" ;; esac
    case "$optins" in *,tfe,*)  ;; *) expected="$expected /root/.terraform.d" ;; esac
    case "$optins" in *,az,*)   ;; *) expected="$expected /root/.azure" ;; esac
    case "$optins" in
      *,aws,*) expected="$expected /root/.aws/cli/cache" ;;
      *)       expected="$expected /root/.aws" ;;
    esac
  fi
  # shellcheck disable=SC2086  # word-split of the space-separated list is intended
  expected=$(printf '%s\n' $expected | sort)
  actual=$(awk '$3 == "tmpfs" && ($2 == "/root" || $2 ~ /^\/root\//) { print $2 }' "$PROC_MOUNTS" | sort)
  if [ "$actual" = "$expected" ]; then
    pass "mask-set: tmpfs masks under /root are exactly [$(echo "$expected" | tr "\n" " ")]"
  else
    fail "mask-set: tmpfs masks under /root are [$(echo "$actual" | tr "\n" " ")], expected [$(echo "$expected" | tr "\n" " ")]"
  fi
}

# ---------------------------------------------------------------------------
# 6. Host config parity, and the seeded config.toml
# ---------------------------------------------------------------------------

# smoke.sh puts every parity item, each carrying SMOKE-SENTINEL-PARITY, in the
# fake home: agents/, skills/, prompts/ and AGENTS.md under ~/.vibe, and
# skills/ under ~/.agents. Each must arrive as a read-only copy. The host's
# hooks.toml and its own config.toml sit beside them and must not.
check_host_config() {
  local item path
  for item in .vibe/agents .vibe/skills .vibe/prompts .vibe/AGENTS.md .agents/skills; do
    path="${ROOT_HOME}/${item}"
    if grep -rqF SMOKE-SENTINEL-PARITY "$path" 2>/dev/null; then
      pass "parity-${item}: $path carries the host fixture"
    else
      fail "parity-${item}: $path missing or not the host fixture"
    fi
    assert_write_fails_ro "parity-${item}-ro" "$path"
  done
  if [ -e "${ROOT_HOME}/.vibe/hooks.toml" ]; then
    fail "parity-hooks: host hooks.toml reached the container"
  else
    pass "parity-hooks: host hooks.toml not forwarded"
  fi
  if grep -qF SMOKE-SENTINEL-HOST-CONFIG "${ROOT_HOME}/.vibe/config.toml" 2>/dev/null; then
    fail "parity-host-config: the host's own config.toml reached the container"
  else
    pass "parity-host-config: the host's own config.toml not forwarded"
  fi
}

check_config() {
  local config="${ROOT_HOME}/.vibe/config.toml"
  local mode="${EXPECT_CONFIG:-0}" perms

  if [ "$mode" = "0" ]; then
    # No seed mounted, fresh volumes: the entrypoint must start cleanly
    # without creating one. (The warm no-seed path — a previously persisted
    # config.toml left as-is — is mode=keep below.)
    if [ -e "$config" ]; then
      fail "config-absent: $config exists but no seed was mounted"
    else
      pass "config-absent: no config.toml without a seed"
    fi
    return
  fi

  if [ "$mode" = "keep" ]; then
    # Warm volume, no seed this run: the entrypoint's seed step must not
    # touch the config.toml a previous run persisted. The shared checks
    # below assert it survived with the previous pass's sentinel and is
    # still atomically replaceable.
    if [ -e "$SEED_CONFIG" ]; then
      fail "config-keep: seed present at $SEED_CONFIG but this pass expects none"
    else
      pass "config-keep: no seed mounted this run"
    fi
  fi

  if [ ! -f "$config" ] || [ -L "$config" ]; then
    fail "config-present: $config missing or not a regular file (mode=$mode: seed copy did not run, or a persisted file was lost)"
    return
  fi
  pass "config-present: $config is a regular file"

  if [ "$mode" = "1" ]; then
    perms=$(stat -c '%a' "$config" 2>/dev/null) || perms=""
    assert_eq "config-mode: seeded config.toml is 600" "$perms" "600"
  fi

  # Content must carry the sentinel smoke.sh expects for THIS pass. The warm
  # cell reruns with a rewritten fixture, so matching the pass-specific
  # sentinel proves the entrypoint re-seeded (mode=1) or left the persisted
  # copy alone (mode=keep) — not merely that some config.toml exists.
  local sentinel="${EXPECT_CONFIG_SENTINEL:-}"
  if [ -z "$sentinel" ]; then
    fail "config-content: EXPECT_CONFIG_SENTINEL not set (smoke.sh plumbing regression)"
  elif grep -qF -- "$sentinel" "$config" 2>/dev/null; then
    pass "config-content: config.toml carries expected sentinel '$sentinel'"
  else
    # Size only: config.toml may hold secrets, and this lands in the CI log.
    fail "config-content: '$sentinel' not found in $config ($(wc -c 2>/dev/null < "$config" || echo '<unreadable>') bytes)"
  fi

  # The reason config.toml is copied instead of bind-mounted: vibe saves
  # settings by renaming a temporary file over config.toml, and rename() over a
  # mountpoint fails with EBUSY. Prove the rename path works.
  local tmp="${config}.tmp.smoke"
  if cp "$config" "$tmp" 2>/dev/null && mv "$tmp" "$config" 2>/dev/null; then
    pass "config-rename: tmp-file rename over config.toml succeeds"
  else
    rm -f "$tmp"
    fail "config-rename: cannot atomically replace $config (mountpoint or ownership regression)"
  fi
}

# ---------------------------------------------------------------------------
# 7. vibe itself — runs as the dropped user, with the image's settings
# ---------------------------------------------------------------------------

# The image pins vibe's update and trust-store behaviour through VIBE_*
# variables, which vibe reads after config.toml: they must survive the drop.
check_vibe() {
  assert_eq "vibe-env: VIBE_ENABLE_UPDATE_CHECKS" "${VIBE_ENABLE_UPDATE_CHECKS:-}" "false"
  assert_eq "vibe-env: VIBE_ENABLE_AUTO_UPDATE" "${VIBE_ENABLE_AUTO_UPDATE:-}" "false"
  assert_eq "vibe-env: VIBE_ENABLE_SYSTEM_TRUST_STORE" "${VIBE_ENABLE_SYSTEM_TRUST_STORE:-}" "true"
  local out
  out=$(vibe --version 2>&1) || out="exit $?: $out"
  assert_eq "vibe-version: vibe --version as $(id -u)" "$out" "vibe ${EXPECT_VIBE_VERSION:-<unset>}"
}

# ---------------------------------------------------------------------------
# 8. Robustness — entrypoint reached here, so it did not abort
# ---------------------------------------------------------------------------

check_entrypoint_reached() {
  # If we are executing at all, the entrypoint ran to completion and exec'd us.
  pass "entrypoint-reached: this script is running, entrypoint did not abort"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  set -euo pipefail

  echo "=== assert-in-container starting (UID=$(id -u) GID=$(id -g)) ==="

  check_entrypoint_reached
  check_identity
  check_security
  check_path_order
  check_git_trust
  check_workspace_write
  check_credentials
  check_aws_state_masking
  check_mistral
  check_az_ca
  check_mask_set
  check_host_config
  check_config
  check_vibe

  echo "==="
  echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
  fi
  echo "RESULT: PASS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
