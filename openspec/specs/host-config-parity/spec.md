# host-config-parity

## Purpose

Make the container feel like the user's host Mistral Vibe: same agents, skills, prompts, global `AGENTS.md`, shared `~/.agents/skills`, and a container-specific `config.docker.toml` when the user provides one — without copying host-specific configuration or host hooks that would misfire inside the Linux container.

The host config directory defaults to `~/.vibe` but is configurable via `--vibe-dir=PATH` or the `VIBE_DOCKER_CONFIG_DIR` env var. This supports users who keep more than one vibe setup (e.g. a personal and a work profile), each with its own config directory.

## Requirements

### Requirement: Configurable host config directory

`run.sh` SHALL read all host config items from a single base directory. The base directory defaults to `~/.vibe` and MAY be overridden with `--vibe-dir=PATH` (flag) or `VIBE_DOCKER_CONFIG_DIR` (env var). When both are provided, the flag takes precedence. The `~/.agents/skills` item is the one exception: it is read from `$HOME/.agents`, not from the base directory (see "Bind-mount host Vibe config items").

#### Scenario: Alternate config dir is used

- **GIVEN** `~/.vibe-work/` contains a `prompts/` directory with custom system prompts
- **WHEN** user runs `vibe-docker --vibe-dir=~/.vibe-work ~/repo`
- **THEN** `/root/.vibe/prompts/` in the container contains the prompts from `~/.vibe-work/prompts/`

#### Scenario: Env var sets the config dir

- **GIVEN** `VIBE_DOCKER_CONFIG_DIR=~/.vibe-work` is set in the environment
- **WHEN** user runs `vibe-docker ~/repo`
- **THEN** config items are loaded from `~/.vibe-work/` as if `--vibe-dir=~/.vibe-work` had been passed

### Requirement: Forward terminal colour capability

`run.sh` SHALL forward the host's `COLORTERM` to the container alongside `TERM`, when it is set. Terminal programs pick truecolor or 256-colour output from these variables; without `COLORTERM` the TUI falls back to 256 colours in the container and renders theme colours rounded to the nearest palette entry, so a theme looks different from the host. When `COLORTERM` is unset on the host it SHALL stay unset in the container.

#### Scenario: Truecolor terminal renders exact theme colours

- **GIVEN** the host terminal sets `COLORTERM=truecolor`
- **WHEN** user runs `vibe-docker`
- **THEN** `COLORTERM=truecolor` is set in the container
- **AND** the vibe TUI renders theme colours as 24-bit escape sequences, as it does on the host

### Requirement: Ghostty terminal type resolves in the container

The image SHALL resolve `TERM=xterm-ghostty`, the value Ghostty sets and `run.sh` forwards, to a terminfo entry. The entry SHALL come from the image's `ncurses-term` package: the build SHALL alias `xterm-ghostty` to the package's `ghostty` entry. The build SHALL fail if `infocmp xterm-ghostty` does not resolve.

#### Scenario: ncurses programs recognise Ghostty

- **GIVEN** the host terminal is Ghostty, with `TERM=xterm-ghostty`
- **WHEN** user runs `vibe-docker` and, inside the container, `tput colors`
- **THEN** `tput` succeeds instead of failing with `unknown terminal "xterm-ghostty"`

#### Scenario: Entry comes from the image's package

- **WHEN** a reader inspects how the image provides `xterm-ghostty`
- **THEN** it is a link to the `ghostty` entry shipped by `ncurses-term`
- **AND** no terminfo source is downloaded or vendored into the repository

### Requirement: Bind-mount host Vibe config items

`run.sh` SHALL copy these host items, when present, into the stage directory and bind-mount the copies read-only: `agents/`, `skills/`, `prompts/` and `AGENTS.md` from the config directory at the same path under `/root/.vibe/`, and `$HOME/.agents/skills/` at `/root/.agents/skills/`, the latter only when the config directory is the default `~/.vibe` or exists. No host path of these items SHALL be bind-mounted directly. Host `hooks.toml` SHALL NOT be carried over: host hooks are host-specific.

#### Scenario: Global instructions reach the container

- **GIVEN** host has `~/.vibe/AGENTS.md`
- **WHEN** user runs `vibe-docker` and `vibe` starts
- **THEN** `/root/.vibe/AGENTS.md` in the container is a read-only copy of the host file

#### Scenario: Shared agent skills reach the container

- **GIVEN** host has `~/.agents/skills/review/SKILL.md` and the default config directory
- **WHEN** user runs `vibe-docker`
- **THEN** `/root/.agents/skills/review/SKILL.md` in the container is a read-only copy of the host file

#### Scenario: Host hooks stay on the host

- **GIVEN** host has `~/.vibe/hooks.toml`
- **WHEN** user runs `vibe-docker`
- **THEN** no copy of it is mounted into the container

### Requirement: Host config items and entries follow at most one symlink

Each host config item, and each entry directly inside `agents/`, `skills/`, `prompts/` or `~/.agents/skills/`, MAY be one symlink. Its target, trailing slashes removed, SHALL be used when it exists, does not end in `.` or `..`, and is not itself a symlink; otherwise it SHALL be skipped with a warning. When an item is a symlink, its entries SHALL get no hop of their own: the item's target may be a directory a session can write.

#### Scenario: Skills via symlinks resolve in container

- **GIVEN** `~/.vibe/skills/create-team` is a symlink to `~/repos/shared-config/skills/create-team`
- **WHEN** user runs `vibe-docker`
- **THEN** `/root/.vibe/skills/create-team/` in the container contains the skill files (not a dangling symlink)

#### Scenario: Top-level directory symlink resolves in container

- **GIVEN** `~/.vibe-work/prompts` is a symlink to `~/vibe-config/prompts`
- **WHEN** user runs `vibe-docker --vibe-dir=~/.vibe-work ~/repo`
- **THEN** `/root/.vibe/prompts/` in the container contains the files from `~/vibe-config/prompts/`

#### Scenario: A link planted in a linked item's target is not followed

- **GIVEN** `~/.vibe/skills` is a symlink to `~/dotfiles/vibe/skills`, and `~/dotfiles` is open as a workspace
- **AND** a session has created `~/dotfiles/vibe/skills/x` as a symlink to `~/.ssh`
- **WHEN** user next runs `vibe-docker`
- **THEN** `x` is skipped with a warning
- **AND** nothing from `~/.ssh` is copied into the container

#### Scenario: A link chain is refused

- **GIVEN** `~/.vibe/skills` is a symlink to `~/hop`, itself a symlink to a directory; or `~/.vibe/skills/foo` links to a path (with or without a trailing slash) a session has replaced with a symlink; or `~/.vibe/AGENTS.md` links to a file that is a symlink
- **WHEN** user runs `vibe-docker`
- **THEN** that item or entry is not copied or mounted, and `run.sh` prints a `vibe-docker: skipping` warning

### Requirement: Links inside a copied host config entry are not followed

Inside a copied entry no symlink SHALL be followed. A symlink SHALL be kept only when its target is relative, consists of leading `../` components (no more than its depth below the entry) followed by plain names, and so resolves inside the entry; any other SHALL be skipped with a warning. A `.git` inside a copied entry SHALL NOT be copied.

#### Scenario: Relative links inside a linked skill are kept

- **GIVEN** `~/.vibe/skills/foo` links to `~/repos/x/skills/foo`, which contains `entry -> lib/run.sh` and `lib/up -> ../SKILL.md`
- **WHEN** user runs `vibe-docker`
- **THEN** both links exist in `/root/.vibe/skills/foo/` and resolve to the copied files

#### Scenario: A link planted inside a linked skill is not followed

- **GIVEN** `~/.vibe/skills/foo` links to `~/repos/x/skills/foo`, and a session has added `key -> ~/.ssh/id_ed25519`, `rel -> ../../../.ssh/id_ed25519` and `lib/root -> ../..` there
- **WHEN** user runs `vibe-docker`
- **THEN** none of those links, nor the key's contents, appear in the stage directory or the container
- **AND** `run.sh` prints a `vibe-docker: skipping` warning naming each skipped link

### Requirement: Host config is read without following swapped-in symlinks

Every file and directory SHALL be read without following a symlink swapped in while `run.sh` reads it: each directory SHALL be entered and checked to be the inode `lstat` names, and each file opened and checked the same way. A session can write any workspace, and link targets often live in a repo the user also opens as one, so following a link there could copy another host file into the container.

#### Scenario: A directory swapped for a symlink during staging is not followed

- **GIVEN** `~/.vibe/skills/foo` is a directory that a session replaces with a symlink to `~/.ssh` while `run.sh` is copying it
- **WHEN** `run.sh` enters it
- **THEN** the inode check fails, the entry is skipped with a warning, and nothing from `~/.ssh` is copied

### Requirement: The host config stage directory lives under $HOME

The stage directory MUST reside under `$HOME` (e.g. `$HOME/.cache/vibe-docker/host.XXXXXX`). Colima's default mount config shares only `$HOME` with its Linux VM, not `/tmp` or `$TMPDIR`, and a bind mount from outside it silently yields an empty mountpoint; Docker Desktop shares `$HOME` too, so it is the one location that works on both.

#### Scenario: Copies are visible under Colima

- **GIVEN** a Colima host with its default mount config
- **WHEN** user runs `vibe-docker` with `~/.vibe/skills/` present
- **THEN** the stage directory is under `$HOME/.cache/vibe-docker/`
- **AND** `/root/.vibe/skills/` in the container is not empty

### Requirement: Container-specific config file

When `<config-dir>/config.docker.toml` exists, `run.sh` SHALL copy it into the stage directory under the same symlink rules as `AGENTS.md` and bind-mount the copy read-only at `/run/vibe-docker/config.toml`, and `entrypoint.sh` SHALL copy that seed to `/root/.vibe/config.toml` with mode `0600` at every start. When it is absent, no file SHALL be seeded and a `config.toml` already in the home volume SHALL be left as-is. The host's own `config.toml` SHALL never be forwarded.

#### Scenario: Container uses dedicated settings file

- **GIVEN** `~/.vibe/config.docker.toml` contains `theme = "mistral-dark"`
- **WHEN** user runs `vibe-docker`
- **THEN** `/root/.vibe/config.toml` in the container is a writable copy of that file with mode `0600`

#### Scenario: Alternate config dir with config.docker.toml

- **GIVEN** `~/.vibe-work/config.docker.toml` exists
- **WHEN** user runs `vibe-docker --vibe-dir=~/.vibe-work ~/repo`
- **THEN** `/root/.vibe/config.toml` in the container is a copy of `~/.vibe-work/config.docker.toml`

#### Scenario: No settings file

- **GIVEN** `config.docker.toml` does not exist in the config dir
- **WHEN** user runs `vibe-docker`
- **THEN** the container starts without a host-derived `config.toml` seed and vibe uses defaults (or whatever a previous run persisted in the home volume)

### Requirement: The seeded config file is a regular file

The container-side `config.toml` MUST be a regular file, not a mountpoint: vibe rewrites it when settings change in-session (`/config`, `/theme`, `/model`), and replacing a mountpoint fails with `EBUSY`. In-session changes SHALL therefore save, last for that container run, and be overwritten from the host file on the next start; nothing SHALL be written back to the host.

#### Scenario: In-session settings change saves without EBUSY

- **GIVEN** the container started with a seeded `/root/.vibe/config.toml`
- **WHEN** vibe rewrites `/root/.vibe/config.toml` (e.g. the user changes theme or model in-session)
- **THEN** the write succeeds and the change applies for the rest of the run
- **AND** the host `config.docker.toml` is unchanged
- **AND** the next container start re-seeds `config.toml` from the host file
