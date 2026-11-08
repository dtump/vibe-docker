#!/usr/bin/env bats
# Unit tests for tests/smoke/assert-in-container.sh; /proc, /root and the CA paths
# point at fixtures under $BATS_TEST_TMPDIR.

setup() {
  # shellcheck source=../smoke/assert-in-container.sh
  source "${BATS_TEST_DIRNAME}/../smoke/assert-in-container.sh"
  ROOT_HOME="${BATS_TEST_TMPDIR}/root"
  PROC_STATUS="${BATS_TEST_TMPDIR}/status"
  PROC_MOUNTS="${BATS_TEST_TMPDIR}/mounts"
  AZ_CA="${BATS_TEST_TMPDIR}/az.crt"
  AUTH_PROXY_CA="${BATS_TEST_TMPDIR}/auth-proxy.crt"
  CA_BUNDLE="${BATS_TEST_TMPDIR}/bundle.crt"
  SEED_CONFIG="${BATS_TEST_TMPDIR}/seed.toml"
  mkdir -p "$ROOT_HOME"
  unset EXPECT_OPTINS EXPECT_EPHEMERAL AWS_PROFILE GITLAB_TOKEN TF_TOKEN_app_terraform_io \
    AZURE_DEVOPS_EXT_PAT MISTRAL_API_KEY EXPECT_CONFIG EXPECT_CONFIG_SENTINEL EXPECT_VIBE_VERSION \
    VIBE_ENABLE_UPDATE_CHECKS VIBE_ENABLE_AUTO_UPDATE VIBE_ENABLE_SYSTEM_TRUST_STORE
  # A writable fixture can't produce EROFS; that check needs a real :ro mount.
  assert_write_fails_ro() { pass "$1: stubbed"; }
}

# --- pass / fail / assert_eq -------------------------------------------------

@test "pass and fail bump their counters" {
  pass a >/dev/null
  pass b >/dev/null
  fail c >/dev/null
  [ "$PASS_COUNT" -eq 2 ]
  [ "$FAIL_COUNT" -eq 1 ]
}

@test "assert_eq passes on equal values" {
  assert_eq lbl x x >/dev/null
  [ "$PASS_COUNT" -eq 1 ] && [ "$FAIL_COUNT" -eq 0 ]
  run assert_eq lbl x x
  [ "$output" = "PASS: lbl: got 'x'" ]
}

@test "assert_eq fails on different values" {
  assert_eq lbl x y >/dev/null
  [ "$PASS_COUNT" -eq 0 ] && [ "$FAIL_COUNT" -eq 1 ]
  run assert_eq lbl x y
  [ "$output" = "FAIL: lbl: expected 'y', got 'x'" ]
}

# --- path_index / assert_path_before -----------------------------------------

@test "path_index finds an entry" {
  PATH=/a:/b:/c run path_index /b
  [ "$output" = 1 ]
}

@test "path_index returns -1 when absent" {
  PATH=/a:/b run path_index /z
  [ "$output" = -1 ]
}

@test "path_index does not match a prefix" {
  PATH=/root/go/bin/foo:/usr/bin run path_index /root/go/bin
  [ "$output" = -1 ]
}

@test "assert_path_before: first missing" {
  PATH=/b run assert_path_before /a /b
  [[ "$output" == "FAIL: path-order: /a is not on PATH"* ]]
}

@test "assert_path_before: second missing" {
  PATH=/a run assert_path_before /a /b
  [[ "$output" == "FAIL: path-order: /b is not on PATH"* ]]
}

@test "assert_path_before: correct order" {
  PATH=/a:/b run assert_path_before /a /b
  [ "$output" = "PASS: path-order: /a (#0) precedes /b (#1)" ]
}

@test "assert_path_before: wrong order" {
  PATH=/b:/a run assert_path_before /a /b
  [[ "$output" == "FAIL: path-order: expected /a before /b"* ]]
}

# --- optin_config_path -------------------------------------------------------

@test "optin_config_path maps every opt-in" {
  [ "$(optin_config_path aws)" = "${ROOT_HOME}/.aws/config:AWS_PROFILE" ]
  [ "$(optin_config_path glab)" = "${ROOT_HOME}/.config/glab-cli:GITLAB_TOKEN" ]
  [ "$(optin_config_path tfe)" = "${ROOT_HOME}/.terraform.d/credentials.tfrc.json:TF_TOKEN_app_terraform_io" ]
  [ "$(optin_config_path az)" = "${ROOT_HOME}/.azure:AZURE_DEVOPS_EXT_PAT" ]
}

@test "optin_config_path is empty for an unknown name" {
  [ -z "$(optin_config_path nope)" ]
}

# --- check_credentials -------------------------------------------------------

@test "check_credentials: nothing granted, nothing present" {
  run check_credentials
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PASS: masked-glab: config path absent"* ]]
  [[ "$output" == *"PASS: leak-glab: GITLAB_TOKEN not forwarded"* ]]
}

@test "check_credentials: granted opt-in with fixture and env passes" {
  mkdir -p "${ROOT_HOME}/.config/glab-cli"
  echo SMOKE-SENTINEL > "${ROOT_HOME}/.config/glab-cli/config.yml"
  : > "$AUTH_PROXY_CA"
  EXPECT_OPTINS=glab,az GITLAB_TOKEN=vibe-docker-proxy AZURE_DEVOPS_EXT_PAT=SMOKE-SENTINEL-pat \
    run check_credentials
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PASS: optin-glab-content"* ]]
  [[ "$output" == *"PASS: optin-glab-env"* ]]
  [[ "$output" == *"PASS: optin-glab-proxy:"* ]]
  [[ "$output" == *"PASS: optin-glab-proxy-ca"* ]]
  [[ "$output" == *"PASS: optin-az-env"* ]]
}

@test "check_credentials: --glab with the real token or no session CA fails" {
  mkdir -p "${ROOT_HOME}/.config/glab-cli"
  echo SMOKE-SENTINEL > "${ROOT_HOME}/.config/glab-cli/config.yml"
  EXPECT_OPTINS=glab GITLAB_TOKEN=glpat-real run check_credentials
  [[ "$output" == *"FAIL: optin-glab-proxy:"* ]]
  [[ "$output" == *"FAIL: optin-glab-proxy-ca"* ]]
}

@test "check_credentials: granted opt-in without fixture or env fails" {
  EXPECT_OPTINS=tfe run check_credentials
  [[ "$output" == *"FAIL: optin-tfe: config path missing"* ]]
  [[ "$output" == *"FAIL: optin-tfe-content"* ]]
  [[ "$output" == *"FAIL: optin-tfe-env"* ]]
}

@test "check_credentials: populated config without its opt-in fails" {
  mkdir -p "${ROOT_HOME}/.azure"
  touch "${ROOT_HOME}/.azure/x"
  run check_credentials
  [[ "$output" == *"FAIL: masked-az: config path unexpectedly populated"* ]]
}

@test "check_credentials: env var leaked without its opt-in fails" {
  GITLAB_TOKEN=leak run check_credentials
  [[ "$output" == *"FAIL: leak-glab: GITLAB_TOKEN is set"* ]]
  [[ "$output" == *"PASS: leak-tfe"* ]]
}

@test "check_credentials leaves IFS alone" {
  EXPECT_OPTINS=aws,glab check_credentials >/dev/null
  [ "$IFS" = $' \t\n' ]
}

# --- check_security ----------------------------------------------------------

status_fixture() {
  printf '%s\n' "CapPrm:	0000000000000000" "CapEff:	0000000000000000" \
    "CapBnd:	00000000000000c5" "NoNewPrivs:	1" "$@" > "$PROC_STATUS"
}

@test "check_security: dropped posture passes" {
  status_fixture "CapAmb:	0000000000000000"
  find() { :; }  # skip the setuid walk over the runner's whole filesystem
  EXPECT_UID=1000 run check_security
  [[ "$output" != *"FAIL: Cap"* ]] && [[ "$output" != *"FAIL: NoNewPrivs"* ]]
  [[ "$output" == *"PASS: CapAmb=0"* ]]
  [[ "$output" == *"PASS: CapBnd+NoNewPrivs"* ]]
}

@test "check_security: a missing Cap field fails instead of aborting" {
  status_fixture
  EXPECT_UID=1000 run bash -c 'set -euo pipefail; source "$1"; PROC_STATUS=$2; find() { :; }; check_security; echo done' _ \
    "${BATS_TEST_DIRNAME}/../smoke/assert-in-container.sh" "$PROC_STATUS"
  [[ "$output" == *"FAIL: CapAmb=0: expected '0000000000000000', got ''"* ]]
  [[ "$output" == *done* ]]
}

# --- check_git_trust ---------------------------------------------------------

# git stands in for the system config and `git init`; git_opens answers per
# path: OUTSIDE for a repo outside the workspace, INSIDE for one under it.
git_trust_stubs() {
  WORKSPACE="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$WORKSPACE"
  SYSTEM_TRUST="$WORKSPACE"$'\n'"$WORKSPACE/*"
  OUTSIDE="fatal: detected dubious ownership in repository at '/tmp/x'"
  INSIDE=ok
  INIT_FAILS=""
  git() {
    case "$1" in
      config) printf '%s\n' "$SYSTEM_TRUST" ;;
      init) [ -z "$INIT_FAILS" ] && mkdir -p "$3" ;;
    esac
  }
  git_opens() {
    case "$1" in "$WORKSPACE"/*) echo "$INSIDE" ;; *) echo "$OUTSIDE" ;; esac
  }
}

@test "check_git_trust: the vouched-for workspace is trusted and a foreign repo refused" {
  git_trust_stubs
  run check_git_trust
  [[ "$output" == *"PASS: git-safe-directory-system: got '$WORKSPACE,$WORKSPACE/*'"* ]]
  [[ "$output" == *"PASS: git-trust: foreign-owned repo outside /workspaces refused"* ]]
  [[ "$output" == *"PASS: git-trust: foreign-owned repo under a trusted workspace opens"* ]]
  [[ "$output" == *"PASS: git-trust: survives an exported GIT_CONFIG_* set"* ]]
  [[ "$output" != *FAIL* ]]
}

@test "check_git_trust: a wider system entry fails" {
  git_trust_stubs
  SYSTEM_TRUST='/workspaces/*'
  run check_git_trust
  [[ "$output" == *"FAIL: git-safe-directory-system"* ]]
}

@test "check_git_trust: a foreign repo outside /workspaces that opens fails" {
  git_trust_stubs
  OUTSIDE=ok
  run check_git_trust
  [[ "$output" == *"FAIL: git-trust: foreign-owned repo outside /workspaces was not refused"* ]]
}

@test "check_git_trust: under EXPECT_RO=1 the workspace repo is skipped" {
  git_trust_stubs
  EXPECT_RO=1 run check_git_trust
  [[ "$output" == *"PASS: git-trust-workspace: skipped (EXPECT_RO=1"* ]]
  [[ "$output" != *"under a trusted workspace"* ]]
}

@test "check_git_trust: a failed git init is a FAIL, not an abort, and leaves no repo" {
  git_trust_stubs
  INIT_FAILS=1
  run bash -c 'set -euo pipefail; source "$1"; '"$(declare -f git_trust_stubs)"'; git_trust_stubs; INIT_FAILS=1; WORKSPACE=$2; check_git_trust; echo done' _ \
    "${BATS_TEST_DIRNAME}/../smoke/assert-in-container.sh" "$WORKSPACE"
  [[ "$output" == *"FAIL: git-trust: could not create a repo outside /workspaces"* ]]
  [[ "$output" == *"FAIL: git-trust: could not create a repo under $WORKSPACE"* ]]
  [[ "$output" == *done* ]]
  [ -z "$(ls -A "$WORKSPACE")" ]
}

# --- check_mask_set ----------------------------------------------------------

# One tmpfs line per mountpoint, plus a non-tmpfs mount under /root to ignore.
write_mounts() {
  : > "$PROC_MOUNTS"
  local m
  for m in "$@"; do echo "tmpfs $m tmpfs rw 0 0" >> "$PROC_MOUNTS"; done
  echo "/dev/vda1 /root/.vibe ext4 rw 0 0" >> "$PROC_MOUNTS"
}

@test "check_mask_set: no opt-ins expects every mask" {
  write_mounts /root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.azure /root/.aws
  run check_mask_set
  [[ "$output" == "PASS: mask-set:"* ]]
}

@test "check_mask_set: aws narrows its mask to the cli cache" {
  export EXPECT_OPTINS=aws,glab
  write_mounts /root/.config/gh /root/.terraform.d /root/.azure /root/.aws/cli/cache
  run check_mask_set
  [[ "$output" == "PASS: mask-set:"* ]]
}

@test "check_mask_set: a dropped mask fails" {
  write_mounts /root/.config/gh /root/.terraform.d /root/.azure /root/.aws
  run check_mask_set
  [[ "$output" == "FAIL: mask-set:"* ]]
}

@test "check_mask_set: an extra mask fails" {
  export EXPECT_EPHEMERAL=1
  write_mounts /root/.aws
  run check_mask_set
  [[ "$output" == "FAIL: mask-set:"* ]]
}

@test "check_mask_set: a mountpoint that only regex-matches is not a mask" {
  EXPECT_EPHEMERAL=1
  # '.' would match any char as an ERE.
  write_mounts /rootxaws
  run check_mask_set
  [[ "$output" == "PASS: mask-set:"* ]]
}

# --- check_aws_state_masking -------------------------------------------------

@test "check_aws_state_masking: ephemeral with no cache passes" {
  EXPECT_EPHEMERAL=1 run check_aws_state_masking
  [[ "$output" == "PASS: ephemeral-aws:"* ]]
}

@test "check_aws_state_masking: ephemeral with a populated cache fails" {
  mkdir -p "${ROOT_HOME}/.aws/cli/cache"
  touch "${ROOT_HOME}/.aws/cli/cache/sts.json"
  EXPECT_EPHEMERAL=1 run check_aws_state_masking
  [[ "$output" == "FAIL: ephemeral-aws:"* ]]
}

@test "check_aws_state_masking: not granted, empty .aws mask passes" {
  mkdir -p "${ROOT_HOME}/.aws"
  run check_aws_state_masking
  [[ "$output" == "PASS: masked-aws-dir:"* ]]
  [[ "$output" != *FAIL* ]]
}

@test "check_aws_state_masking: not granted, populated .aws fails" {
  mkdir -p "${ROOT_HOME}/.aws"
  touch "${ROOT_HOME}/.aws/credentials"
  run check_aws_state_masking
  [[ "$output" == "FAIL: masked-aws-dir: ${ROOT_HOME}/.aws unexpectedly populated (1 entries)" ]]
}

@test "check_aws_state_masking: a missing mask path fails" {
  run check_aws_state_masking
  [[ "$output" == "FAIL: masked-aws-dir: ${ROOT_HOME}/.aws does not exist"* ]]
}

@test "check_aws_state_masking: --aws with an empty, writable cache and config passes" {
  mkdir -p "${ROOT_HOME}/.aws/cli/cache"
  touch "${ROOT_HOME}/.aws/config"
  EXPECT_OPTINS=aws run check_aws_state_masking
  [[ "$output" == *"PASS: aws-cache-masked:"* ]]
  [[ "$output" == *"PASS: aws-cache-masked-scope:"* ]]
  [[ "$output" == *"PASS: aws-cache-writable:"* ]]
  [[ "$output" != *FAIL* ]]
  [ ! -e "${ROOT_HOME}/.aws/cli/cache/__smoke_write_test" ]
}

@test "check_aws_state_masking: --aws with the config hidden fails the scope check" {
  mkdir -p "${ROOT_HOME}/.aws/cli/cache"
  EXPECT_OPTINS=aws run check_aws_state_masking
  [[ "$output" == *"FAIL: aws-cache-masked-scope:"* ]]
}

# --- check_mistral -----------------------------------------------------------

@test "check_mistral: granted, the smoke key passes" {
  EXPECT_OPTINS=aws,mistral MISTRAL_API_KEY=SMOKE-SENTINEL-MISTRAL run check_mistral
  [ "$output" = "PASS: optin-mistral-env: MISTRAL_API_KEY carries the smoke sentinel" ]
}

@test "check_mistral: granted, a missing or foreign key fails" {
  EXPECT_OPTINS=mistral run check_mistral
  [[ "$output" == "FAIL: optin-mistral-env:"* ]]
  EXPECT_OPTINS=mistral MISTRAL_API_KEY=other run check_mistral
  [[ "$output" == "FAIL: optin-mistral-env:"* ]]
}

@test "check_mistral: not granted, no key passes" {
  EXPECT_OPTINS=aws run check_mistral
  [ "$output" = "PASS: leak-mistral: MISTRAL_API_KEY not forwarded (opt-in off)" ]
}

@test "check_mistral: not granted, a forwarded key fails" {
  MISTRAL_API_KEY=SMOKE-SENTINEL-MISTRAL run check_mistral
  [[ "$output" == "FAIL: leak-mistral: MISTRAL_API_KEY is set"* ]]
}

# --- check_az_ca -------------------------------------------------------------

@test "check_az_ca: CA present in the bundle passes" {
  printf '%s\n' "-----BEGIN CERTIFICATE-----" "MIIUNIQUE" > "$AZ_CA"
  printf '%s\n' other MIIUNIQUE > "$CA_BUNDLE"
  EXPECT_OPTINS=az run check_az_ca
  [[ "$output" == *"PASS: optin-az-ca"* ]]
}

@test "check_az_ca: empty CA line 2 does not match any bundle" {
  printf '%s\n' "-----BEGIN CERTIFICATE-----" "" > "$AZ_CA"
  echo anything > "$CA_BUNDLE"
  EXPECT_OPTINS=az run check_az_ca
  [[ "$output" == *"FAIL: optin-az-ca"* ]]
}

@test "check_az_ca: CA line starting with a dash is matched literally" {
  printf '%s\n' "-----BEGIN CERTIFICATE-----" "-v" > "$AZ_CA"
  echo "-v" > "$CA_BUNDLE"
  EXPECT_OPTINS=az run check_az_ca
  [[ "$output" == *"PASS: optin-az-ca"* ]]
}

@test "check_az_ca: a CA without --az fails" {
  : > "$AZ_CA"
  run check_az_ca
  [[ "$output" == "FAIL: leak-az-ca:"* ]]
  rm "$AZ_CA"
  run check_az_ca
  [[ "$output" == "PASS: leak-az-ca:"* ]]
}

# --- check_host_config -------------------------------------------------------

parity_fixture() {
  mkdir -p "$ROOT_HOME/.vibe/agents" "$ROOT_HOME/.vibe/skills/s" "$ROOT_HOME/.vibe/prompts" \
    "$ROOT_HOME/.agents/skills/s"
  echo SMOKE-SENTINEL-PARITY > "$ROOT_HOME/.vibe/agents/a.toml"
  echo SMOKE-SENTINEL-PARITY > "$ROOT_HOME/.vibe/skills/s/SKILL.md"
  echo SMOKE-SENTINEL-PARITY > "$ROOT_HOME/.vibe/prompts/p.md"
  echo SMOKE-SENTINEL-PARITY > "$ROOT_HOME/.vibe/AGENTS.md"
  echo SMOKE-SENTINEL-PARITY > "$ROOT_HOME/.agents/skills/s/SKILL.md"
}

@test "check_host_config: every item present, no hooks or host config passes" {
  parity_fixture
  run check_host_config
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PASS: parity-.agents/skills:"* ]]
  [[ "$output" == *"PASS: parity-.vibe/AGENTS.md-ro: stubbed"* ]]
  [[ "$output" == *"PASS: parity-hooks:"* ]]
  [[ "$output" == *"PASS: parity-host-config:"* ]]
}

@test "check_host_config: a missing item fails" {
  parity_fixture
  rm -r "$ROOT_HOME/.agents"
  run check_host_config
  [[ "$output" == *"FAIL: parity-.agents/skills:"* ]]
}

@test "check_host_config: forwarded hooks or host config.toml fail" {
  parity_fixture
  : > "$ROOT_HOME/.vibe/hooks.toml"
  echo '# SMOKE-SENTINEL-HOST-CONFIG' > "$ROOT_HOME/.vibe/config.toml"
  run check_host_config
  [[ "$output" == *"FAIL: parity-hooks:"* ]]
  [[ "$output" == *"FAIL: parity-host-config:"* ]]
}

# --- check_config ------------------------------------------------------------

seeded() {
  mkdir -p "${ROOT_HOME}/.vibe"
  printf '%s\n' "$1" > "${ROOT_HOME}/.vibe/config.toml"
  chmod "${2:-600}" "${ROOT_HOME}/.vibe/config.toml"
}

@test "check_config: a seeded 600 copy with the sentinel passes" {
  seeded '# want'
  EXPECT_CONFIG=1 EXPECT_CONFIG_SENTINEL=want run check_config
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PASS: config-mode: seeded config.toml is 600"* ]]
  [[ "$output" == *"PASS: config-rename"* ]]
}

@test "check_config: a seeded copy with the wrong mode fails" {
  seeded '# want' 644
  EXPECT_CONFIG=1 EXPECT_CONFIG_SENTINEL=want run check_config
  [[ "$output" == *"FAIL: config-mode: seeded config.toml is 600: expected '600', got '644'"* ]]
}

@test "check_config: a symlink is not a seeded copy" {
  mkdir -p "${ROOT_HOME}/.vibe"
  echo '# want' > "${BATS_TEST_TMPDIR}/elsewhere"
  ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${ROOT_HOME}/.vibe/config.toml"
  EXPECT_CONFIG=1 EXPECT_CONFIG_SENTINEL=want run check_config
  [[ "$output" == "FAIL: config-present:"* ]]
}

@test "check_config: sentinel mismatch reports size, not content" {
  seeded 'api_key = "secret"'
  EXPECT_CONFIG=1 EXPECT_CONFIG_SENTINEL=want run check_config
  [[ "$output" == *"FAIL: config-content"*"19 bytes"* ]]
  [[ "$output" != *secret* ]]
}

@test "check_config: sentinel starting with a dash is matched literally" {
  seeded '# -v'
  EXPECT_CONFIG=1 EXPECT_CONFIG_SENTINEL=-v run check_config
  [[ "$output" == *"PASS: config-content"* ]]
  [[ "$output" == *"PASS: config-rename"* ]]
}

@test "check_config: no seed on fresh volumes passes when nothing was seeded" {
  EXPECT_CONFIG=0 run check_config
  [ "$output" = "PASS: config-absent: no config.toml without a seed" ]
}

@test "check_config: no seed but a config.toml fails" {
  seeded '# x'
  EXPECT_CONFIG=0 run check_config
  [[ "$output" == "FAIL: config-absent:"* ]]
}

@test "check_config: keep passes on a persisted file with no seed" {
  seeded '# V2' 644
  EXPECT_CONFIG=keep EXPECT_CONFIG_SENTINEL=V2 run check_config
  [[ "$output" == *"PASS: config-keep: no seed mounted this run"* ]]
  [[ "$output" == *"PASS: config-content:"* ]]
  [[ "$output" != *FAIL* ]]
}

@test "check_config: keep fails when a seed is mounted" {
  seeded '# V2'
  echo '# x' > "$SEED_CONFIG"
  EXPECT_CONFIG=keep EXPECT_CONFIG_SENTINEL=V2 run check_config
  [[ "$output" == *"FAIL: config-keep: seed present at ${SEED_CONFIG}"* ]]
}

@test "check_config: keep fails when the persisted file is gone" {
  EXPECT_CONFIG=keep EXPECT_CONFIG_SENTINEL=V2 run check_config
  [[ "$output" == *"FAIL: config-present:"* ]]
}

# --- check_vibe --------------------------------------------------------------

@test "check_vibe: image env and the pinned version pass" {
  vibe() { echo "vibe 3.1.0"; }
  VIBE_ENABLE_UPDATE_CHECKS=false VIBE_ENABLE_AUTO_UPDATE=false VIBE_ENABLE_SYSTEM_TRUST_STORE=true \
    EXPECT_VIBE_VERSION=3.1.0 run check_vibe
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PASS: vibe-version"* ]]
}

@test "check_vibe: a wrong version, a failing vibe or missing env fail" {
  vibe() { echo "vibe 3.0.0"; }
  EXPECT_VIBE_VERSION=3.1.0 run check_vibe
  [[ "$output" == *"FAIL: vibe-env: VIBE_ENABLE_UPDATE_CHECKS"* ]]
  [[ "$output" == *"FAIL: vibe-version"*"got 'vibe 3.0.0'"* ]]
  vibe() { echo boom >&2; return 3; }
  EXPECT_VIBE_VERSION=3.1.0 run check_vibe
  [[ "$output" == *"FAIL: vibe-version"*"got 'exit 3: boom'"* ]]
}

# --- main --------------------------------------------------------------------

# Stub every check but check_config with a passing one.
stub_checks() {
  check_entrypoint_reached() { pass c1; }
  check_identity() { pass c2; }
  check_security() { pass c3; }
  check_path_order() { pass c4; }
  check_git_trust() { pass c4b; }
  check_workspace_write() { pass c5; }
  check_credentials() { pass c6; }
  check_aws_state_masking() { pass c7; }
  check_mistral() { pass c8; }
  check_az_ca() { pass c8b; }
  check_mask_set() { pass c9; }
  check_host_config() { pass c10; }
  check_vibe() { pass c11; }
}

@test "main exits 1 with RESULT: FAIL when any check fails" {
  stub_checks
  check_config() { fail config; }
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"Results: 13 passed, 1 failed"* ]]
  [[ "$output" == *"RESULT: FAIL" ]]
  [[ "$output" != *"RESULT: PASS"* ]]
}

@test "main exits 0 with RESULT: PASS when every check passes" {
  stub_checks
  check_config() { pass config; }
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: PASS" ]]
}
