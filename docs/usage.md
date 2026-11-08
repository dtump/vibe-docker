# Usage

[← Back to the README](../README.md)

## Container runtime

`vibe-docker` runs on **docker or podman**. With no configuration it auto-detects the engine, preferring `docker` and falling back to `podman` — so a podman-only host (including Windows via `podman machine` + WSL backend, and podman-as-docker Linux setups) works with zero setup and never hits `docker: command not found`.

To force an engine, set `VIBE_DOCKER_RUNTIME`:

```bash
VIBE_DOCKER_RUNTIME=podman vibe-docker ~/repo
```

The env var is the canonical mechanism: it works everywhere — scripts, CI, editor "run" integrations, and non-interactive shells all inherit it. If you want a shorter interactive spelling, an alias is optional sugar (not a substitute — an alias only resolves at an interactive prompt, so scripts and editors still need the env var):

```bash
alias vibe-podman='VIBE_DOCKER_RUNTIME=podman vibe-docker'
```

Only `docker` and `podman` are accepted; any other value is rejected before anything runs. The image build is the engine's own command — `podman build -t mistral-vibe:local .` on a podman host, mirroring the `docker build` line in the [Quickstart](../README.md#quickstart).

**Windows:** run `vibe-docker` from PowerShell (via the [`vibe-docker.ps1`](../vibe-docker.ps1) launcher), WSL2 or Git Bash — see [Windows](windows.md) for setup and the Git Bash specifics.

## Running vibe-docker

```bash
vibe-docker                               # current dir as workspace
vibe-docker ~/repo-a ~/repo-b             # multi-workspace
vibe-docker --yolo ~/repo                 # passes --auto-approve to vibe
vibe-docker ~/repo -- --resume            # resume a past session (any vibe flag goes after --)
vibe-docker ~/repo -- --trust             # trust the workspace for this session without the prompt
vibe-docker ~/repo -- -p "fix the tests"  # programmatic mode: one prompt, then exit
```

`vibe-docker --help` (or `-h`) prints every wrapper flag with a one-line explanation — the canonical reference.

The first workspace is Vibe's working directory; every further workspace is passed to Vibe as `--add-dir /workspaces/<name>`, so its `AGENTS.md` and `.vibe/` apply and file tools treat it like the working directory.

Credential flags (`--aws`, `--gh`, `--mistral`, …) are covered in [Credential opt-in](auth.md#credential-opt-in).

### Session flags

| Flag          | Effect                                                                                                                                |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `--ephemeral` | Skip the persistent named volumes. No in-container auth state, Mistral key, shell history, or session history persists across runs.   |
| `--ro`        | Mount every workspace read-only. Prevents the agent from modifying your code.                                                         |
| `--ro=PATH`   | Add PATH as a workspace mounted read-only; the others stay writable. Repeatable. Not isolation for untrusted repos.                   |
| `--yolo`      | Pass `--auto-approve` to vibe: every tool call runs without asking. See [Threat model](security.md#threat-model).                     |

`--ro` does **not** block credential flags or restrict network egress — for an isolated review session, combine `--ephemeral` and `--ro` and pass no credential flags:

```bash
vibe-docker --ephemeral --ro ~/untrusted-repo
```

To keep one repo writable and give the agent read-only access to others, pass those as `--ro=PATH`. A `--ro=PATH` counts as a workspace, so `$PWD` is only the default when no workspace is given at all; pass `.` to keep it. The first workspace is the working directory, `--ro=` ones included:

```bash
vibe-docker ~/repo --ro=~/shared-modules --ro=~/reference-repo
vibe-docker . --ro=../shared-modules    # $PWD writable, shared-modules read-only
vibe-docker --ro=. --ro=../shared       # both read-only; $PWD is the working dir
```

A `--ro=PATH` directory inside a writable workspace (`~/repo --ro=~/repo/vendor`), also through a symlink, is still writable through the outer mount; `vibe-docker` warns when it sees one. Passing one directory both read-write and read-only (`~/repo --ro=~/repo`, or through a symlink) is refused. So is passing it twice through a symlink in the same mode: workspaces are mounted by their real path, so both would be the same mount. These checks compare paths exactly, so on a case-insensitive filesystem (macOS default) `~/repo --ro=~/Repo/vendor` slips past them: type paths with their real case.

`--ro=PATH` protects that directory, not the rest of the session: the agent can still act on what it reads there by writing to the writable workspaces, including git hooks or an `.envrc` the host later runs. For an untrusted repo, use `--ro` so that every workspace is read-only, or give it a session of its own (`--ephemeral --ro`).

For `--iterm` / `--tmux`, see [Terminal: tmux and iTerm2 panes](#terminal-tmux-and-iterm2-panes). In-container `--yolo` narrows the blast radius compared to running on the host, but see [Threat model](security.md#threat-model) for what it does and doesn't protect.

### Resuming sessions

The container starts `vibe` directly, so there is no shell to type `vibe --resume` in. Pass the flag through the wrapper instead, after `--`:

```bash
vibe-docker ~/repo -- --resume                # pick from this workspace's sessions
vibe-docker ~/repo -- --resume <session-id>   # resume a specific session (a prefix of the ID is enough)
vibe-docker ~/repo -- --continue              # resume the most recent session
```

Inside a running session, `/resume` opens the same picker.

Sessions are listed per container path, `/workspaces/<basename>` of the first workspace. A session started from `~/repo` shows up in the picker only when you launch with a first workspace named `repo` again; two host directories with the same basename share one list. To reach a session from another workspace, resume it by ID. A workspace passed as a symlink is mounted, and named, as the directory it points to; `vibe-docker` says so when it starts.

Session history persists in the shared `vibe-home` volume (`~/.vibe/logs/session/`). Under `--ephemeral` it doesn't, so there is nothing to resume. Resuming needs Vibe's session logging, which is on by default; don't turn off `session_logging.enabled` in your `config.docker.toml` if you want it.

### Trusted folders

Vibe loads a workspace's own `AGENTS.md` and `.vibe/` (config, prompts, skills, agents, hooks) only from a folder you trust, and asks the first time it sees one that has them. Your answer is kept in `~/.vibe/trusted_folders.toml`, so in the `vibe-home` volume: it applies to later sessions with the same `/workspaces/<name>` path, and under `--ephemeral` you are asked every run. `vibe-docker` never trusts a folder for you. To skip the prompt for one session, pass `-- --trust`. Workspaces after the first are passed with `--add-dir`, which Vibe trusts for that session without asking. A workspace's `.vibe/` is instructions to a model with a shell, so trust only repos you would run yourself (see [Threat model](security.md#threat-model)).

### Cost

vibe-docker adds nothing for cost. Vibe shows the session's token use and cost with `/status`, in the container as on the host. For a programmatic run, `-- -p "…" --max-price DOLLARS` stops the run once it has spent that much.

## Host config parity

On every run, these items are copied at start and the copies are mounted read-only into the container at the equivalent path:

| Item                  | Container path          | Purpose                                                    |
| --------------------- | ----------------------- | ---------------------------------------------------------- |
| `~/.vibe/agents/`     | `/root/.vibe/agents/`   | custom agent profiles                                      |
| `~/.vibe/skills/`     | `/root/.vibe/skills/`   | custom skills                                              |
| `~/.vibe/prompts/`    | `/root/.vibe/prompts/`  | custom system, compaction and title prompts                |
| `~/.vibe/AGENTS.md`   | `/root/.vibe/AGENTS.md` | instructions for every project                             |
| `~/.agents/skills/`   | `/root/.agents/skills/` | skills in the [Agent Skills](https://agentskills.io) path  |

**Symlinks.** Each item, and each entry directly inside `agents/`, `skills/` or `prompts/`, may be one symlink you made, e.g. `skills/foo -> ~/repos/shared-config/skills/foo`. Its target must not be another symlink. When the item itself is a symlink (`skills -> ~/dotfiles/vibe/skills`), the entries in its target get no hop of their own: that directory may be one a session can write. Inside what those reach, a symlink is kept only when it is relative and stays inside the copied entry (`lib/run.sh`, `../SKILL.md`). Anything else is skipped with a `vibe-docker: skipping …` warning: a link chain, an absolute link, a link that climbs out of the entry. The reason: the link targets often live in a repo you also open as a workspace, and a session can write there, so following its links could copy another host file into the container.

Because these are copies, edits you make on the host during a session apply from the next start. A `.git` inside a copied entry is left out. The copy starts a few processes per file, so a very large config tree slows launch: about 3 s per 500 files on Linux, more on macOS and Git Bash.

The mounts are read-only: anything Vibe tries to save into them from inside the container fails. Edit them on the host and they apply on the next start. `~/.vibe/hooks.toml` is deliberately not forwarded: host hooks run host commands with host paths and would misfire in the container.

`TERM` and `COLORTERM` are forwarded from the host terminal, so Vibe renders in truecolor when the host does. Ghostty's `TERM=xterm-ghostty` resolves to the `ghostty` terminfo entry from Ubuntu's `ncurses-term`, so `tput`, `less` and `--tmux` recognise the terminal.

For `config.toml`, maintain a dedicated `~/.vibe/config.docker.toml` (any valid Vibe `config.toml`) — when present it's copied to `/root/.vibe/config.toml` at container start. A copy rather than a bind mount, because Vibe saves settings (from `/config`, `/theme`, `/model`) by renaming a temporary file over `config.toml`, and `rename()` over a mountpoint fails with `EBUSY` — so in-session settings changes actually save; they last for that container run, are re-seeded from the host file on the next start, and are never written back to the host. Keeping it separate from your host `config.toml` avoids dragging host-only settings (MCP servers that start host binaries, absolute host paths) into the container. Without the file, the container keeps whatever `config.toml` earlier sessions saved in the `vibe-home` volume. See [`examples/config.docker.toml`](../examples/config.docker.toml) for a starting point.

The image sets `VIBE_ENABLE_UPDATE_CHECKS=false`, `VIBE_ENABLE_AUTO_UPDATE=false` and `VIBE_ENABLE_SYSTEM_TRUST_STORE=true`. Vibe reads `VIBE_*` variables after `config.toml`, so these win over your config file: the image's Vibe is pinned and updated by rebuilding it, and the system trust store is where the entrypoint installs the auth-proxy and `--az` CAs.

### Alternate Vibe config dirs (`--vibe-dir`)

If you keep more than one host Vibe config (e.g. a personal `~/.vibe/` and a work-only `~/.vibe-work/`), point the wrapper at the one you want with `--vibe-dir=PATH` or the `VIBE_DOCKER_CONFIG_DIR` env var:

```bash
vibe-docker --vibe-dir=~/.vibe-work ~/repo
VIBE_DOCKER_CONFIG_DIR=~/.vibe-work vibe-docker ~/repo
```

The chosen dir takes the place of `~/.vibe` for every item under it in the parity table above (agents, skills, prompts, `AGENTS.md`, `config.docker.toml`). `~/.agents/skills/` is read from your home directory, not from the config dir.

### Git identity

`user.name` and `user.email` from your global git config (`~/.gitconfig`) are forwarded automatically as `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` so in-container `git commit` works out of the box with your real identity — no `git -c user.email=...` dance, no wrong-author commits. Not gated by a flag: identity is already public on every commit you've made. Signing keys, credential helpers, aliases, and hooks are NOT forwarded — those are host-specific (keychains, absolute paths) and would misfire inside the container.

### Active opt-ins in the container

`run.sh` exports `VIBE_DOCKER_FLAGS` into the container with the comma-separated list of active opt-ins (`aws`, `gh`, `gh-direct`, `glab`, `glab-direct`, `tfe`, `az`, `registry`, `mistral`, `ephemeral`, `ro`, `ro-partial`), for a hook, a prompt or your shell to read. It is set by the wrapper — not a user-tunable knob. `ro` means every workspace is read-only; `ro-partial` means only the `--ro=PATH` ones are. It reports mount flags, not effective protection: a read-only workspace inside a writable one still shows `ro-partial`. `--yolo` is not listed — Vibe's own mode indicator already shows auto-approve.

## File ownership

Files created inside the container appear on the host owned by the user who launched `vibe-docker`, not by `root`. The wrapper forwards `HOST_UID` / `HOST_GID` and the in-container entrypoint creates a matching `vibe` passwd entry and drops to it via `runuser` before exec'ing vibe. Persistent state in the `vibe-root` and `vibe-home` named volumes is chowned on first start, so an existing volume is fixed up the next time you run `vibe-docker`. OS-level hardening comes from `--cap-drop ALL` (with `CHOWN`, `SETUID`, `SETGID`, `DAC_READ_SEARCH` re-added for transient entrypoint use only), `--security-opt no-new-privileges`, the Docker default seccomp profile, `--init` (tini reaps subprocess zombies), and the bind-mount layout; see [Threat model](security.md#threat-model).

Git's ownership check never refuses a workspace you own. `vibe-docker` checks on the host that you own each workspace and its git directory (the `.git` directory, or for a worktree or submodule the git directory its `.git` file points to; a `.git` symlink is never trusted), and the entrypoint then trusts it in the container's system git config (`/etc/gitconfig`, `safe.directory = /workspaces/<name>` and the worktrees nested in it). That absorbs an owner the mount misreports, as Windows NTFS mounts always do (there every workspace is trusted, since ownership means nothing). A workspace that belongs to another host user gets no entry, and `vibe-docker` says so at start: git refuses it as it would on the host, so another user's hooks or `core.fsmonitor` never run in your session. The exception is such a workspace passed inside one you own: the outer entry covers it, and `vibe-docker` warns that it is trusted anyway. Git also still refuses a repository elsewhere in the container whose owner differs. Because the setting lives at system scope, a `GIT_CONFIG_*` export that adds entries doesn't remove it, and neither does a tool running git with a cleaned environment. Only a deliberate reset drops it: `GIT_CONFIG_NOSYSTEM=1`, or an empty `safe.directory` value. Don't add `safe.directory` entries to `~/.gitconfig`. Delete any that older sessions left there (`git config --global --unset-all safe.directory`). That file is in the persistent volume, so an entry such as `*` would keep widening trust beyond `/workspaces` in every later session.

## Git worktrees

Git worktrees embed the path between the worktree and its repo's `.git/` in two link files. By default those paths are absolute, so a worktree created on the host breaks inside the container (and vice versa) because the same files sit at different absolute paths in each environment.

**No host config change needed.** For every workspace whose `.git/config` is a regular file (i.e. the main repo, not a worktree pointer), `vibe-docker` overlays a container-only copy of `.git/config` that declares `extensions.relativeWorktrees = true` and `worktree.useRelativePaths = true`. The host's on-disk `.git/config` is never touched. Worktrees created inside the container therefore get relative paths, and those link files are then portable to the host without any opt-in. A `.git` or `.git/config` that is a symlink is never followed, including one swapped in while `vibe-docker` starts: that workspace gets no overlay, because the workspace is container-writable and following the link could copy a host file from outside it into the container.

This asymmetry is deliberate: the extension flag — when written into the host's `.git/config` — blinds tools that bundle an older libgit2 (notably `gitstatusd`, which powers the Powerlevel10k git prompt), because they refuse to open a v1 repo declaring an extension they don't know. Keeping the flag container-only sidesteps that.

To convert pre-existing absolute-path worktrees, ask Vibe to run `git worktree repair --relative-paths <worktree-path>`, or type it yourself as `! git worktree repair --relative-paths <worktree-path>`. New worktrees added in the container get relative paths automatically.

**Trade-off:** container-side `git config` writes (e.g. `git remote add ...` writing to local config) land in the ephemeral overlay and are discarded when the container exits. Persistent `git config` edits should happen on the host.

**Fallback — `git worktree repair` (no flag):** ask Vibe to run it, or type `! git worktree repair`.

Use this when you passed a repo and a _sibling_ worktree as separate workspace args (`vibe-docker ~/repo ~/repo-feature`). Sibling-flattened mounts collapse the parent directory, so the relative offset between worktree and repo is not preserved by the bind mount and relative paths can't help.

**Caveats:**

- The overlay only applies to workspaces whose `.git` is a real directory (the main repo). If you mount only a worktree without its main repo, no overlay is created for it. Mount the main repo alongside if you need bidirectional worktree work.
- Relative paths assume the worktree's location relative to the repo's `.git/` is the same in both environments. Nested layouts (e.g. `<repo>/.worktrees/<name>`) always satisfy this; moving a worktree to a totally different parent dir breaks both relative and absolute setups.
- Vibe's own `-- --worktree NAME` creates its worktree under `~/.vibe/worktrees/`, which is in the `vibe-home` volume, not in your workspace: the host never sees it, and under `--ephemeral` it is gone when the session ends. Push its branch, or create the worktree inside the workspace with `git worktree add` instead.

## Networks without DNS

The container uses the host's DNS server but not the host's `/etc/hosts`, so a forge reachable on the host only through an `/etc/hosts` entry doesn't resolve inside it, and `git push` over HTTPS, `gh`, `glab` and `az` fail. Set `VIBE_DOCKER_ADD_HOSTS` to the same entries, comma-separated:

```bash
export VIBE_DOCKER_ADD_HOSTS=gitlab.example.com:10.1.2.3,devops.example.com:10.1.2.4
```

Each entry is passed to the runtime as `--add-host`, and so lands in the container's `/etc/hosts`; the auth-proxy sidecar (`--gh`, `--glab`) gets them too. Entries for the hosts the sidecar intercepts (`github.com`, `api.github.com` and `uploads.github.com` under `--gh`, the proxied GitLab host under `--glab`) are skipped for the agent container with a warning, since those must resolve to the sidecar. An entry that isn't `host:ip` stops `vibe-docker` before any container starts.

## Pasting images

`Cmd-V` to paste a clipboard image doesn't work inside the container — the container has no access to the host clipboard, and the image ships none of the Linux clipboard tools (`wl-copy`, `xclip`, `xsel`) Vibe would use. Workaround: save the image into any workspace you mounted (e.g. `Cmd-Shift-4` to Desktop, then move it into `~/repo`) and reference it in your prompt with `@screenshot.png`; Vibe sends `.png`, `.jpg`, `.jpeg`, `.gif` and `.webp` files to vision-capable models. Copying text out of Vibe works through the terminal (OSC 52), or with Shift held while selecting to use the terminal's own selection.

## Terminal: tmux and iTerm2 panes

The container can run Vibe inside tmux, for split panes next to it and for a terminal that reports Shift+Enter (the image's tmux config enables extended keys, so Shift+Enter and Alt+Enter insert a newline; Ctrl+J works everywhere). Two modes:

| Flag               | Env var equivalent    | Effect                                                                                                   |
| ------------------ | --------------------- | -------------------------------------------------------------------------------------------------------- |
| _(none — default)_ | _(unset)_             | No tmux. Vibe runs directly in your terminal.                                                            |
| `--tmux`           | `VIBE_DOCKER_TMUX=1`  | Plain tmux, session `vibe`. Split panes in one terminal tab; switch with `C-b` + arrow keys. Any terminal. |
| `--iterm`          | `VIBE_DOCKER_TMUX=cc` | `tmux -CC` (iTerm2 control mode). Panes are **native iTerm2 panes/tabs**. macOS + iTerm2 only.           |

The env vars are handy for `export` in your shell rc; the flags are handy for one-offs.

### iTerm2 tips for `cc` mode

- Launch from a tab that is **not** already inside a host `tmux -CC` session — nesting degrades the inner server to plain splits.
- iTerm2 → Settings → General → tmux → Attaching → **"When attaching, restore windows as:"** → `Tabs in the attaching window` keeps the gateway and Vibe's content inside one iTerm2 window (default is `Native windows`, which spawns a separate window).
- iTerm2 → Settings → General → tmux → **"Automatically bury the tmux client session after connecting"** → hides the `** tmux mode started **` gateway tab on attach so only the Vibe tab is visible. Retrieve the gateway later via Session → Buried Sessions if needed.
- The image sets `LANG=C.UTF-8` and `run.sh` passes `tmux -u`, so tmux renders UTF-8.

## Extending the image

When a project needs extra tooling (language runtimes, package managers, project-scoped CLIs) that doesn't belong in the base image, build a child image and reuse this wrapper via the `VIBE_DOCKER_IMAGE` env var — no need to fork `run.sh`.

In the child repo:

```dockerfile
# .vibe-docker/Dockerfile
FROM mistral-vibe:local
RUN ...   # add your extras here
```

```bash
#!/usr/bin/env bash
# vibe-docker (project-root entrypoint)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
IMAGE="mistral-vibe-myproject:local"
docker build -t "$IMAGE" "$here/.vibe-docker"
VIBE_DOCKER_IMAGE="$IMAGE" exec vibe-docker "$@"
```

The child Dockerfile uses `FROM mistral-vibe:local` (locally-built tag) — assumes the base has been built once on the host. Every wrapper flag (`--aws`, `--gh`, `--ephemeral`, `--ro`, `--iterm`, …) keeps working because the child script just exec's into this one with a different image tag.

Any extra package managers a child image installs (rustup, go, ruby, etc.) _add_ to the runtime code-fetch surface noted under [Threat model](security.md#threat-model) — they don't replace the existing `npx`/`pnpm dlx`/`uvx` primitives.
