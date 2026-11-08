#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis

# Override via VIBE_DOCKER_IMAGE so child images (FROM mistral-vibe:local) can
# reuse this wrapper's full feature set — credential opt-ins, git-identity
# forwarding, host-config bind-mounts — without forking it.
IMAGE="${VIBE_DOCKER_IMAGE:-mistral-vibe:local}"

# Auth-proxy sidecar image (Caddy), used by --gh / --glab when a host token is
# found (see openspec/specs/gh-auth-proxy).
# Digest-pinned and deliberately excluded from update_pins.py: a Caddy
# upgrade can change Caddyfile directive semantics — i.e. this
# security-critical config — so bumping it is a reviewed change (changelog +
# config-compatibility check), not a routine automated bump. run.sh cannot
# read pins/, so the pin lives here.
PROXY_IMAGE="${VIBE_DOCKER_PROXY_IMAGE:-caddy:2.11.4@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9}"

# Keep this in sync with the flag-parsing case statement below — adding or
# removing a wrapper flag means updating both the case branch and this heredoc
# in the same diff.
print_help() {
  cat <<'EOF'
Usage: vibe-docker [OPTIONS] [WORKSPACE...] [-- VIBE_FLAGS...]

Hardened Docker wrapper for Mistral Vibe. Wrapper flags and workspace paths
are parsed before `--`; anything after `--` is forwarded verbatim to the
`vibe` binary inside the container.

Workspaces:
  WORKSPACE...        One or more host directories to mount at
                      /workspaces/<basename>. Defaults to $PWD when omitted.
                      First workspace becomes the container's working dir;
                      every additional workspace is passed to vibe as
                      --add-dir so the agent can read/write across all of them.

Wrapper flags:
  -h, --help          Print this help and exit 0 without starting Docker.
  --yolo              Pass --auto-approve to vibe: every tool call runs
                      without asking.
  --ephemeral         Skip the vibe-root/vibe-home named volumes. No Mistral
                      key from the setup wizard, gh login, shell history,
                      trusted-folder answer, or session history persists
                      across runs.
  --ro                Mount every workspace read-only (review / audit mode).
  --ro=PATH           Add PATH as a workspace mounted read-only; the others
                      keep their mode. Repeatable; counts as a workspace, so
                      pass . too to keep $PWD (`. --ro=../lib`). Not a
                      sandbox for untrusted content: the agent can still
                      write what it reads there into the writable workspaces.
  --mistral           Forward the host's MISTRAL_API_KEY into the container,
                      so vibe skips its setup wizard. The session can read
                      the key. Requires MISTRAL_API_KEY set (non-empty).
                      Without this flag the key is never forwarded; vibe
                      then uses the key its setup wizard saved in the
                      vibe-home volume, or asks for one.
  --aws               Opt in to AWS: mount ~/.aws/config + ~/.aws/sso (:ro)
                      and forward AWS_PROFILE / AWS_REGION /
                      AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
                      AWS_SESSION_TOKEN when set.
  --gh                Opt in to GitHub via a per-session auth-proxy sidecar:
                      gh/git reach GitHub through a proxy that injects the
                      real token in transit. The agent container never sees
                      it — GH_TOKEN / `gh auth token` return a placeholder.
                      In-container gh login state stays masked while the
                      sidecar is active. Requires a host GitHub token (env
                      or `gh auth token`); silently behaves like today's
                      --gh with no sidecar if none is found. Mutually
                      exclusive with --gh-direct. Env overrides:
                      VIBE_DOCKER_PROXY_IMAGE (sidecar image),
                      VIBE_DOCKER_GH_POLICY (Caddyfile policy snippet).
  --gh-direct         Legacy GitHub opt-in: forward GH_TOKEN / GITHUB_TOKEN
                      straight into the agent container (no sidecar, no
                      token isolation) and unmask in-container gh login
                      state. For custom-hostname GitHub (Enterprise Server /
                      *.ghe.com) or hosts that can't run the sidecar.
                      Mutually exclusive with --gh.
  --glab              Opt in to GitLab via the auth-proxy sidecar: the
                      token (GITLAB_TOKEN, else host glab's stored token for
                      GITLAB_HOST or the repo's origin host, keyring
                      included) stays in the sidecar, which injects it for
                      that one host; the agent gets GITLAB_TOKEN as a
                      placeholder. Mounts glab-cli config (:ro, tokens
                      blanked), forwards GITLAB_HOST, unmasks in-container
                      glab state. Policy: VIBE_DOCKER_GLAB_POLICY.
                      Mutually exclusive with --glab-direct.
  --glab-direct       Like --glab, but forward the real GITLAB_TOKEN into the
                      agent container (no sidecar). For GitLab hosts the
                      proxy can't serve: plain http, an IP address, a
                      private-CA upstream. Mutually exclusive with --glab.
  --tfe               Opt in to Terraform Cloud (app.terraform.io): mount
                      ~/.terraform.d/credentials.tfrc.json (:ro) when
                      present and forward TF_TOKEN_app_terraform_io;
                      unmask in-container `terraform login` state.
  --az                Opt in to Azure DevOps (Services or on-prem Server):
                      forward AZURE_DEVOPS_EXT_PAT (the PAT) and
                      AZURE_DEVOPS_ORG_URL (default org, and so the host) when
                      set; unmask in-container ~/.azure state. Mounts no
                      host ~/.azure file (no profile, no token caches). Covers
                      az devops / repos / boards / pipelines only.
                      Optional private CA via VIBE_DOCKER_AZ_CA.
  --registry          Opt in to private package registries: surface host-
                      native uv/npm/pnpm/pip config so in-container installs
                      resolve against a private feed. Mounts ~/.npmrc,
                      ~/.config/uv/uv.toml, and pip.conf (:ro) when present and
                      forwards UV_INDEX_* / npm_config_registry / PIP_* env
                      when set. Runtime only; the image build is unaffected.
                      ~/.netrc is NOT mounted (too broad); npmrc and pip.conf
                      are whole-file mounts, so scope them to the registry.
                      See docs/auth.md, "Private package registries".
  --iterm             Wrap vibe in tmux -CC (iTerm2 control mode → native
                      panes). Equivalent to VIBE_DOCKER_TMUX=cc.
  --tmux              Wrap vibe in plain tmux (works in any terminal; Shift+
                      Enter inserts a newline). Equivalent to VIBE_DOCKER_TMUX=1.
  --vibe-dir=PATH     Use PATH as the host Vibe config dir instead of
                      ~/.vibe. Affects agents, skills, prompts, AGENTS.md and
                      config.docker.toml. Env: VIBE_DOCKER_CONFIG_DIR.

Separator:
  --                  Ends wrapper-flag parsing. Everything after is passed
                      to `vibe`, e.g. `vibe-docker ~/repo -- --resume`.
                      Resume a past session with `-- --resume` (picker),
                      `-- --resume <session-id>` or `-- --continue` (latest);
                      trust the workspace for one session with `-- --trust`;
                      run one prompt and exit with `-- -p "prompt"`.

Environment:
  VIBE_DOCKER_TMUX         1  → plain tmux wrapper (same as --tmux).
                           cc → tmux -CC iTerm2 control mode (same as
                           --iterm).
  VIBE_DOCKER_IMAGE        Override the image tag (default: mistral-vibe:local).
                           Used by child images that extend this one and want to
                           reuse this wrapper.
  VIBE_DOCKER_CONFIG_DIR   Override the host Vibe config dir (same as
                           --vibe-dir=PATH).
  VIBE_DOCKER_RUNTIME      Container engine to invoke: docker or podman. Unset
                           (default) auto-detects, preferring docker then
                           podman. This is the canonical way to force an engine
                           and works in scripts, CI, and non-interactive shells.
  VIBE_DOCKER_PROXY_IMAGE  Override the digest-pinned Caddy image used by the
                           --gh / --glab auth-proxy sidecar.
  VIBE_DOCKER_GH_POLICY    Path to a Caddyfile snippet imported into the --gh
                           sidecar's api.github.com site block, to extend the
                           default request-filtering policy.
  VIBE_DOCKER_GLAB_POLICY  Path to a Caddyfile snippet imported into the
                           --glab sidecar's GitLab site block, to extend the
                           default request-filtering policy.
  VIBE_DOCKER_AZ_CA        Path to a PEM CA certificate for an on-prem Azure
                           DevOps Server; installed into the container's trust
                           store, so trusted for all TLS. Ignored without --az.
  VIBE_DOCKER_ADD_HOSTS    Static host entries for networks without DNS, as
                           host:ip[,host:ip...], e.g.
                           gitlab.example.com:10.1.2.3. Added to the
                           container's /etc/hosts (and the auth-proxy sidecar's).
  MISTRAL_API_KEY          Forwarded into the container under --mistral only.

Credentials are off by default; combine opt-ins as needed:
  vibe-docker --aws --gh ~/repo

Git identity (user.name, user.email) is forwarded automatically from the
host's global git config as GIT_AUTHOR_* / GIT_COMMITTER_* env vars so
in-container `git commit` works without a `-c user.email=...` override.
Not gated: identity is already public on every commit you've ever made.
Signing, credential helpers, and hooks are NOT forwarded.

If <config-dir>/config.docker.toml exists it is copied to config.toml in
the container at startup — writable in-session, re-seeded from the host file
on every run; the host's own config.toml is never forwarded. Without it the
container keeps the config.toml earlier sessions saved in the vibe-home volume.
EOF
}

# Wrapper flags and workspace paths before `--`; verbatim vibe flags after.
# See `print_help` above or `vibe-docker --help` for the flag list.
WORKSPACES=()
# Parallel to WORKSPACES: 1 for a workspace passed as --ro=PATH. A missing
# entry reads as 0, so callers may set WORKSPACES alone.
WORKSPACES_RO=()
VIBE_FLAGS=()
EPHEMERAL=0
RO_WORKSPACES=0
WITH_AWS=0
WITH_GH=0
WITH_GH_DIRECT=0
WITH_GLAB=0
WITH_GLAB_DIRECT=0
WITH_TFE=0
WITH_AZ=0
WITH_REGISTRY=0
WITH_MISTRAL=0
# Flat key/value pairs, emitted as GIT_CONFIG_* env by build_git_config.
GIT_CFG=()
VIBE_CONFIG_DIR="${VIBE_DOCKER_CONFIG_DIR:-$HOME/.vibe}"
MOUNT_ARGS=()
# COLORTERM next to TERM: without it vibe's TUI falls back to 256 colours in
# the container and theme colours render rounded (host-config-parity).
ENV_ARGS=(-e TERM -e COLORTERM)
CONTAINER_PATHS=()
SEEN_NAMES=()
SEEN_PATHS=()
CWD=""
CMD=()
IS_MSYS=0
APPDATA_DIR=""
HOST_UID=""
HOST_GID=""
RUNTIME=""
stage=""
GLAB_SRC=""
AUTH_PROXY_NETWORK=""
AUTH_PROXY_SIDECAR=""
GH_HOST_TOKEN=""
GH_SIDECAR_ACTIVE=0
GLAB_HOST_TOKEN=""
GLAB_PROXY_HOST=""
GLAB_SIDECAR_ACTIVE=0
ADD_HOSTS=()
proxy_sid=""
proxy_ip=""

parse_args() {
  local arg path saw_sep=0
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then saw_sep=1; continue; fi
    if [ "$saw_sep" = "1" ]; then
      VIBE_FLAGS+=("$arg"); continue
    fi
    case "$arg" in
      -h|--help)      print_help; exit 0 ;;
      --yolo)         VIBE_FLAGS+=("--auto-approve") ;;
      --ephemeral)    EPHEMERAL=1 ;;
      --ro)           RO_WORKSPACES=1 ;;
      --ro=*)
        path="${arg#--ro=}"
        if [ -z "$path" ]; then
          echo "vibe-docker: --ro= needs a path (--ro=PATH), or use --ro for every workspace" >&2; exit 1
        fi
        # The shell does not tilde-expand after `--ro=`; same "~/" rule as VIBE_CONFIG_DIR below.
        # shellcheck disable=SC2088  # literal "~/" is the intended case pattern
        case "$path" in "~/"*) path="$HOME/${path#\~/}" ;; esac
        WORKSPACES+=("$path"); WORKSPACES_RO+=(1) ;;
      --aws)          WITH_AWS=1 ;;
      --gh)           WITH_GH=1 ;;
      --gh-direct)    WITH_GH_DIRECT=1 ;;
      --glab)         WITH_GLAB=1 ;;
      --glab-direct)  WITH_GLAB_DIRECT=1 ;;
      --tfe)          WITH_TFE=1 ;;
      --az)           WITH_AZ=1 ;;
      --registry)     WITH_REGISTRY=1 ;;
      --mistral)      WITH_MISTRAL=1 ;;
      --iterm)        VIBE_DOCKER_TMUX=cc ;;
      --tmux)         VIBE_DOCKER_TMUX=1 ;;
      --vibe-dir=*)   VIBE_CONFIG_DIR="${arg#--vibe-dir=}" ;;
      -*)             echo "vibe-docker: unknown flag '$arg' (use -- to pass flags to vibe)" >&2; exit 1 ;;
      *)              WORKSPACES+=("$arg"); WORKSPACES_RO+=(0) ;;
    esac
  done
  if [ "${#WORKSPACES[@]}" -eq 0 ]; then WORKSPACES=("$PWD"); WORKSPACES_RO=(0); fi

  # Expand a leading ~/ in VIBE_CONFIG_DIR — needed when set via env var, where
  # the shell does not perform tilde expansion. Pattern is "~/" not "~" so a
  # user-tilde form like "~alice/path" is not silently misresolved as "$HOME/alice/path".
  # shellcheck disable=SC2088  # literal "~/" is the intended case pattern, not a tilde-expansion target
  case "$VIBE_CONFIG_DIR" in "~/"*) VIBE_CONFIG_DIR="$HOME/${VIBE_CONFIG_DIR#\~/}" ;; esac
  return 0
}

validate_opts() {
  # --gh (auth-proxy sidecar) and --gh-direct (legacy forwarding) are mutually
  # exclusive strategies for the same credential — picking one silently would
  # hide the other's risk profile from the user, so reject the combination
  # outright (same exit style as the unknown-flag case above).
  if [ "$WITH_GH" = "1" ] && [ "$WITH_GH_DIRECT" = "1" ]; then
    echo "vibe-docker: --gh and --gh-direct are mutually exclusive — pick the auth-proxy sidecar (--gh) or legacy token forwarding (--gh-direct)" >&2
    exit 1
  fi
  if [ "$WITH_GLAB" = "1" ] && [ "$WITH_GLAB_DIRECT" = "1" ]; then
    echo "vibe-docker: --glab and --glab-direct are mutually exclusive — pick the auth-proxy sidecar (--glab) or direct token forwarding (--glab-direct)" >&2
    exit 1
  fi

  # --mistral forwards the host's MISTRAL_API_KEY by name. Unset or empty is an
  # error, not a silent skip: vibe would otherwise fall back to the key in the
  # vibe-home volume or start its setup wizard, and the user asked for this
  # key. Empty counts as unset, so a failed `$(helper)` / `op read` stops here
  # too, before any container starts.
  if [ "$WITH_MISTRAL" = "1" ] && [ -z "${MISTRAL_API_KEY:-}" ]; then
    echo "vibe-docker: --mistral needs MISTRAL_API_KEY set (non-empty) in the host environment" >&2
    exit 1
  fi

  # --az private CA, e.g. for an on-prem Azure DevOps Server. Its own variable, not
  # the host's REQUESTS_CA_BUNDLE, since that is often set for unrelated reasons
  # and this CA ends up trusted for all TLS in the container. It is mounted and
  # installed below rather than forwarded. A set-but-missing path is fatal:
  # skipping it would fail later at the first TLS handshake.
  if [ "$WITH_AZ" = "1" ] && [ -n "${VIBE_DOCKER_AZ_CA:-}" ] && [ ! -f "$VIBE_DOCKER_AZ_CA" ]; then
    echo "vibe-docker: VIBE_DOCKER_AZ_CA '$VIBE_DOCKER_AZ_CA' is not a file" >&2
    exit 1
  fi

  # --gh sidecar policy. A set-but-unreadable path is fatal, like the CA paths:
  # staging an empty policy instead would run the sidecar without the
  # restrictions the user asked for.
  if [ "$WITH_GH" = "1" ] && [ -n "${VIBE_DOCKER_GH_POLICY:-}" ] \
     && { [ ! -f "$VIBE_DOCKER_GH_POLICY" ] || [ ! -r "$VIBE_DOCKER_GH_POLICY" ]; }; then
    echo "vibe-docker: VIBE_DOCKER_GH_POLICY '$VIBE_DOCKER_GH_POLICY' is not a readable file" >&2
    exit 1
  fi
  if [ "$WITH_GLAB" = "1" ] && [ -n "${VIBE_DOCKER_GLAB_POLICY:-}" ] \
     && { [ ! -f "$VIBE_DOCKER_GLAB_POLICY" ] || [ ! -r "$VIBE_DOCKER_GLAB_POLICY" ]; }; then
    echo "vibe-docker: VIBE_DOCKER_GLAB_POLICY '$VIBE_DOCKER_GLAB_POLICY' is not a readable file" >&2
    exit 1
  fi

  # Static host:ip entries for networks without DNS for the forges: the runtime
  # regenerates /etc/hosts at start, so --add-host is the only way in. Checked
  # here so a typo fails now, not as a resolution error mid-session.
  local entry
  IFS=, read -ra ADD_HOSTS <<<"${VIBE_DOCKER_ADD_HOSTS:-}"
  for entry in ${ADD_HOSTS[@]+"${ADD_HOSTS[@]}"}; do
    if ! [[ "$entry" =~ ^[A-Za-z0-9.-]+:[0-9A-Fa-f.:]+$ ]]; then
      echo "vibe-docker: VIBE_DOCKER_ADD_HOSTS entry '$entry' is not host:ip" >&2
      exit 1
    fi
  done
}

select_runtime() {
  # Select the container runtime AFTER flag parsing: `-h`/`--help` is handled in
  # the loop above and has already exited 0 by now, so this never blocks help on
  # an engine-less host; and a real run on such a host fails here — before any
  # mktemp/cp staging below. VIBE_DOCKER_RUNTIME is the canonical override (works
  # in scripts/CI/editors/non-interactive shells); empty means auto-detect.
  RUNTIME="${VIBE_DOCKER_RUNTIME:-}"
  # Allowlist the override — it names the binary invoked as `"$RUNTIME" run` at the
  # end of this script, so we must never hand `run …` to an arbitrary on-PATH
  # binary. Empty is allowed and means "auto-detect".
  case "$RUNTIME" in
    ""|docker|podman) ;;
    *) echo "vibe-docker: VIBE_DOCKER_RUNTIME must be 'docker' or 'podman', got '$RUNTIME'" >&2; exit 1 ;;
  esac
  if [ -z "$RUNTIME" ]; then
    if   command -v docker >/dev/null 2>&1; then RUNTIME=docker
    elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
    else echo "vibe-docker: no container runtime found — install docker or podman, or set VIBE_DOCKER_RUNTIME" >&2; exit 1
    fi
  elif ! command -v "$RUNTIME" >/dev/null 2>&1; then
    echo "vibe-docker: requested runtime '$RUNTIME' not found on PATH" >&2; exit 1
  fi
}

prune_stale_auth_proxy() {
  local stale_cid stale_nid
  # Best-effort prune of auth-proxy resources stranded by a prior run.sh that
  # died before its EXIT trap could run — the trap installed below (right after
  # this session's own stage dir exists) is the primary teardown path; this is
  # only insurance. Containers: STOPPED states only (exited/created/dead) — a
  # running vibe-auth-proxy-* almost certainly belongs to a concurrent live
  # session, and `rm -f` would sever its access mid-flight, so running
  # strays (hard-killed run.sh whose sidecar lives on) are deliberately left
  # for manual cleanup; the name prefix makes them easy to spot. Networks:
  # removal of an in-use network fails and is swallowed, so live sessions are
  # safe; an empty network belonging to a session inside its create→sidecar-run
  # window can race and lose, which fails that session closed with a clear
  # error — rare, safe, retry succeeds. Every failure here is swallowed: a
  # stale resource that resists removal must never abort this run.
  "$RUNTIME" ps -aq --filter "name=^vibe-auth-proxy-" \
      --filter "status=exited" --filter "status=created" --filter "status=dead" \
      2>/dev/null | while IFS= read -r stale_cid; do
    [ -z "$stale_cid" ] && continue
    "$RUNTIME" rm -f "$stale_cid" >/dev/null 2>&1 || true
  done || true
  "$RUNTIME" network ls -q --filter "name=^vibe-auth-" 2>/dev/null | while IFS= read -r stale_nid; do
    [ -z "$stale_nid" ] && continue
    "$RUNTIME" network rm "$stale_nid" >/dev/null 2>&1 || true
  done || true
}

detect_msys() {
  # Git Bash / MSYS / Cygwin on Windows rewrites POSIX-looking argv into Windows
  # paths before the native docker.exe/podman.exe sees them, corrupting the
  # container-side paths we pass verbatim (/workspaces/<name>, -w, --add-dir,
  # /root/..., /run/...) into e.g. "\Program Files\Git\workspaces\...". Disable
  # that argv conversion; the host bind-mount *sources* that legitimately need
  # Windows form are translated by hostpath() below, since the shell no longer will.
  IS_MSYS=0
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) IS_MSYS=1 ;;
  esac
  if [ "$IS_MSYS" = "1" ]; then
    export MSYS2_ARG_CONV_EXCL='*'   # MSYS2 / newer Git Bash
    export MSYS_NO_PATHCONV=1        # older Git-for-Windows
  fi

  # Windows keeps per-user app config under %APPDATA% (e.g. terraform.d, pip,
  # uv, glab-cli), not ~/.config. APPDATA arrives in Windows form
  # (C:\Users\...\AppData\Roaming); convert it to the POSIX form the shell's own
  # [ -f ] / [ -d ] tests expect. Empty off-MSYS, so every %APPDATA% lookup
  # is skipped on Linux/macOS.
  APPDATA_DIR=""
  if [ "$IS_MSYS" = "1" ] && [ -n "${APPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
    APPDATA_DIR=$(cygpath -u "$APPDATA")
  fi

  # Identity the entrypoint drops to. On Windows there is no POSIX ownership to
  # preserve: Git Bash's id -u/-g are synthetic SID-derived values (e.g. 197609)
  # that fall outside rootless podman's 65536-ID subordinate range, and NTFS bind
  # mounts show every file as container root anyway. Use the conventional first
  # user UID instead — still non-root, so the privilege drop is unchanged.
  if [ "$IS_MSYS" = "1" ]; then
    HOST_UID=1000
    HOST_GID=1000
    # Those same root-owned NTFS mounts would trip git's ownership check;
    # build_git_trust has the entrypoint trust every workspace on Windows.
  else
    HOST_UID=$(id -u)
    HOST_GID=$(id -g)
  fi
}

# Translate a host path to the form the native engine accepts as a bind-mount
# source. Under MSYS, cygpath -m turns /c/Users/foo into C:/Users/foo (drive
# letter + forward slashes, which docker/podman parse correctly). Off-MSYS (or
# if cygpath is somehow absent) it is the identity function, so the Linux/macOS
# argv is byte-for-byte unchanged from the hardcoded-docker behaviour.
hostpath() {
  if [ "$IS_MSYS" = "1" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# Reading host files a session can write. Every workspace is writable from the
# container, so a session can plant a symlink there, or swap one in while a
# later launch runs, to make that launch copy another host file (an SSH key, a
# cloud credential) into its container. [ -L ] then cp is not enough: the link
# can appear between the two. Below a starting directory the caller trusts,
# the helpers follow no link, and pin what they checked: each directory is
# entered and then checked to be the inode lstat named, so the shell's cwd
# holds it; each file is opened and then checked to be the inode lstat names.
# lstat of a link is the link's own inode, never its target's, so a swap at any
# point fails the check. Hard links are no way round it: the session can't name
# a host file outside its workspaces to link to. The starting directory and its
# parents are resolved normally; docs/security.md states what that leaves open.

# dev:inode of $1, following links (GNU stat, else BSD/macOS stat).
file_id() { stat -L -c '%d:%i' "$1" 2>/dev/null || stat -L -f '%d:%i' "$1" 2>/dev/null; }
# dev:inode of $1 itself (lstat).
link_id() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null; }
# macOS reports /dev/fd/N on the fdesc device with the file's inode, so there the
# open file is matched by inode alone; elsewhere by dev:inode. Set by init_shell.
FD_INODE_ONLY=0

# Process-wide settings, before anything else in main.
init_shell() {
  # An exported CDPATH makes `cd` to a relative directory print that directory
  # on stdout, which would land in the files staged from `( cd dir && cat … )`.
  unset CDPATH
  [ "$(uname -s 2>/dev/null)" = Darwin ] && FD_INODE_ONLY=1
  return 0
}

# Print ./$1, in the current directory, if it is a regular file and, once open,
# still the file lstat names. Opens it on fd 9 of the calling shell. A FIFO
# swapped in between the -f test and the open would block that open: a hang,
# not a leak, and bash has no portable non-blocking open.
cat_checked() {
  local fd id
  [ -f "./$1" ] && [ ! -L "./$1" ] || return 1
  exec 9<"./$1" || return 1
  if fd=$(file_id /dev/fd/9) && id=$(link_id "./$1") \
     && { [ "$fd" = "$id" ] || { [ "$FD_INODE_ONLY" = 1 ] && [ "${fd#*:}" = "${id#*:}" ]; }; }; then
    cat <&9
    fd=$?
  else
    fd=1
  fi
  exec 9<&-
  return "$fd"
}

# Print file $2, a relative path under directory $1, following no symlink in $2.
# $1 itself is resolved normally. Prints nothing and fails on any mismatch.
cat_nofollow() {
  (
    cd -- "$1" || exit 1
    rest=$2
    while :; do
      case $rest in
        */*)
          comp=${rest%%/*}
          rest=${rest#*/}
          id=$(link_id "./$comp") && cd "./$comp" && [ "$(file_id .)" = "$id" ] || exit 1
          ;;
        *) break ;;
      esac
    done
    cat_checked "$rest"
  ) 2>/dev/null
}

# Resolve one symlink hop the user made: print $1's target when $1 is a link
# whose target exists and is not itself a link, or $1 when it is no link.
# Further hops are refused, because the next link may sit in a workspace.
# Trailing slashes are stripped first ([ -L dir/ ] looks through a link), and a
# target ending in . or .. is refused.
one_hop() {
  local p=$1 t
  if [ -L "$p" ]; then
    t=$(readlink "$p") || return 1
    case $t in /*) ;; *) t="$(dirname "$p")/$t" ;; esac
    while :; do
      case $t in
        / | *[!/]) break ;;
        *) t=${t%/} ;;
      esac
    done
    case /$t in */. | */..) return 1 ;; esac
    [ -L "$t" ] && return 1
    p=$t
  fi
  [ -e "$p" ] || return 1
  printf '%s\n' "$p"
}

# True when symlink target $1, in a directory $2 levels below a copy root,
# resolves inside that root: relative, leading ../ only (at most $2 of them),
# then plain names. A .. after a name could climb out through another link.
link_stays_inside() {
  local l=$1 up=$2
  case $l in /* | '') return 1 ;; esac
  while :; do
    case $l in
      ../*) [ "$up" -gt 0 ] || return 1; up=$((up - 1)); l=${l#../} ;;
      ..) [ "$up" -gt 0 ]; return ;;
      *) break ;;
    esac
  done
  case "/$l/" in */../* | */./*) return 1 ;; esac
  return 0
}

# Copy directory $1 to $2 (absolute) without following links inside it. $3=1:
# links directly in $1 are the user's own (skills/foo -> ~/repos/x/skills/foo)
# and get one hop, into a fresh copy root. Otherwise a link is kept as a link
# only if it stays inside its copy root ($4 = depth below it); any other link
# is skipped with a warning. Relative $1 is entered from the current directory,
# which keeps the walk on the directories already checked. A directory that
# fails its identity check is skipped with a warning, never fatal: if a
# platform reports inodes differently, launch loses that item, not the session.
copy_tree_nofollow() {
  local src=$1 dest=$2 hop=$3 depth=$4 shown=$1
  case $src in /*) ;; *) shown="$PWD/${src#./}" ;; esac
  mkdir -p "$dest" || return 1
  (
    if ! id=$(link_id "$src") || ! cd "$src" || [ "$(file_id .)" != "$id" ]; then
      echo "vibe-docker: skipping $shown: it is a link now, or changed while being copied" >&2
      exit 1
    fi
    for e in ./* ./.[!.]* ./..?*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      n=${e#./}
      # A skill linked from a repo root would otherwise carry its whole .git,
      # thousands of files at a few processes each, for nothing in the container.
      [ "$n" = .git ] && continue
      if [ -L "$e" ] && [ "$hop" = 1 ]; then
        if ! t=$(one_hop "$PWD/$n"); then
          echo "vibe-docker: skipping $PWD/$n: a symlink to a symlink, or to nothing" >&2
        elif [ -d "$t" ]; then
          copy_tree_nofollow "$t" "$dest/$n" 0 0 || true
        elif ! cat_nofollow "$(dirname "$t")" "$(basename "$t")" >"$dest/$n"; then
          rm -f "$dest/$n"
          echo "vibe-docker: skipping $PWD/$n: its target changed while being read" >&2
        else
          [ ! -x "$t" ] || chmod +x "$dest/$n"
        fi
      elif [ -L "$e" ]; then
        if ! l=$(readlink "$e"); then
          echo "vibe-docker: skipping $PWD/$n: it changed while being copied" >&2
        elif link_stays_inside "$l" "$depth"; then
          # -- : a relative target may start with -, which ln would read as
          # an option and fail on, dropping the whole directory.
          ln -s -- "$l" "$dest/$n" || exit 1
        else
          echo "vibe-docker: skipping $PWD/$n: a symlink to $l, outside the copied directory" >&2
        fi
      elif [ -d "$e" ]; then
        copy_tree_nofollow "./$n" "$dest/$n" 0 $((depth + 1)) || true
      elif [ -f "$e" ]; then
        if cat_checked "$n" >"$dest/$n" 2>/dev/null; then
          [ ! -x "$e" ] || chmod +x "$dest/$n"
        else
          rm -f "$dest/$n"
          echo "vibe-docker: skipping $PWD/$n: it changed while being read" >&2
        fi
      fi
    done
  ) || { rm -rf "$dest"; return 1; }
}

# Stage host config file $VIBE_CONFIG_DIR/$1 (one hop allowed) as $2. Fails
# quietly when the file is absent; warns when a link or a swap is refused.
stage_config_file() {
  local src="$VIBE_CONFIG_DIR/$1" t
  [ -e "$src" ] || [ -L "$src" ] || return 1
  if t=$(one_hop "$src") && [ -f "$t" ] \
     && cat_nofollow "$(dirname "$t")" "$(basename "$t")" >"$2"; then
    [ ! -x "$t" ] || chmod +x "$2"
    return 0
  fi
  rm -f "$2"
  echo "vibe-docker: skipping $src: not a regular file reached by at most one symlink" >&2
  return 1
}

build_workspace_mounts() {
  local ws_suffix ws abs shown link name n i j k=0

  # Parallel arrays (not associative) so macOS system bash 3.2 works.
  # Counter-based iteration avoids ${!arr[@]} which trips set -u on empty arrays.
  SEEN_NAMES=()
  SEEN_PATHS=()
  SEEN_RO=()
  SEEN_SHOWN=()
  for ws in "${WORKSPACES[@]}"; do
    # Checked up front so a typo gets a vibe-docker: message, not bash's bare `cd:` error.
    if [ ! -d "$ws" ]; then
      echo "vibe-docker: workspace '$ws' is not a directory" >&2
      exit 1
    fi
    # Physical path (pwd -P): the engine follows symlinks in a mount source, so
    # mount what it would really get and name it after that directory. A
    # workspace that is itself a symlink is announced: a session whose
    # workspace holds that link could have pointed it somewhere else. Links
    # higher up (a symlinked /home or /tmp) are common and not announced.
    # Messages name the workspace as given ($shown), symlinks unresolved.
    abs=$(cd -P "$ws" && pwd -P) || exit 1
    shown=$(cd "$ws" && pwd) || exit 1
    # Every trailing slash goes first: `[ -L link/ ]` looks through the link.
    link=$ws
    while [ "${link%/}" != "$link" ] && [ "${link%/}" != "" ]; do link=${link%/}; done
    if [ -L "$link" ]; then
      echo "vibe-docker: workspace '$ws' is a symlink; mounting '$abs'" >&2
    fi
    ws_suffix=""
    { [ "$RO_WORKSPACES" = "1" ] || [ "${WORKSPACES_RO[$k]:-0}" = "1" ]; } && ws_suffix=":ro"
    k=$((k + 1))
    name=$(basename "$abs")
    # Safe: -v/-w/--add-dir all receive the path as a single quoted argv element; only : and empty break docker -v parsing.
    # `/` (or `//`) has basename `/`, which would mount at /workspaces//.
    case "$name" in
      /)   echo "vibe-docker: workspace '$abs' is the filesystem root; pick a directory below it" >&2; exit 1 ;;
      "")  echo "vibe-docker: workspace basename is empty; cannot mount at /workspaces/" >&2; exit 1 ;;
      *:*) echo "vibe-docker: workspace basename '$name' cannot contain ':' (breaks docker -v parsing)" >&2; exit 1 ;;
    esac
    n=${#SEEN_NAMES[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
      # The same directory twice, as the same path or through a symlink: mounts
      # are of the physical path, so both would be one mount. Read-write and
      # read-only at once gets its own message (the :ro would protect nothing).
      if [ "${SEEN_PATHS[$i]}" = "$abs" ]; then
        if [ "${SEEN_SHOWN[$i]}" = "$shown" ]; then
          echo "vibe-docker: workspace '$shown' is given more than once; pass it once, as PATH (read-write) or --ro=PATH (read-only)" >&2
        elif [ "${SEEN_RO[$i]}" != "${ws_suffix:+1}" ]; then
          echo "vibe-docker: workspaces '${SEEN_SHOWN[$i]}' and '$shown' are the same directory, one read-write and one read-only; pass it once" >&2
        else
          echo "vibe-docker: workspaces '${SEEN_SHOWN[$i]}' and '$shown' are the same directory; pass it once" >&2
        fi
        exit 1
      fi
      if [ "${SEEN_NAMES[$i]}" = "$name" ]; then
        echo "vibe-docker: workspace basename collision — '$abs' and '${SEEN_PATHS[$i]}' both map to /workspaces/$name" >&2
        exit 1
      fi
      i=$((i + 1))
    done
    SEEN_NAMES+=("$name")
    SEEN_PATHS+=("$abs")
    SEEN_SHOWN+=("$shown")
    SEEN_RO+=("${ws_suffix:+1}")
    MOUNT_ARGS+=("-v" "$(hostpath "$abs"):/workspaces/$name$ws_suffix")
    CONTAINER_PATHS+=("/workspaces/$name")
  done

  # A read-only workspace inside a writable one stays writable through the
  # writable mount; say so rather than let ro-partial overstate the protection.
  # SEEN_PATHS are physical, so this sees through symlinks.
  n=${#SEEN_PATHS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    j=0
    while [ -n "${SEEN_RO[$i]}" ] && [ "$j" -lt "$n" ]; do
      case "${SEEN_PATHS[$i]}" in
        "${SEEN_PATHS[$j]}"/*)
          [ -z "${SEEN_RO[$j]}" ] && echo "vibe-docker: warning: read-only workspace '${SEEN_SHOWN[$i]}' is inside writable workspace '${SEEN_SHOWN[$j]}', so it stays writable under ${CONTAINER_PATHS[$j]}" >&2 ;;
      esac
      j=$((j + 1))
    done
    i=$((i + 1))
  done
  CWD="${CONTAINER_PATHS[0]}"
}

# Whether host path $1 belongs to the user running vibe-docker. A function
# so the tests can stand in for an owner they can't create.
owned_by_me() { [ -O "$1" ]; }

# Whether git's own directories for workspace $1 are yours: there are none (not
# a repo), or .git is a directory you own, or a pointer file (worktree,
# submodule) you own whose gitdir, and that gitdir's commondir, you own too.
# Host git checks the gitdir as well, but safe.directory in the container is
# matched against the workspace path alone, so the check happens here. A .git
# symlink is refused, as stage_git_overlays refuses it.
git_dirs_owned() {
  local ws="$1" gd cd
  [ -L "$ws/.git" ] && return 1
  [ -e "$ws/.git" ] || return 0
  owned_by_me "$ws/.git" || return 1
  [ -f "$ws/.git" ] || return 0
  gd=$(sed -n 's/^gitdir: //p' "$ws/.git" 2>/dev/null | head -1)
  [ -n "$gd" ] || return 1
  case "$gd" in /*) ;; *) gd="$ws/$gd" ;; esac
  owned_by_me "$gd" || return 1
  [ -f "$gd/commondir" ] || return 0
  cd=$(head -1 "$gd/commondir" 2>/dev/null)
  [ -n "$cd" ] || return 1
  case "$cd" in /*) ;; *) cd="$gd/$cd" ;; esac
  owned_by_me "$cd"
}

# Which mounted workspaces git in the container may trust despite an owner
# mismatch (its safe.directory check). Git refuses a repository whose owner
# differs from the user running it, so that another user's planted hooks or
# core.fsmonitor never run in your session. Inside the container that check
# misfires: Windows NTFS mounts show every file as root's, and Docker Desktop
# on macOS has been seen to report a mismatch for a workspace you own. So the
# host decides: a workspace you own, along with its git directory
# (git_dirs_owned), is passed to the entrypoint, which trusts it in the
# container's system git config, out of the session's reach. A workspace
# another host user owns gets no entry, and git refuses it as it would on the
# host. On Windows ownership means nothing, so every workspace is trusted.
build_git_trust() {
  local n=${#SEEN_PATHS[@]} i j ws trusted="" vouched=() parent
  i=0
  while [ "$i" -lt "$n" ]; do
    ws="${SEEN_PATHS[$i]}"
    vouched[$i]=""
    if [ "$IS_MSYS" = "1" ] || { owned_by_me "$ws" && git_dirs_owned "$ws"; }; then
      vouched[$i]=1
      trusted="${trusted:+$trusted:}${CONTAINER_PATHS[$i]}"
    fi
    i=$((i + 1))
  done
  # A workspace left out is still trusted through a vouched-for one it sits
  # in (<parent>/* covers it), so say which applies. SEEN_PATHS are physical
  # paths, so this sees through symlinks.
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ -z "${vouched[$i]}" ]; then
      parent=""
      j=0
      while [ "$j" -lt "$n" ]; do
        case "${SEEN_PATHS[$i]}" in
          "${SEEN_PATHS[$j]}"/*) [ -n "${vouched[$j]}" ] && parent="${SEEN_PATHS[$j]}" ;;
        esac
        j=$((j + 1))
      done
      if [ -n "$parent" ]; then
        echo "vibe-docker: warning: '${SEEN_PATHS[$i]}' or its git directory belongs to another user, but it sits inside '$parent', so git in the container trusts it anyway; pass it on its own, or leave it out" >&2
      else
        echo "vibe-docker: '${SEEN_PATHS[$i]}' or its git directory belongs to another user, so git in the container won't trust it (its ownership check); mount only repos whose git directory you own" >&2
      fi
    fi
    i=$((i + 1))
  done
  ENV_ARGS+=("-e" "VIBE_DOCKER_TRUSTED_WORKSPACES=$trusted")
}

build_cred_mounts() {
  local tfe_src npmrc_src uv_toml pip_conf
  # File-based host creds. gh uses macOS Keychain → log in inside the container once; persists via vibe-root.
  # glab on macOS lives under ~/Library/Application Support/glab-cli (not XDG), on Windows under %APPDATA%\glab-cli;
  # fall back to ~/.config/glab-cli (Linux, and older glab releases on Windows).
  if [ "$WITH_GLAB" = "1" ] || [ "$WITH_GLAB_DIRECT" = "1" ]; then
    if [ -d "$HOME/Library/Application Support/glab-cli" ]; then
      GLAB_SRC="$HOME/Library/Application Support/glab-cli"
    elif [ -n "$APPDATA_DIR" ] && [ -d "$APPDATA_DIR/glab-cli" ]; then
      GLAB_SRC="$APPDATA_DIR/glab-cli"
    elif [ -d "$HOME/.config/glab-cli" ]; then
      GLAB_SRC="$HOME/.config/glab-cli"
    fi
    [ -n "$GLAB_SRC" ] && MOUNT_ARGS+=("-v" "$(hostpath "$GLAB_SRC"):/root/.config/glab-cli:ro")
  fi

  # Scoped AWS mount: only non-secret config + short-lived SSO bearer cache.
  # Excludes ~/.aws/credentials (long-lived access keys) and ~/.aws/cli/cache
  # (cached assume-role STS). Env-var flow (AWS_ACCESS_KEY_ID/...) still forwards
  # below for users who flatten creds with `aws configure export-credentials`.
  if [ "$WITH_AWS" = "1" ]; then
    [ -f "$HOME/.aws/config" ] && MOUNT_ARGS+=("-v" "$(hostpath "$HOME/.aws/config"):/root/.aws/config:ro")
    [ -d "$HOME/.aws/sso" ]    && MOUNT_ARGS+=("-v" "$(hostpath "$HOME/.aws/sso"):/root/.aws/sso:ro")
  fi

  # Terraform Cloud credentials file written by `terraform login`: at
  # ~/.terraform.d/credentials.tfrc.json on Linux/macOS, and at
  # %APPDATA%\terraform.d\credentials.tfrc.json on Windows. Only
  # app.terraform.io is in scope here; the file format supports other hosts
  # but mounting them is intentional and out of scope for --tfe.
  if [ "$WITH_TFE" = "1" ]; then
    tfe_src=""
    if [ -n "$APPDATA_DIR" ] && [ -f "$APPDATA_DIR/terraform.d/credentials.tfrc.json" ]; then
      tfe_src="$APPDATA_DIR/terraform.d/credentials.tfrc.json"
    elif [ -f "$HOME/.terraform.d/credentials.tfrc.json" ]; then
      tfe_src="$HOME/.terraform.d/credentials.tfrc.json"
    fi
    [ -n "$tfe_src" ] && MOUNT_ARGS+=("-v" "$(hostpath "$tfe_src"):/root/.terraform.d/credentials.tfrc.json:ro")
  fi

  # Azure DevOps: no host ~/.azure file is mounted. Auth is the PAT in
  # AZURE_DEVOPS_EXT_PAT and the host is whatever AZURE_DEVOPS_ORG_URL names
  # (Services or an on-prem Server); azureProfile.json would only carry tenant /
  # subscription IDs and the account name in, and the AAD token caches never are.
  if [ "$WITH_AZ" = "1" ]; then
    # Installed by the entrypoint's update-ca-certificates step (vibe-docker-*.crt),
    # so git/curl trust it too; the az wrapper points requests at the system bundle.
    [ -n "${VIBE_DOCKER_AZ_CA:-}" ] && MOUNT_ARGS+=("-v" "$(hostpath "$VIBE_DOCKER_AZ_CA"):/usr/local/share/ca-certificates/vibe-docker-az.crt:ro")
  fi

  # Private package registries: surface the host's native uv/npm/pnpm/pip registry
  # config read-only so in-container installs resolve against a private feed
  # (CodeArtifact / Artifactory / Nexus / …). Each mount is a silent no-op when the
  # host file is absent. The pip user config dir is platform-specific (macOS keeps
  # it under Application Support, Linux under XDG ~/.config); both map to the
  # container's Linux path /root/.config/pip/pip.conf. Read-only, like every other
  # cred mount. NOTE: ~/.netrc is deliberately NOT mounted — it is a machine-keyed
  # store that routinely holds credentials for hosts unrelated to the registry, so
  # forwarding the whole file into a full-egress container is too broad. Use
  # registry auth that lives in npmrc/pip.conf, the URL, or UV_INDEX_*_PASSWORD.
  if [ "$WITH_REGISTRY" = "1" ]; then
    # npm/pnpm read ~/.npmrc by default, but honour a relocated userconfig
    # (npm_config_userconfig / NPM_CONFIG_USERCONFIG) so a host that moved its
    # npmrc doesn't silently fall through to the public registry. Whatever the
    # host source, mount it at the container's default /root/.npmrc — and we do
    # NOT forward npm_config_userconfig, so the in-container npm keeps that path.
    npmrc_src="${npm_config_userconfig:-${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}}"
    [ -f "$npmrc_src" ]               && MOUNT_ARGS+=("-v" "$(hostpath "$npmrc_src"):/root/.npmrc:ro")
    # uv and pip keep their Windows user config under %APPDATA% (pip names the
    # file pip.ini there — same INI format, so it lands at the same pip.conf path).
    uv_toml=""
    if [ -n "$APPDATA_DIR" ] && [ -f "$APPDATA_DIR/uv/uv.toml" ]; then
      uv_toml="$APPDATA_DIR/uv/uv.toml"
    elif [ -f "$HOME/.config/uv/uv.toml" ]; then
      uv_toml="$HOME/.config/uv/uv.toml"
    fi
    [ -n "$uv_toml" ] && MOUNT_ARGS+=("-v" "$(hostpath "$uv_toml"):/root/.config/uv/uv.toml:ro")
    pip_conf=""
    if [ -f "$HOME/Library/Application Support/pip/pip.conf" ]; then
      pip_conf="$HOME/Library/Application Support/pip/pip.conf"
    elif [ -n "$APPDATA_DIR" ] && [ -f "$APPDATA_DIR/pip/pip.ini" ]; then
      pip_conf="$APPDATA_DIR/pip/pip.ini"
    elif [ -f "$HOME/.config/pip/pip.conf" ]; then
      pip_conf="$HOME/.config/pip/pip.conf"
    fi
    [ -n "$pip_conf" ] && MOUNT_ARGS+=("-v" "$(hostpath "$pip_conf"):/root/.config/pip/pip.conf:ro")
  fi
  # Each mount above is a `[ ] &&` that is false when its file is absent; main
  # runs under set -e, so the function must not return that status.
  return 0
}

build_env_args() {
  local v _name
  ENV_VARS=()
  # GH_TOKEN/GITHUB_TOKEN are forwarded verbatim only under --gh-direct: under
  # --gh the token instead goes to the auth-proxy sidecar (see below), never
  # into the agent container.
  [ "$WITH_GH_DIRECT" = "1" ] && ENV_VARS+=(GH_TOKEN GITHUB_TOKEN)
  # GITLAB_TOKEN likewise only under --glab-direct; --glab hands it to the sidecar.
  [ "$WITH_GLAB_DIRECT" = "1" ] && ENV_VARS+=(GITLAB_TOKEN GITLAB_HOST)
  [ "$WITH_GLAB" = "1" ] && ENV_VARS+=(GITLAB_HOST)
  [ "$WITH_AWS" = "1" ]  && ENV_VARS+=(AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)
  [ "$WITH_TFE" = "1" ]  && ENV_VARS+=(TF_TOKEN_app_terraform_io)
  [ "$WITH_AZ" = "1" ]   && ENV_VARS+=(AZURE_DEVOPS_EXT_PAT AZURE_DEVOPS_ORG_URL)
  # --registry: forward the native registry-config env vars uv/npm/pnpm/pip read.
  # Static, fixed-name vars here; uv's dynamic per-index credential vars (whose
  # names embed a user-chosen index name) are handled by the scan below.
  # UV_NETRC is intentionally omitted: it points uv at a netrc file we no longer
  # mount, so forwarding it would dangle at a host path absent in the container.
  [ "$WITH_REGISTRY" = "1" ] && ENV_VARS+=(npm_config_registry NPM_CONFIG_REGISTRY NODE_AUTH_TOKEN NPM_TOKEN UV_INDEX_URL UV_DEFAULT_INDEX UV_EXTRA_INDEX_URL UV_INDEX UV_KEYRING_PROVIDER PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_TRUSTED_HOST PIPENV_PYPI_MIRROR)
  # --mistral: the model key, by name (-e MISTRAL_API_KEY, no value), so it is
  # never on the docker CLI's argv. vibe reads the environment before
  # ~/.vibe/.env, so this key wins over one the setup wizard saved in the
  # vibe-home volume. Never forwarded without the flag.
  [ "$WITH_MISTRAL" = "1" ] && ENV_VARS+=(MISTRAL_API_KEY)
  # Guarded: bash 3.2 under `set -u` errors on empty-array expansion.
  if [ "${#ENV_VARS[@]}" -gt 0 ]; then
    for v in "${ENV_VARS[@]}"; do
      [ -n "${!v:-}" ] && ENV_ARGS+=("-e" "$v")
    done
  fi
  # uv's per-index credentials are UV_INDEX_<NAME>_USERNAME / _PASSWORD, where
  # <NAME> is a user-chosen index name — a fixed list can't enumerate them. Scan
  # the exported host vars and forward matches, scoped STRICTLY to those two
  # suffixes: a blanket UV_* would drag in path-valued vars like UV_CACHE_DIR that
  # point at host paths absent in the container. Safe under set -u (read assigns).
  if [ "$WITH_REGISTRY" = "1" ]; then
    while IFS= read -r _name; do
      case "$_name" in
        UV_INDEX_*_USERNAME|UV_INDEX_*_PASSWORD)
          [ -n "${!_name:-}" ] && ENV_ARGS+=("-e" "$_name") ;;
      esac
    done < <(compgen -e)
  fi
  return 0
}

discover_tokens() {
  local _ws0 _glab_cfg _glab_remote _glab_default _glab_tried _glab_host _glab_from _glab_discovered=0
  local _glab_origin _glab_unbound _glab_flag=--glab
  [ "$WITH_GLAB_DIRECT" = "1" ] && _glab_flag=--glab-direct
  # GitHub token discovery — shared, unchanged, by --gh and --gh-direct: host
  # env (GH_TOKEN/GITHUB_TOKEN) wins; else fall back to the gh CLI's active
  # token so users authenticated via `gh auth login` don't have to export
  # anything manually; else silent skip (gh absent or not logged in). What
  # differs is disposition: --gh-direct forwards the result into the agent
  # container (below, mirroring the legacy --gh behavior this preserves);
  # --gh instead hands it only to the auth-proxy sidecar, further down.
  GH_DISCOVERED_TOKEN=""
  if { [ "$WITH_GH" = "1" ] || [ "$WITH_GH_DIRECT" = "1" ]; } \
     && [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] \
     && command -v gh >/dev/null 2>&1; then
    GH_DISCOVERED_TOKEN=$(gh auth token 2>/dev/null) || true
  fi
  if [ "$WITH_GH_DIRECT" = "1" ] && [ -n "$GH_DISCOVERED_TOKEN" ]; then
    GH_TOKEN="$GH_DISCOVERED_TOKEN"
    export GH_TOKEN
    ENV_ARGS+=("-e" "GH_TOKEN")
  fi
  # Token handed to the --gh auth-proxy sidecar setup below, mirroring the
  # discovery precedence above (host env wins over the gh-CLI fallback). Empty
  # when no token was found either way; set from an exported GH_TOKEN /
  # GITHUB_TOKEN even without --gh, so its users check WITH_GH too.
  GH_HOST_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-$GH_DISCOVERED_TOKEN}}"
  # GitLab token discovery for --glab, same shape as gh's: host GITLAB_TOKEN
  # wins; else ask host glab for a token, trying GITLAB_HOST alone when set,
  # otherwise the first workspace's origin host and then glab's default host
  # (config.yml's `host`, else gitlab.com). Without a token the in-container
  # glab calls the API unauthenticated, which public projects mask (#126); its
  # config.yml has the keyring off (stage_glab_config). `glab config get token
  # --host` reads the OS keyring, which the read-only config mount can't carry;
  # without --host it never looks at per-host tokens. The origin URL is read as a
  # plain file (no includes) from the repo's common git dir, so worktree and
  # submodule workspaces (.git is a pointer file) resolve to the main repo /
  # module config; symlinked .git or config is skipped, as in the git-config
  # overlay below. Under --glab-direct a discovered token is forwarded by bare
  # name, never on argv; under --glab it goes to the auth-proxy sidecar only.
  # Warn when nothing is found.
  # Explicit GITLAB_TOKEN under --glab-direct needs no host at all (it is
  # forwarded with the other opt-in vars, and the in-container glab picks its
  # host as before); every other case needs the candidate list.
  if { [ "$WITH_GLAB" = "1" ] || [ "$WITH_GLAB_DIRECT" = "1" ]; } \
     && { [ -z "${GITLAB_TOKEN:-}" ] || [ "$WITH_GLAB" = "1" ]; }; then
    _glab_hosts=()
    _glab_origin=""
    if [ -n "${GITLAB_HOST:-}" ]; then
      _glab_hosts=("$GITLAB_HOST")
    else
      _ws0="${SEEN_PATHS[0]}"
      if [ -e "$_ws0/.git" ] && [ ! -L "$_ws0/.git" ]; then
        # git.exe is native under Git Bash and argv conversion is off, so -C
        # needs hostpath(), as for the core.autocrlf lookup in stage_git_overlays.
        _glab_cfg=$(git -C "$(hostpath "$_ws0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || true
        if [ -n "$_glab_cfg" ] && [ -f "$_glab_cfg/config" ] && [ ! -L "$_glab_cfg/config" ]; then
          # Read through cat_nofollow so a config swapped for a link mid-launch
          # is refused too; git parses the verified bytes from stdin.
          _glab_remote=$(cat_nofollow "$_glab_cfg" config | git config --file - --get remote.origin.url 2>/dev/null) || true
          # The port of an ssh:// or scp-style (user@host:path) remote is the SSH
          # port, not GitLab's: reduce those to the bare host here. http(s) URLs
          # keep theirs and are trimmed with the other candidates below.
          case "$_glab_remote" in
            http://* | https://*) ;;
            *://*)
              _glab_remote=${_glab_remote#*://}
              _glab_remote=${_glab_remote%%/*}
              _glab_remote=${_glab_remote##*@}
              _glab_remote=${_glab_remote%%:*}
              ;;
            *)
              _glab_remote=${_glab_remote%%:*}
              _glab_remote=${_glab_remote##*@}
              ;;
          esac
          if [ -n "$_glab_remote" ]; then
            _glab_hosts+=("$_glab_remote")
            _glab_origin=$(glab_host_of "$_glab_remote")
          fi
        fi
      fi
      if command -v glab >/dev/null 2>&1; then
        _glab_default=$(GLAB_CHECK_UPDATE=false glab config get host 2>/dev/null) || true
        _glab_hosts+=("${_glab_default:-gitlab.com}")
      else
        # No glab on the host (--glab or --glab-direct, token or not), so no
        # configured default to ask for: use glab's built-in one, gitlab.com.
        # An exported GITLAB_TOKEN then belongs to it; without one nothing
        # below can look a token up, and discovery comes back empty.
        _glab_hosts+=("gitlab.com")
      fi
    fi
    _glab_tried=""
    _glab_host=""
    # The candidate as given, scheme included, for the plain-http check below.
    _glab_from=""
    if [ -n "${GITLAB_TOKEN:-}" ]; then
      # Explicit token (--glab): no lookup ties it to a host, so it belongs to
      # GITLAB_HOST when set, else glab's default host, the last candidate.
      # Never the origin: it may not be a GitLab host at all, and the proxy
      # would then send the token there.
      _glab_from="${_glab_hosts[${#_glab_hosts[@]}-1]}"
      _glab_host=$(glab_host_of "$_glab_from")
    elif command -v glab >/dev/null 2>&1; then
      # `glab config get token --host` answers GITLAB_ACCESS_TOKEN, OAUTH_TOKEN
      # or a legacy root-level `token:` for any host. Such a token is no proof
      # that the origin is a GitLab host, and the origin comes from a writable
      # .git/config: ask for a host that can't exist, and when the origin's
      # answer is that same unbound token, skip the origin. The token then
      # belongs to the default host, as an explicit GITLAB_TOKEN does.
      _glab_unbound=""
      if [ -n "$_glab_origin" ]; then
        _glab_unbound=$(GLAB_CHECK_UPDATE=false glab config get token --host vibe-docker.invalid 2>/dev/null) || true
      fi
      # Non-empty whenever glab is on PATH (default host always appended), so
      # the expansion is safe under bash 3.2's set -u.
      for _glab_from in "${_glab_hosts[@]}"; do
        _glab_host=$(glab_host_of "$_glab_from")
        [ -n "$_glab_host" ] || continue
        case ", $_glab_tried, " in *", $_glab_host, "*) continue ;; esac
        GITLAB_TOKEN=$(GLAB_CHECK_UPDATE=false glab config get token --host "$_glab_host" 2>/dev/null) || true
        # Not added to _glab_tried: the default host may be the same one, and
        # there the unbound token is accepted.
        if [ -n "$GITLAB_TOKEN" ] && [ "$GITLAB_TOKEN" = "$_glab_unbound" ] \
           && [ "$_glab_from" = "${_glab_hosts[0]}" ] && [ "$_glab_host" = "$_glab_origin" ]; then
          GITLAB_TOKEN=""
          continue
        fi
        _glab_tried="${_glab_tried:+$_glab_tried, }$_glab_host"
        [ -n "$GITLAB_TOKEN" ] && { _glab_discovered=1; break; }
      done
    fi
    if [ -n "${GITLAB_TOKEN:-}" ]; then
      if [ "$WITH_GLAB" = "1" ]; then
        # Proxied: the token goes to the auth-proxy sidecar only (it is not in
        # ENV_VARS under --glab, so nothing forwards it), which needs a host it
        # can intercept by name over TLS.
        case "$_glab_from" in
          http://*)
            echo "vibe-docker: --glab: GitLab host '$_glab_from' is plain http, which the auth proxy can't serve; use --glab-direct" >&2
            exit 1 ;;
        esac
        # IPv4 (only digits and dots before the port) or IPv6 (brackets or
        # more than one colon).
        if [[ "${_glab_host%:*}" != *[!0-9.]* || "$_glab_host" == *\[* || "$_glab_host" == *:*:* ]]; then
          echo "vibe-docker: --glab: GitLab host '$_glab_host' is an IP address, which the auth proxy can't intercept by name; use --glab-direct" >&2
          exit 1
        fi
        # The host lands in the Caddyfile as the site address and in
        # --add-host: allow only a hostname with an optional port.
        if ! [[ "$_glab_host" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
          echo "vibe-docker: --glab: GitLab host '$_glab_host' is not a valid host[:port]" >&2
          exit 1
        fi
        GLAB_HOST_TOKEN="$GITLAB_TOKEN"
        GLAB_PROXY_HOST="$_glab_host"
      elif [ "$_glab_discovered" = "1" ]; then
        export GITLAB_TOKEN
        ENV_ARGS+=("-e" "GITLAB_TOKEN")
      fi
      # The token belongs to the host it was found for. Without GITLAB_HOST the
      # in-container glab targets gitlab.com, so pass that host along (a set
      # GITLAB_HOST is already forwarded with the other opt-in vars).
      if [ -z "${GITLAB_HOST:-}" ]; then
        export GITLAB_HOST="$_glab_host"
        ENV_ARGS+=("-e" "GITLAB_HOST")
      fi
    elif command -v glab >/dev/null 2>&1; then
      echo "vibe-docker: $_glab_flag: no GitLab token found for ${_glab_tried:-any host}; set GITLAB_HOST=<host> (after host 'glab auth login') or export GITLAB_TOKEN" >&2
    else
      echo "vibe-docker: $_glab_flag: glab not on host PATH, no GitLab token to forward; export GITLAB_TOKEN" >&2
    fi
  fi
}

# host[:port] from https://user@host:port/path or a bare host[:port]. Path
# first, so an @ in the path or password can't move the cut.
glab_host_of() {
  local h="$1"
  h=${h#*://}
  h=${h%%/*}
  h=${h##*@}
  printf '%s' "$h"
}

# Scope a credential helper to one host[:port]. git matches credential.<url>
# keys by URL, and an empty host (from e.g. AZURE_DEVOPS_ORG_URL=https://)
# matches every host, while a * glob widens to every host it covers. Anything
# but a plain hostname gets no helper, so the token is never offered beyond
# its forge.
add_cred_helper() {
  local flag=$1 var=$2 host=$3 helper=$4
  if [[ ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?$ ]]; then
    echo "vibe-docker: $flag: $var has no usable host ('$host'); git over HTTPS gets no credential helper" >&2
    return 0
  fi
  GIT_CFG+=("credential.https://$host.helper" "$helper")
}

# The forwarded forge tokens reach the CLIs but not git: over HTTPS, git has no
# credential helper and fails with "could not read Username". Give it one per
# opted-in forge, each scoped to that forge's host so git never offers a token
# anywhere else. Under --gh and --glab the sidecar injects auth for the forge's
# host, so only --gh-direct and --glab-direct need one. GIT_CONFIG_* env is
# command-line scope: nothing lands in the persistent ~/.gitconfig. SSH remotes
# are left alone (no key or agent in the container); docs/auth.md#ssh-remotes
# covers switching them to HTTPS.
build_git_config() {
  local host i=0
  [ "$WITH_GH_DIRECT" = "1" ] && GIT_CFG+=(credential.https://github.com.helper "!gh auth git-credential")
  if [ "$WITH_GLAB_DIRECT" = "1" ]; then
    # discover_tokens has set GITLAB_HOST to the token's host when it found one.
    host=${GITLAB_HOST:-gitlab.com}
    host=${host#*://}; host=${host%%/*}
    add_cred_helper --glab-direct GITLAB_HOST "$host" "!glab auth git-credential"
  fi
  if [ "$WITH_AZ" = "1" ]; then
    host=${AZURE_DEVOPS_ORG_URL:-https://dev.azure.com}
    host=${host#*://}; host=${host%%/*}
    # \$ stays literal: the PAT is read from env when git runs the helper, so it
    # is never on argv or in the helper string.
    add_cred_helper --az AZURE_DEVOPS_ORG_URL "$host" "!f() { test \"\$1\" = get && echo username=pat && echo \"password=\$AZURE_DEVOPS_EXT_PAT\"; }; f"
  fi
  while [ "$i" -lt "${#GIT_CFG[@]}" ]; do
    ENV_ARGS+=("-e" "GIT_CONFIG_KEY_$((i / 2))=${GIT_CFG[i]}" "-e" "GIT_CONFIG_VALUE_$((i / 2))=${GIT_CFG[i + 1]}")
    i=$((i + 2))
  done
  [ "$i" -gt 0 ] && ENV_ARGS+=("-e" "GIT_CONFIG_COUNT=$((i / 2))")
  return 0
}

forward_git_identity() {
  local git_name git_email
  # Forward host git identity so in-container `git commit` works without a
  # per-invocation `-c user.email=...` dance. Non-opt-in: user.name/user.email
  # are already on every public commit the user has ever made, so there is no
  # credential to gate. GIT_AUTHOR_* / GIT_COMMITTER_* take precedence over
  # config and are sufficient for commits; we deliberately skip signing and
  # other host-specific settings (credential helpers, hooks) that wouldn't
  # work in the container anyway.
  if command -v git >/dev/null 2>&1; then
    if git_name=$(git config --global --get user.name 2>/dev/null) && [ -n "$git_name" ]; then
      ENV_ARGS+=("-e" "GIT_AUTHOR_NAME=$git_name" "-e" "GIT_COMMITTER_NAME=$git_name")
    fi
    if git_email=$(git config --global --get user.email 2>/dev/null) && [ -n "$git_email" ]; then
      ENV_ARGS+=("-e" "GIT_AUTHOR_EMAIL=$git_email" "-e" "GIT_COMMITTER_EMAIL=$git_email")
    fi
  fi
}

build_flags_env() {
  local old_ifs DOCKER_FLAGS_CSV ro_count=0 k=0
  # Surface active opt-ins in-container via VIBE_DOCKER_FLAGS so a hook, a
  # prompt or the user's shell can tell what this session was actually granted.
  # Order mirrors the Credential opt-in table in docs/auth.md so the list reads
  # predictably.
  # --yolo is omitted intentionally: vibe already shows auto-approve in its
  # own mode indicator, so duplicating it here would just be noise.
  DOCKER_FLAGS=()
  [ "$WITH_AWS" = "1" ]      && DOCKER_FLAGS+=("aws")
  [ "$WITH_GH" = "1" ]       && DOCKER_FLAGS+=("gh")
  [ "$WITH_GH_DIRECT" = "1" ] && DOCKER_FLAGS+=("gh-direct")
  [ "$WITH_GLAB" = "1" ]     && DOCKER_FLAGS+=("glab")
  [ "$WITH_GLAB_DIRECT" = "1" ] && DOCKER_FLAGS+=("glab-direct")
  [ "$WITH_TFE" = "1" ]      && DOCKER_FLAGS+=("tfe")
  [ "$WITH_AZ" = "1" ]       && DOCKER_FLAGS+=("az")
  [ "$WITH_REGISTRY" = "1" ] && DOCKER_FLAGS+=("registry")
  [ "$WITH_MISTRAL" = "1" ]  && DOCKER_FLAGS+=("mistral")
  [ "$EPHEMERAL" = "1" ]     && DOCKER_FLAGS+=("ephemeral")
  while [ "$k" -lt "${#WORKSPACES[@]}" ]; do
    [ "${WORKSPACES_RO[$k]:-0}" = "1" ] && ro_count=$((ro_count + 1))
    k=$((k + 1))
  done
  if [ "$RO_WORKSPACES" = "1" ] || { [ "$ro_count" -gt 0 ] && [ "$ro_count" -eq "${#WORKSPACES[@]}" ]; }; then
    DOCKER_FLAGS+=("ro")
  elif [ "$ro_count" -gt 0 ]; then
    DOCKER_FLAGS+=("ro-partial")
  fi
  if [ "${#DOCKER_FLAGS[@]}" -gt 0 ]; then
    old_ifs=$IFS; IFS=','; DOCKER_FLAGS_CSV="${DOCKER_FLAGS[*]}"; IFS=$old_ifs
    ENV_ARGS+=("-e" "VIBE_DOCKER_FLAGS=$DOCKER_FLAGS_CSV")
  fi
}

create_stage() {
  local stage_root
  # Host Vibe config parity: copies of host config items, and the auth-proxy
  # sidecar's config, are bind-mounted from this stage dir. It lives under
  # $HOME because /tmp and $TMPDIR are NOT shared by Colima's default mount
  # config, so any bind-mount from those paths silently yields an empty
  # mountpoint in the container. $TMPDIR on macOS is /var/folders/... (not
  # shared by either runtime); /tmp is shared by Docker Desktop only, while
  # both share /Users.
  stage_root="$HOME/.cache/vibe-docker"
  mkdir -p "$stage_root" || exit 1
  stage=$(mktemp -d "$stage_root/host.XXXXXX") || exit 1

  # Auth-proxy sidecar session identity, derived from the stage-dir
  # suffix so it's already unique (mktemp did the work) with no extra
  # bookkeeping. Named here — immediately after the stage dir exists but
  # before ANY docker resource is created — purely so the EXIT trap below can
  # be extended before there is anything for it to clean up. Actual sidecar
  # creation (gated on a proxied opt-in having a credential) happens further down.
  proxy_sid="${stage##*.}"
  AUTH_PROXY_NETWORK="vibe-auth-$proxy_sid"
  AUTH_PROXY_SIDECAR="vibe-auth-proxy-$proxy_sid"

  # `case` instead of `[[ ]]` for bash 3.2 friendliness inside the trap string.
  # $HOME/$RUNTIME/$AUTH_PROXY_* are expanded at trap execution time, * is a glob
  # wildcard. The sidecar/network removals are unconditional and tolerate
  # not-yet-existing resources (`|| true`): trap-before-create closes the
  # window where a failure between creating a resource and re-trapping would
  # leak it, so this must be in place before the network/sidecar are created.
  # The sidecar goes first: a network with a container attached can't be removed.
  trap '
  case "$stage" in "$HOME/.cache/vibe-docker/host."*) rm -rf "$stage" ;; esac
  "$RUNTIME" rm -f "$AUTH_PROXY_SIDECAR" >/dev/null 2>&1 || true
  "$RUNTIME" network rm "$AUTH_PROXY_NETWORK" >/dev/null 2>&1 || true
  ' EXIT
}

# Auth-proxy sidecar config. Every file below is a constant — quoted heredoc
# delimiters keep the shell out of them, and tests/test_auth_proxy_caddyfile.py
# pins that. Per-run differences reach Caddy only as env ({$VAR} substituted at
# config load, {env.VAR} per request: that is how the credentials get in, so
# they never touch disk) or as *which* files are staged. The root Caddyfile
# imports every staged site snippet; each proxied opt-in contributes one.
stage_proxy_root() {
  mkdir -p "$1/sites" || exit 1
  cat <<'CADDY' >"$1/Caddyfile" || exit 1
{
	admin off
	local_certs
	skip_install_trust
	log {
		output stdout
		format json
	}
}

import /etc/caddy/sites/*.caddy
CADDY
}

# --gh: github.com / api.github.com / uploads.github.com. api.github.com and
# uploads.github.com take a Bearer token; github.com (git smart-HTTP) takes
# Basic x-access-token:<token> — see the gh-auth-proxy-sidecar design.md.
# header_up REPLACES any client-supplied Authorization, so the placeholder
# GH_TOKEN gh/git send is discarded, never forwarded. The single exception is
# release-asset HEAD probes on github.com, where the header is deleted
# instead of replaced (see the block itself). The policy file is ALWAYS
# staged — the user's snippet when VIBE_DOCKER_GH_POLICY is set, an empty
# file otherwise — so the import needs no conditional (validate_opts has
# already rejected a set-but-unreadable path).
stage_gh_proxy_site() {
  if [ -n "${VIBE_DOCKER_GH_POLICY:-}" ]; then
    cp "$VIBE_DOCKER_GH_POLICY" "$1/policy.caddy" || exit 1
  else
    : > "$1/policy.caddy" || exit 1
  fi
  cat <<'CADDY' >"$1/sites/gh.caddy" || exit 1
github.com {
	tls internal
	log {
		output stdout
		format json
	}

	# Release-asset HEAD probes go out anonymous. GitHub routes a HEAD that
	# carries *any* Authorization header to a legacy
	# objects.githubusercontent.com pre-signed URL that then answers 401 to
	# every method, while an anonymous HEAD gets the working
	# release-assets.githubusercontent.com CDN — so uv, which probes with HEAD
	# before GET, cannot install from a release-asset URL (issue #22). The
	# credential buys nothing on this endpoint: github.com's web
	# /releases/download/ path does not accept token auth at all, so a private
	# asset 404s with or without it (the supported route for those is the API
	# asset endpoint, i.e. `gh release download`). Scoped to method+path so
	# every request that works today keeps its credential and its route:
	# authenticated GET is untouched (it already redirects to the working CDN),
	# as are git smart-HTTP, /archive/ and /raw/, none of which change route
	# under auth. -Authorization *deletes* rather than replaces, because the
	# placeholder GH_TOKEN gh/git send would trigger the same legacy routing.
	@gh_release_asset_head {
		method HEAD
		path_regexp ^/[^/]+/[^/]+/releases/download/.+
	}
	handle @gh_release_asset_head {
		reverse_proxy {$GH_PROXY_UPSTREAM_GITHUB} {
			header_up -Authorization
		}
	}

	handle {
		reverse_proxy {$GH_PROXY_UPSTREAM_GITHUB} {
			header_up Authorization "{env.GH_PROXY_BASIC}"
		}
	}
}

api.github.com {
	tls internal
	log {
		output stdout
		format json
	}

	# Both routes GitHub serves a repo on: /repos/{owner}/{repo} and the
	# numeric-id alias /repositories/{id} (the form its Link headers use).
	@gh_proxy_repo_delete {
		method DELETE
		path_regexp ^/(repos/[^/]+/[^/]+|repositories/[0-9]+)/?$
	}
	respond @gh_proxy_repo_delete "vibe-docker gh-proxy policy: repository deletion is blocked by default. Extend policy via VIBE_DOCKER_GH_POLICY, or bypass the proxy entirely with --gh-direct." 403
	import /etc/caddy/policy.caddy

	reverse_proxy {$GH_PROXY_UPSTREAM_API} {
		header_up Authorization "{env.GH_PROXY_BEARER}"
	}
}

uploads.github.com {
	tls internal
	log {
		output stdout
		format json
	}
	reverse_proxy {$GH_PROXY_UPSTREAM_UPLOADS} {
		header_up Authorization "{env.GH_PROXY_BEARER}"
	}
}
CADDY
}

# --glab: the one GitLab host the token belongs to ({$GLAB_PROXY_SITE},
# host[:port]). Everything sits in `route` so it runs in the written order —
# Caddy otherwise sorts directives, and would run a top-level `respond` (the
# policy, or a user snippet) only after proxying. Client credentials are
# stripped first; then the real one is injected per path class: Bearer on
# /api/ (REST and GraphQL take PATs and OAuth tokens alike), Basic oauth2:<token>
# on git smart-HTTP, nothing anywhere else (web UI paths don't serve glab or
# git). Not on LFS either: the batch response echoes a usable credential back
# to the client (actions.*.header.Authorization). The default policy blocks
# project/group deletion and the REST calls that grant access that outlives
# the session: tokens, SSH/GPG/deploy keys, runner, trigger and cluster-agent
# tokens, project/group members (added, imported or approved), invitations,
# LDAP/SAML group links, shares, transfers, webhooks, integrations, push and
# pull mirrors, pipeline schedules and access-request approvals, plus the admin
# calls that create or edit users and OAuth applications or change instance
# settings. Adding an email is blocked too: a verified secondary address can
# receive a password reset, which hands over the whole account. A PUT on a bare project or group
# path (its settings, visibility included) is refused too: Caddy can't read
# the body to tell a visibility change apart. Best effort: GraphQL is not
# filtered, and token scope is the real limit. Both match the raw request
# URI: path_regexp sees the decoded path, so a URL-encoded project path
# (group%2Fproject) would slip past it. A raw match
# can be dodged by percent-encoding a letter (/api/v4/%70rojects/1), which
# GitLab's router decodes, so a write (DELETE/POST/PUT, what the policy
# checks) that escapes an unreserved character is refused; reads pass, since
# GitLab's own docs encode dots in file paths. Deletion also matches POST:
# Rack::MethodOverride turns a POST carrying _method=delete or
# X-HTTP-Method-Override: DELETE into a DELETE. The only POSTs on a bare
# project or group path are the imports, which are let through. Request
# {http.request.uri} is the origin-form path and query even for an
# absolute-form request line (DELETE https://host/api/...), so the anchored
# matches cover that too. Request headers are dropped from the access log.
stage_glab_proxy_site() {
  if [ -n "${VIBE_DOCKER_GLAB_POLICY:-}" ]; then
    cp "$VIBE_DOCKER_GLAB_POLICY" "$1/glab-policy.caddy" || exit 1
  else
    : > "$1/glab-policy.caddy" || exit 1
  fi
  cat <<'CADDY' >"$1/sites/glab.caddy" || exit 1
{$GLAB_PROXY_SITE} {
	tls internal
	log {
		output stdout
		format filter {
			wrap json
			request>headers delete
		}
	}

	route {
		request_header -Authorization
		request_header -PRIVATE-TOKEN
		request_header -JOB-TOKEN

		@glab_proxy_api path /api/*
		request_header @glab_proxy_api Authorization "{env.GLAB_PROXY_BEARER}"
		@glab_proxy_git path_regexp (/info/refs|/git-upload-pack|/git-receive-pack)$
		request_header @glab_proxy_git Authorization "{env.GLAB_PROXY_BASIC}"

		@glab_proxy_escaped {
			method DELETE POST PUT
			vars_regexp {http.request.uri} ^[^?]*%(2[DEde]|3[0-9]|4[1-9A-Fa-f]|5[0-9AFaf]|6[1-9A-Fa-f]|7[0-9AEae])
		}
		respond @glab_proxy_escaped "vibe-docker glab-proxy policy: a percent-encoded letter, digit or -._~ in the path is refused, since it could hide a blocked call. Send it unencoded, or bypass the proxy entirely with --glab-direct." 403
		@glab_proxy_delete {
			method DELETE POST
			vars_regexp {http.request.uri} ^/+api/+v4/+(projects|groups)/+[^/?]+/*(\?.*)?$
			not {
				method POST
				vars_regexp {http.request.uri} ^/+api/+v4/+(projects|groups)/+(import|remote-import|remote-import-s3)(\.json)?/*(\?.*)?$
			}
		}
		respond @glab_proxy_delete "vibe-docker glab-proxy policy: project and group deletion is blocked by default. Extend policy via VIBE_DOCKER_GLAB_POLICY, or bypass the proxy entirely with --glab-direct." 403
		@glab_proxy_settings {
			method PUT
			vars_regexp {http.request.uri} ^/+api/+v4/+(projects|groups)/+[^/?]+/*(\?.*)?$
		}
		respond @glab_proxy_settings "vibe-docker glab-proxy policy: changing a project's or group's settings is blocked by default, since visibility and access settings can open access that outlives the session. Bypass the proxy with --glab-direct to change them." 403
		@glab_proxy_mint {
			method POST PUT
			vars_regexp {http.request.uri} ^/+api/+v4/+(personal_access_tokens/+[^/?]+/+rotate|user/+personal_access_tokens|users/+[^/?]+/+(personal_access_tokens|impersonation_tokens)|(projects|groups)/+[^/?]+/+(access_tokens|deploy_tokens)(/+[^/?]+/+rotate)?|groups/+[^/?]+/+service_accounts/+[^/?]+/+personal_access_tokens(/+[^/?]+/+rotate)?|deploy_tokens|user/+(keys|gpg_keys|runners|emails)|users/+[^/?]+/+(keys|gpg_keys|emails)|(projects|groups)/+[^/?]+/+deploy_keys(/+[^/?]+/+enable)?|projects/+[^/?]+/+triggers|runners(/+[^/?]+/+reset_authentication_token|/+reset_registration_token)?|(projects|groups)/+[^/?]+/+runners/+reset_registration_token|(projects|groups)/+[^/?]+/+(members|invitations)(/+[^/?]+)?|projects/+[^/?]+/+cluster_agents/+[^/?]+/+tokens|deploy_keys|(projects|groups)/+[^/?]+/+(share|transfer|hooks(/+[^/?]+)?|access_requests/+[^/?]+/+approve)|projects/+[^/?]+/+remote_mirrors(/+[^/?]+)?|projects/+[^/?]+/+mirror/+pull|hooks|projects/+[^/?]+/+import_project_members/+[^/?]+|(projects|groups)/+[^/?]+/+members/+[^/?]+/+approve|groups/+[^/?]+/+(ldap|saml)_group_links(/+[^/?]+)?|(projects|groups)/+[^/?]+/+(integrations|services)(/+[^/?]+)?|projects/+[^/?]+/+pipeline_schedules(/+[^/?]+(/+take_ownership)?)?|users(/+[^/?]+)?|applications|application/+settings)(\.json)?/*(\?.*)?$
		}
		respond @glab_proxy_mint "vibe-docker glab-proxy policy: creating or rotating tokens, adding keys, emails, members, group links, shares, webhooks, integrations, push or pull mirrors, approving access requests or members, pipeline schedules, transfers, and the admin calls that create users, OAuth applications or change instance settings are blocked by default, since they grant access or a data feed that outlives the session. Extend policy via VIBE_DOCKER_GLAB_POLICY, or bypass the proxy entirely with --glab-direct." 403
		import /etc/caddy/glab-policy.caddy

		reverse_proxy {$GLAB_PROXY_UPSTREAM}
	}
}
CADDY
}

start_auth_sidecar() {
  local proxy_dir caddy_dir cfg_loaded ca_ready proxy_exited proxy_logs i entry
  local services="" direct_hint="" sidecar_env sidecar_hosts
  # One sidecar per session serves every proxied opt-in that has a credential.
  # --gh / --glab without a host token keep their no-token fallback and add no
  # site. --*-direct never reach here. Every site is TLS-intercepted, so an
  # active sidecar always has a session CA.
  if [ "$WITH_GH" = "1" ] && [ -n "$GH_HOST_TOKEN" ]; then
    GH_SIDECAR_ACTIVE=1
    services="gh" direct_hint="--gh-direct"
  fi
  if [ "$WITH_GLAB" = "1" ] && [ -n "$GLAB_HOST_TOKEN" ]; then
    GLAB_SIDECAR_ACTIVE=1
    services="${services:+$services, }glab" direct_hint="${direct_hint:+$direct_hint / }--glab-direct"
  fi
  [ -n "$services" ] || return 0

  proxy_dir="$stage/auth-proxy"
  caddy_dir="$proxy_dir/caddy"
  stage_proxy_root "$caddy_dir"
  sidecar_env=()
  if [ "$GH_SIDECAR_ACTIVE" = "1" ]; then
    # Real GitHub by default; the test-only VIBE_DOCKER_GH_UPSTREAM hook
    # repoints all three at a single mock upstream (undocumented — for the
    # tests/ integration harness only).
    GH_PROXY_UPSTREAM_GITHUB="${VIBE_DOCKER_GH_UPSTREAM:-https://github.com}"
    GH_PROXY_UPSTREAM_API="${VIBE_DOCKER_GH_UPSTREAM:-https://api.github.com}"
    GH_PROXY_UPSTREAM_UPLOADS="${VIBE_DOCKER_GH_UPSTREAM:-https://uploads.github.com}"
    # Complete header values, scheme prefix included, computed host-side. tr -d
    # '\n' is required: GNU base64 wraps at 76 columns (the encoded credential
    # exceeds that), BSD base64 does not.
    GH_PROXY_BASIC="Basic $(printf '%s' "x-access-token:$GH_HOST_TOKEN" | base64 | tr -d '\n')" || exit 1
    GH_PROXY_BEARER="Bearer $GH_HOST_TOKEN"
    export GH_PROXY_UPSTREAM_GITHUB GH_PROXY_UPSTREAM_API GH_PROXY_UPSTREAM_UPLOADS GH_PROXY_BASIC GH_PROXY_BEARER
    stage_gh_proxy_site "$caddy_dir"
    sidecar_env+=(-e GH_PROXY_BEARER -e GH_PROXY_BASIC -e GH_PROXY_UPSTREAM_GITHUB -e GH_PROXY_UPSTREAM_API -e GH_PROXY_UPSTREAM_UPLOADS)
  fi
  if [ "$GLAB_SIDECAR_ACTIVE" = "1" ]; then
    GLAB_PROXY_SITE="$GLAB_PROXY_HOST"
    # Test-only hook, like VIBE_DOCKER_GH_UPSTREAM.
    GLAB_PROXY_UPSTREAM="${VIBE_DOCKER_GLAB_UPSTREAM:-https://$GLAB_PROXY_HOST}"
    GLAB_PROXY_BEARER="Bearer $GLAB_HOST_TOKEN"
    GLAB_PROXY_BASIC="Basic $(printf '%s' "oauth2:$GLAB_HOST_TOKEN" | base64 | tr -d '\n')" || exit 1
    export GLAB_PROXY_SITE GLAB_PROXY_UPSTREAM GLAB_PROXY_BEARER GLAB_PROXY_BASIC
    stage_glab_proxy_site "$caddy_dir"
    sidecar_env+=(-e GLAB_PROXY_SITE -e GLAB_PROXY_UPSTREAM -e GLAB_PROXY_BEARER -e GLAB_PROXY_BASIC)
  fi

  if ! "$RUNTIME" network create "$AUTH_PROXY_NETWORK" >/dev/null; then
    echo "vibe-docker: failed to create network '$AUTH_PROXY_NETWORK' for the auth-proxy sidecar — aborting (no credential was forwarded)" >&2
    exit 1
  fi

  # No published ports: the sidecar is reachable only from the agent
  # container, over the session-private network created above. Capabilities
  # dropped to the one Caddy needs (binding <1024 as non-root). Credentials go
  # in by bare name (-e NAME, no value) so they never appear in the docker
  # CLI's argv: /proc/<pid>/cmdline is world-readable on Linux, while environ
  # is owner-only. Deliberately NOT --rm: `run -d` reports success as soon as
  # the container *starts*, so a Caddy that exits immediately (most often an
  # invalid policy snippet) needs its logs to diagnose — with --rm the
  # container, and its logs, would already be gone by the time we notice. The
  # EXIT trap removes it on session end; a stopped stray from a hard-killed
  # run.sh is swept by the stopped-only prune at the next start.
  # The sidecar dials the upstreams itself, so it needs the static entries too.
  sidecar_hosts=()
  for entry in ${ADD_HOSTS[@]+"${ADD_HOSTS[@]}"}; do
    sidecar_hosts+=("--add-host" "$entry")
  done
  if ! "$RUNTIME" run -d \
      --name "$AUTH_PROXY_SIDECAR" \
      --network "$AUTH_PROXY_NETWORK" \
      --cap-drop ALL --cap-add NET_BIND_SERVICE \
      --security-opt no-new-privileges \
      "${sidecar_env[@]}" \
      ${sidecar_hosts[@]+"${sidecar_hosts[@]}"} \
      -v "$(hostpath "$caddy_dir"):/etc/caddy:ro" \
      "$PROXY_IMAGE" >/dev/null; then
    echo "vibe-docker: failed to start the auth-proxy sidecar ($PROXY_IMAGE) — aborting; no credential was forwarded into any container. Try '$RUNTIME pull $PROXY_IMAGE', or bypass the proxy with $direct_hint." >&2
    exit 1
  fi

  # Ready once Caddy reports its config loaded and, when a TLS site is staged,
  # its local CA root is copyable (Caddy materializes it at config load, not on
  # first handshake — so this is a startup-race guard). ~15s budget, short
  # retries.
  cfg_loaded=0
  ca_ready=0
  proxy_exited=0
  i=0
  while [ "$i" -lt 15 ]; do
    # Logs captured first: grep -q on a pipe exits at the match, and under
    # pipefail the SIGPIPE'd logs call would fail the whole check.
    if [ "$cfg_loaded" = "0" ]; then
      proxy_logs=$("$RUNTIME" logs "$AUTH_PROXY_SIDECAR" 2>&1) || true
      case "$proxy_logs" in *'serving initial configuration'*) cfg_loaded=1 ;; esac
    fi
    if [ "$cfg_loaded" = "1" ]; then
      # The destination is a host path handed to the native engine, so it needs
      # hostpath() like every bind-mount source — MSYS argv conversion is off.
      if "$RUNTIME" cp "$AUTH_PROXY_SIDECAR:/data/caddy/pki/authorities/local/root.crt" "$(hostpath "$proxy_dir/root.crt")" >/dev/null 2>&1; then
        ca_ready=1
        break
      fi
    fi
    # Distinguish "still starting" from "already dead" so a config error is
    # reported as itself instead of waiting out the budget.
    if [ -z "$("$RUNTIME" ps -q --filter "name=^$AUTH_PROXY_SIDECAR$" 2>/dev/null)" ]; then
      proxy_exited=1
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ "$proxy_exited" = "1" ]; then
    echo "vibe-docker: the auth-proxy sidecar exited during startup — aborting; no credential was forwarded into any container. Caddy's own error follows (an invalid VIBE_DOCKER_GH_POLICY / VIBE_DOCKER_GLAB_POLICY snippet is the usual cause):" >&2
    "$RUNTIME" logs "$AUTH_PROXY_SIDECAR" 2>&1 | tail -15 | sed 's/^/  | /' >&2
    exit 1
  fi
  if [ "$ca_ready" != "1" ]; then
    if [ "$cfg_loaded" = "1" ]; then
      echo "vibe-docker: auth-proxy sidecar did not produce a CA certificate within 15s — aborting; no credential was forwarded into any container. The sidecar is still running; inspect it with '$RUNTIME logs $AUTH_PROXY_SIDECAR' (it is removed when this command exits)." >&2
    else
      echo "vibe-docker: auth-proxy sidecar did not load its config within 15s — aborting; no credential was forwarded into any container. The sidecar is still running; inspect it with '$RUNTIME logs $AUTH_PROXY_SIDECAR' (it is removed when this command exits)." >&2
    fi
    exit 1
  fi

  proxy_ip=$("$RUNTIME" inspect --format "{{(index .NetworkSettings.Networks \"$AUTH_PROXY_NETWORK\").IPAddress}}" "$AUTH_PROXY_SIDECAR" 2>/dev/null) || true
  if [ -z "$proxy_ip" ]; then
    echo "vibe-docker: could not determine the auth-proxy sidecar's network address — aborting; no credential was forwarded into any container." >&2
    exit 1
  fi

  # Wire the agent container: redirect only the hostnames that need a
  # credential to the sidecar (--add-host rewrites resolution inside the agent
  # container only — see the gh-auth-proxy-sidecar design.md on why this beats
  # a network alias), and hand each CLI a placeholder that satisfies its "am I
  # authenticated" check without being a usable credential.
  MOUNT_ARGS+=("--network" "$AUTH_PROXY_NETWORK")
  if [ "$GH_SIDECAR_ACTIVE" = "1" ]; then
    MOUNT_ARGS+=(
      "--add-host" "github.com:$proxy_ip"
      "--add-host" "api.github.com:$proxy_ip"
      "--add-host" "uploads.github.com:$proxy_ip"
    )
    ENV_ARGS+=("-e" "GH_TOKEN=vibe-docker-proxy")
  fi
  if [ "$GLAB_SIDECAR_ACTIVE" = "1" ]; then
    MOUNT_ARGS+=("--add-host" "${GLAB_PROXY_HOST%%:*}:$proxy_ip")
    ENV_ARGS+=("-e" "GITLAB_TOKEN=vibe-docker-proxy")
  fi
  # The session CA for the TLS-intercepted sites. UV_SYSTEM_CERTS makes uv
  # read the OS trust store instead of the webpki roots bundled into its rustls
  # client — without it uv is the one shipped tool that trusts neither the
  # system bundle nor NODE_EXTRA_CA_CERTS, so every intercepted fetch fails
  # "invalid peer certificate: UnknownIssuer" while git, gh and curl work (issue
  # #22). Full verification is preserved: uv verifies against the same
  # entrypoint-installed session root. (Env name over the deprecated
  # UV_NATIVE_TLS; both are honoured by the pinned uv, only the new one is
  # warning-free.)
  MOUNT_ARGS+=("-v" "$(hostpath "$proxy_dir/root.crt"):/usr/local/share/ca-certificates/vibe-docker-auth-proxy.crt:ro")
  ENV_ARGS+=(
    "-e" "NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/vibe-docker-auth-proxy.crt"
    "-e" "UV_SYSTEM_CERTS=1"
  )
  echo "vibe-docker: auth-proxy sidecar '$AUTH_PROXY_SIDECAR' is active for $services — view the audit log with: $RUNTIME logs $AUTH_PROXY_SIDECAR" >&2
}

# Whether $1 (case-insensitive) is a name the active auth-proxy sidecar
# answers for, so it must keep resolving to the sidecar.
sidecar_name() {
  local name
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$name" in
    github.com|api.github.com|uploads.github.com) [ "$GH_SIDECAR_ACTIVE" = "1" ] && return 0 ;;
  esac
  [ "$GLAB_SIDECAR_ACTIVE" = "1" ] \
    && [ "$name" = "$(printf '%s' "${GLAB_PROXY_HOST%%:*}" | tr '[:upper:]' '[:lower:]')" ]
}

# VIBE_DOCKER_ADD_HOSTS entries for the agent container. The hosts the
# sidecar intercepts are skipped: they must keep resolving to the sidecar.
build_host_args() {
  local entry
  for entry in ${ADD_HOSTS[@]+"${ADD_HOSTS[@]}"}; do
    if sidecar_name "${entry%%:*}"; then
      echo "vibe-docker: VIBE_DOCKER_ADD_HOSTS entry '$entry' skipped for the agent container: it resolves to the auth-proxy sidecar" >&2
      continue
    fi
    MOUNT_ARGS+=("--add-host" "$entry")
  done
}

stage_host_config() {
  local item
  # Everything here is copied into the stage dir and the copy is mounted, never
  # the host path: a directory you also open as a workspace (a dotfiles or
  # shared-config repo your links point into) can be rewritten by a session, and
  # a bind mount or cp -RL would follow whatever link it left there. So each
  # item, or else each entry directly in it, may be one symlink you made; inside
  # what that reaches, a link is kept only if it stays within the copy (see
  # copy_tree_nofollow). Anything else is skipped with a warning.
  # hooks.toml is deliberately not forwarded: host hooks run host commands with
  # host paths and would misfire in the container.
  for item in agents skills prompts; do
    stage_config_dir "$VIBE_CONFIG_DIR/$item" "$stage/$item" "/root/.vibe/$item"
  done
  if stage_config_file AGENTS.md "$stage/AGENTS.md"; then
    MOUNT_ARGS+=("-v" "$(hostpath "$stage/AGENTS.md"):/root/.vibe/AGENTS.md:ro")
  fi
  # vibe also reads skills from the shared Agent Skills path ~/.agents/skills.
  # It lives in $HOME, not in the config dir, so an alternate --vibe-dir that
  # doesn't exist (a profile without any config) doesn't pull in the default
  # profile's skills from there either.
  if [ "$VIBE_CONFIG_DIR" = "$HOME/.vibe" ] || [ -d "$VIBE_CONFIG_DIR" ]; then
    stage_config_dir "$HOME/.agents/skills" "$stage/agents-skills" /root/.agents/skills
  fi
  # config.toml is forwarded via a seed path + entrypoint copy, NOT
  # bind-mounted at /root/.vibe/config.toml directly: vibe saves settings
  # (/config, /theme, /model) by renaming a temporary file over config.toml,
  # and rename() over a mountpoint fails with EBUSY (regardless of :ro), so a
  # direct mount breaks every in-session settings change. The entrypoint
  # copies the seed onto the container filesystem so those writes work;
  # changes last for the run and are overwritten from the host file on the
  # next start — never written back. The seed itself is a staged copy, like
  # the files above. The host's own config.toml is never forwarded: it may
  # name MCP servers that start host binaries, or absolute host paths.
  if stage_config_file config.docker.toml "$stage/config.docker.toml"; then
    MOUNT_ARGS+=("-v" "$(hostpath "$stage/config.docker.toml"):/run/vibe-docker/config.toml:ro")
  fi
  return 0
}

# Stage host config directory $1 (one hop allowed) as $2 and mount the copy
# read-only at container path $3. Silent when $1 is absent.
stage_config_dir() {
  local path=$1 dest=$2 target=$3 src hop
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if ! src=$(one_hop "$path") || [ ! -d "$src" ]; then
    echo "vibe-docker: skipping $path: not a directory reached by at most one symlink" >&2
    return 0
  fi
  # An item that is itself a link (skills -> ~/dotfiles/vibe/skills) points
  # into a directory a session may be able to write, so links directly in it
  # are no longer the user's own: they get no hop.
  hop=1
  [ -L "$path" ] && hop=0
  copy_tree_nofollow "$src" "$dest" "$hop" 0 || return 0
  MOUNT_ARGS+=("-v" "$(hostpath "$dest"):$target:ro")
}

stage_git_overlays() {
  local n i ws_abs ws_name ws_autocrlf
  # Container-only .git/config overlay: enable relative-path worktrees inside the
  # container without touching the host's on-disk repo config. The host file
  # stays unmodified, so host tools that bundle an old libgit2 (notably
  # gitstatusd → Powerlevel10k) keep opening the repo fine; only the container's
  # view of .git/config declares extensions.relativeWorktrees, so git inside the
  # container writes relative paths into worktree link files. Those link files
  # live in the shared on-disk tree and are readable by both ends.
  # Bumping core.repositoryformatversion to 1 in the overlay is required — git
  # refuses an extensions entry on a v0 repo ("v1-only extension found").
  # Overlay is NOT mounted :ro: container-side `git config` / `git remote add`
  # need to succeed; those writes land in the ephemeral overlay and are dropped
  # at exit, which matches the trade-off documented in docs/security.md.
  # Counter loop for bash 3.2 (no "${!arr[@]}" on indexed arrays).
  n=${#SEEN_NAMES[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    ws_abs="${SEEN_PATHS[$i]}"
    ws_name="${SEEN_NAMES[$i]}"
    # Skip workspaces where .git is a worktree/submodule pointer file rather
    # than a directory — only the main repo's .git/config needs the overlay,
    # and the worktree resolves through the main repo's mount anyway.
    # Symlinks are refused at both levels, including one swapped in while this
    # runs (cat_nofollow, #211): the workspace is writable from the container,
    # so a planted .git or .git/config link would otherwise copy an arbitrary
    # host file into the container.
    # The stage file is created first, so a write error there (disk full,
    # EACCES) stops the launch, and only a refused read reaches the warning.
    if [ -d "$ws_abs/.git" ] && [ ! -L "$ws_abs/.git" ] \
       && { : >"$stage/git-config-$ws_name" || exit 1; } \
       && cat_nofollow "$ws_abs" .git/config >>"$stage/git-config-$ws_name"; then
      cat >>"$stage/git-config-$ws_name" <<'EOF' || exit 1

[core]
	repositoryformatversion = 1
[extensions]
	relativeWorktrees = true
[worktree]
	useRelativePaths = true
EOF
      # Git for Windows keeps core.autocrlf=true in its *system* config, which the
      # container never sees — without it every CRLF-checked-out file reads as
      # modified in-container. Carry the host's effective value for this repo.
      # git.exe is native and argv conversion is off, so -C needs hostpath().
      if [ "$IS_MSYS" = "1" ] \
         && ws_autocrlf=$(git -C "$(hostpath "$ws_abs")" config --get core.autocrlf 2>/dev/null) \
         && case $ws_autocrlf in true | false | input) ;; *) false ;; esac; then
        printf '[core]\n\tautocrlf = %s\n' "$ws_autocrlf" >>"$stage/git-config-$ws_name" || exit 1
      fi
      MOUNT_ARGS+=("-v" "$(hostpath "$stage/git-config-$ws_name"):/workspaces/$ws_name/.git/config")
    else
      rm -f "$stage/git-config-$ws_name"
      # Quiet for a workspace with no repo, or a worktree/submodule pointer.
      if [ -d "$ws_abs/.git" ] && [ ! -L "$ws_abs/.git" ] \
         && { [ -e "$ws_abs/.git/config" ] || [ -L "$ws_abs/.git/config" ]; }; then
        echo "vibe-docker: no .git/config overlay for $ws_abs: it is a symlink, or changed while being read; git in the container uses the host file" >&2
      fi
    fi
    i=$((i + 1))
  done
}

# The in-container glab reads job_token through the OS keyring whenever the
# host's config.yml says use_keyring: true, even with GITLAB_TOKEN set (no env
# var covers job_token), and that read fails hard without D-Bus. Overlay a copy
# with the keyring turned off; the token itself arrives as GITLAB_TOKEN. Under
# --glab, proxied or not (no token found), the copy also has every *token value
# blanked (token, job_token, oauth2_refresh_token — for every host, since
# tokens for other hosts have no business in the container either); the
# placeholder GITLAB_TOKEN env wins over config in glab, so nothing reads them.
# glab refuses a config.yml that others can read, so write the copy as 0600
# rather than whatever the umask gives (#168).
stage_glab_config() {
  local token_expr api_host
  [ -n "$GLAB_SRC" ] && [ -f "$GLAB_SRC/config.yml" ] || return 0
  token_expr='s/x/x/'
  [ "$WITH_GLAB" = "1" ] && token_expr='s/^\([[:space:]]*[A-Za-z0-9_]*token:\).*/\1 ""/'
  (umask 077 && sed -e 's/^\([[:space:]]*use_keyring:\).*/\1 false/' -e "$token_expr" "$GLAB_SRC/config.yml" >"$stage/glab-config.yml") || exit 1
  MOUNT_ARGS+=("-v" "$(hostpath "$stage/glab-config.yml"):/root/.config/glab-cli/config.yml:ro")
  # glab sends API calls to the host's api_host, not the host itself. A
  # different api_host is not intercepted, so those calls would carry only the
  # placeholder and fail 401. Host keys sit at the indent of the first line
  # under hosts: (glab writes four spaces; hand-written configs often use two).
  if [ "$GLAB_SIDECAR_ACTIVE" = "1" ]; then
    api_host=$(awk -v h="$GLAB_PROXY_HOST" '
      /^[[:space:]]*(#|$)/ { next }
      /^[^[:space:]]/ { in_hosts = ($0 ~ /^hosts:/); in_host = 0; ind = ""; next }
      in_hosts {
        match($0, /^[[:space:]]+/); cur = substr($0, 1, RLENGTH)
        if (ind == "") ind = cur
        if (cur == ind) { k = $1; sub(/:$/, "", k); gsub(/["'"'"']/, "", k); in_host = (k == h); next }
      }
      in_host && $1 == "api_host:" { v = $2; gsub(/["'"'"']/, "", v); print v; exit }
    ' "$GLAB_SRC/config.yml" 2>/dev/null) || true
    if [ -n "$api_host" ] && [ "$api_host" != "$GLAB_PROXY_HOST" ] && [ "$api_host" != "${GLAB_PROXY_HOST%%:*}" ] \
       && [ "$api_host" != "$GLAB_PROXY_HOST:443" ]; then
      echo "vibe-docker: --glab: glab's api_host for $GLAB_PROXY_HOST is '$api_host', which the auth proxy does not intercept; API calls will fail. Use --glab-direct, or drop api_host from host glab's config" >&2
    fi
  fi
}

build_cmd() {
  local n i HOLD_ON_ERR
  CMD=(vibe)
  # Grant vibe read/write access to every mounted workspace, not just cwd: its
  # --add-dir also loads that directory's AGENTS.md and .vibe/ and trusts it
  # for the session. Index 0 is already cwd, so skip it. Repeat --add-dir is
  # allowed; we don't dedupe against any user-supplied --add-dir after `--`.
  n=${#CONTAINER_PATHS[@]}
  i=1
  while [ "$i" -lt "$n" ]; do
    CMD+=("--add-dir" "${CONTAINER_PATHS[$i]}")
    i=$((i + 1))
  done
  [ "${#VIBE_FLAGS[@]}" -gt 0 ] && CMD+=("${VIBE_FLAGS[@]}")
  # Test-only hook for the run.sh-driven integration harness (tests/): replace
  # the agent container's command entirely so the harness can run assertions
  # in-container instead of vibe. Undocumented — not a supported user-facing
  # override.
  if [ -n "${VIBE_DOCKER_TEST_ENTRY:-}" ]; then
    CMD=(sh -c "$VIBE_DOCKER_TEST_ENTRY")
  fi
  # VIBE_DOCKER_TMUX=1   → plain tmux (works in any terminal)
  # VIBE_DOCKER_TMUX=cc  → tmux -CC, iTerm2 control mode (native panes on macOS).
  #                          Host must NOT already be inside tmux -CC — nesting
  #                          collapses the inner server to plain splits.
  # Wrap vibe so a fast non-zero exit (e.g. `vibe --worktree` from a non-git
  # dir) stays readable: tmux tears the pane down the moment its command exits AND
  # always returns 0 itself, so without this hold the user sees neither the
  # error message nor a non-zero status — the wrapper just appears to no-op.
  HOLD_ON_ERR='"$@"; rc=$?; if [ $rc -ne 0 ]; then printf "\n[%s exited %d — press Enter to close] " "$1" "$rc" >&2; read -r _; fi; exit $rc'
  case "${VIBE_DOCKER_TMUX:-0}" in
    cc|CC) CMD=(tmux -u -CC new-session -A -s vibe sh -c "$HOLD_ON_ERR" _ "${CMD[@]}") ;;
    1)     CMD=(tmux -u     new-session -A -s vibe sh -c "$HOLD_ON_ERR" _ "${CMD[@]}") ;;
  esac
}

build_volume_mounts() {
  local gh_config_unmask
  # Persistent named volumes carry vibe's setup-wizard key (~/.vibe/.env),
  # gh login, trusted-folder answers and session history.
  # --ephemeral skips them for one-shot untrusted sessions. Prepend to MOUNT_ARGS
  # so the docker run line has no conditionally-empty array (bash 3.2 set -u).
  if [ "$EPHEMERAL" = "0" ]; then
    # Mask persisted in-container auth state when the opt-in flag is off, so a
    # prior `gh`/`glab`/`terraform` auth login stored under vibe-root
    # doesn't leak into a session the user didn't ask to grant those creds to.
    # gh is the exception with three states, not two: masked whenever --gh is
    # absent OR the sidecar is active (the placeholder env token makes
    # persisted login state unnecessary, and leaving it accessible would
    # reintroduce a persisted in-container secret) — unmasked only for --gh
    # with no host token found (in-container login is the remaining auth
    # path, unchanged from before this sidecar existed) and for --gh-direct.
    gh_config_unmask=0
    [ "$WITH_GH_DIRECT" = "1" ] && gh_config_unmask=1
    [ "$WITH_GH" = "1" ] && [ "$GH_SIDECAR_ACTIVE" = "0" ] && gh_config_unmask=1
    [ "$gh_config_unmask" = "0" ] && MOUNT_ARGS+=("--tmpfs" "/root/.config/gh")
    [ "$WITH_GLAB" = "0" ] && [ "$WITH_GLAB_DIRECT" = "0" ] && MOUNT_ARGS+=("--tmpfs" "/root/.config/glab-cli")
    [ "$WITH_TFE" = "0" ]  && MOUNT_ARGS+=("--tmpfs" "/root/.terraform.d")
    [ "$WITH_AZ" = "0" ]   && MOUNT_ARGS+=("--tmpfs" "/root/.azure")
    # AWS has no in-container `login` step to preserve, so unlike gh it needs no
    # unmask state — the mask is on in both directions, only its scope changes.
    # Without --aws the whole directory is masked. With it, just the credential
    # cache, so the :ro host mounts at /root/.aws/config and /root/.aws/sso stay
    # visible to the session that asked for them. That cache is the point: the
    # scoped host mount above deliberately refuses to import ~/.aws/cli/cache
    # because it holds assume-role STS, and the CLI writes the same material to
    # the container's own copy — which, unmasked, persists on vibe-root
    # and reintroduces it by the back door.
    if [ "$WITH_AWS" = "0" ]; then
      MOUNT_ARGS+=("--tmpfs" "/root/.aws")
    else
      MOUNT_ARGS+=("--tmpfs" "/root/.aws/cli/cache")
    fi
    MOUNT_ARGS=(-v vibe-root:/root -v vibe-home:/root/.vibe "${MOUNT_ARGS[@]}")
  fi
}

run_container() {
  # CHOWN/SETUID/SETGID are needed by entrypoint.sh to chown /root and then
  # exec runuser. DAC_READ_SEARCH lets the chown step traverse HOST_UID-owned,
  # mode-0700 directories under /root — narrower than DAC_OVERRIDE since we
  # only need search/read, not write override. All four caps are
  # cleared from the effective/permitted/ambient sets when runuser
  # transitions UID 0 → host UID; the bounding set keeps them but is inert
  # under no-new-privileges, so vibe itself runs with no usable caps.
  # --init wraps the process tree under tini so vibe's shell/MCP children
  # get reaped — runuser would otherwise be PID 1 and wouldn't reap zombies.
  "$RUNTIME" run --rm -it --init \
    --security-opt no-new-privileges \
    --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_READ_SEARCH \
    -e "HOST_UID=${HOST_UID:-$(id -u)}" -e "HOST_GID=${HOST_GID:-$(id -g)}" \
    "${MOUNT_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    -w "$CWD" \
    "$IMAGE" \
    "${CMD[@]}"
}

main() {
  set -euo pipefail
  init_shell
  parse_args "$@"
  validate_opts
  select_runtime
  prune_stale_auth_proxy
  detect_msys
  build_workspace_mounts
  build_git_trust
  build_cred_mounts
  build_env_args
  discover_tokens
  build_git_config
  forward_git_identity
  build_flags_env
  create_stage
  start_auth_sidecar
  build_host_args
  stage_host_config
  stage_git_overlays
  stage_glab_config
  build_cmd
  build_volume_mounts
  run_container
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
