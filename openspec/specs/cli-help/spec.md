# cli-help

## Purpose

Let users discover every `vibe-docker` wrapper flag directly from the terminal instead of reading `run.sh` or the README. `-h`/`--help` prints a self-contained per-flag reference and exits before any Docker or filesystem side effects, while preserving the `--` passthrough contract so `vibe-docker -- --help` still forwards `--help` to `vibe`.

## Requirements

### Requirement: Help flag prints usage and exits

`run.sh` SHALL recognise `-h` and `--help` as wrapper flags. When either appears in the argument list before the `--` separator, `run.sh` MUST print usage to stdout and exit 0 without starting a Docker container and without creating the host-config staging directory.

#### Scenario: --help alone

- **WHEN** user runs `vibe-docker --help`
- **THEN** usage text is printed to stdout and the process exits 0 with no `docker run` invocation

#### Scenario: -h alone

- **WHEN** user runs `vibe-docker -h`
- **THEN** usage text is printed to stdout and the process exits 0 with no `docker run` invocation

#### Scenario: --help mixed with other wrapper flags

- **WHEN** user runs `vibe-docker --aws --gh --help ~/repo`
- **THEN** usage text is printed to stdout and the process exits 0 with no `docker run` invocation and no `mktemp` staging directory left on disk

### Requirement: Flags after `--` are not intercepted

The `--` separator contract SHALL take precedence over help detection. Any occurrence of `-h` or `--help` after `--` MUST be forwarded verbatim to the `vibe` binary inside the container.

#### Scenario: --help after separator passes through

- **WHEN** user runs `vibe-docker -- --help`
- **THEN** `run.sh` launches the container and invokes `vibe --help`, and does NOT print `run.sh`'s own usage text

#### Scenario: -h after separator passes through

- **WHEN** user runs `vibe-docker ~/repo -- -h`
- **THEN** `run.sh` launches the container and invokes `vibe -h`

### Requirement: Help invocation has no side effects

When help is printed, `run.sh` SHALL NOT default an empty workspace list to `$PWD`, create a staging directory via `mktemp`, copy host vibe config, or invoke Docker. The only observable effect MUST be the stdout write and a zero exit status.

#### Scenario: No staging dir created

- **WHEN** user runs `vibe-docker --help`
- **THEN** no `host.*` directory is left under `$HOME/.cache/vibe-docker/` after the command returns

#### Scenario: No docker process spawned

- **WHEN** user runs `vibe-docker --help` on a host with no `docker` binary on PATH
- **THEN** the command still succeeds with exit 0

### Requirement: Help output describes every wrapper flag

The help output SHALL give a one-line description of every wrapper flag, grouped apart from the `--` passthrough contract. It SHALL also describe the `--` separator (arguments after it go to `vibe`), positional workspaces and the default to `$PWD`, the `VIBE_DOCKER_TMUX`, `VIBE_DOCKER_CONFIG_DIR`, `VIBE_DOCKER_AZ_CA` and `VIBE_DOCKER_ADD_HOSTS` variables, and that `config.docker.toml` is copied to `config.toml` in the container.

#### Scenario: All wrapper flags documented

- **WHEN** user runs `vibe-docker --help`
- **THEN** the output contains each of `--yolo`, `--ephemeral`, `--ro`, `--ro=PATH`, `--aws`, `--gh`, `--glab`, `--mistral`, `--az`, `--iterm`, `--tmux`, `--vibe-dir`, `-h`, `--help`, `--`, `VIBE_DOCKER_TMUX`, `VIBE_DOCKER_CONFIG_DIR`, `VIBE_DOCKER_AZ_CA`, `VIBE_DOCKER_ADD_HOSTS`, `MISTRAL_API_KEY`, and `config.docker.toml`
- **AND** it contains none of `--api`, `--api-direct`, `--egress-lock` or `--egress-allowlist`

#### Scenario: Each wrapper flag has an explanation

- **WHEN** user runs `vibe-docker --help`
- **THEN** every wrapper flag listed in the output is followed on the same or next line by a human-readable description of what it does (not just the flag name)

#### Scenario: --yolo names the vibe flag it passes

- **WHEN** user runs `vibe-docker --help`
- **THEN** the `--yolo` description mentions `--auto-approve`

#### Scenario: --mistral states what it exposes

- **WHEN** user runs `vibe-docker --help`
- **THEN** the `--mistral` description mentions `MISTRAL_API_KEY` and that the session can read it

#### Scenario: VIBE_DOCKER_TMUX values are listed

- **WHEN** user runs `vibe-docker --help`
- **THEN** the `VIBE_DOCKER_TMUX` description names the accepted values `1` and `cc`
