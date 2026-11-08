# vibe-docker

[![GitHub release](https://img.shields.io/github/v/release/dtump/vibe-docker)](https://github.com/dtump/vibe-docker/releases)
[![License](https://img.shields.io/github/license/dtump/vibe-docker)](LICENSE)

vibe-docker is a fork of [schubergphilis/claude-docker](https://github.com/schubergphilis/claude-docker), maintained by Dick Tump, that runs Mistral Vibe instead of the upstream agent. The wrapper, the hardening and the forge integrations are carried over from it.

**vibe-docker runs [Mistral Vibe](https://github.com/mistralai/mistral-vibe) in a container on your machine.** Vibe works on the repositories you pass in, with the Mistral API as its model backend and your Git forge. Your Vibe setup (agents, skills, prompts, `AGENTS.md`) comes along read-only, and the image ships `gh`, `glab`, `aws`, `az` with the `azure-devops` extension, `openspec`, `uv`, `pnpm`, `tfenv`, `git-lfs`, `task` and a version-pinned `go`; `tfenv` and `uv` fetch your project's Terraform and Python on demand. The container narrows what the agent can reach: it sees only the directories you pass in, gets host credentials (`gh`, `glab`, `aws`, `tfe`, `az`, `MISTRAL_API_KEY`) only with a [flag](docs/auth.md#credential-opt-in), and is removed when the session ends. That makes it a safer place to let the agent work unattended than `vibe --auto-approve` on your host, though not a full sandbox: see the [threat model](docs/security.md#threat-model) and [Vision and scope](docs/vision-and-scope.md).

<img src="./assets/architecture.svg" alt="vibe-docker architecture: you give a task to Mistral Vibe, which runs in the vibe-docker container on your machine with your mounted workspace and opt-in config. It talks to the Mistral API (with the key from vibe's setup wizard, or your host's MISTRAL_API_KEY via --mistral) and to your Git forge (Azure DevOps via --az, GitLab via --glab, GitHub via --gh). The container sees only the directories you pass in, gets host credentials only with an opt-in flag, and is removed when the session ends." width="800">

## Quickstart

```bash
# Build the image from your checkout (one-time; rerun after Dockerfile or tool pins change)
docker build -t mistral-vibe:local .

# Put on your PATH (create ~/bin if it doesn't exist)
mkdir -p ~/bin
ln -s "$(pwd)/run.sh" ~/bin/vibe-docker
```

Then run it against a workspace:

```bash
vibe-docker ~/repo
```

On the first run Vibe asks for your Mistral API key (or a browser sign-in) and keeps it in the `vibe-home` volume, so later sessions start straight away. To use a key from your host environment instead, see [Mistral API key](docs/auth.md#mistral-api-key---mistral).

The build needs BuildKit — on a Homebrew `docker` CLI with Colima, see [BuildKit on Colima](docs/installation.md#buildkit-on-colima) first. On podman, see [Container runtime](docs/usage.md#container-runtime).

### Prebuilt image

Building from your checkout stays fully supported, and `run.sh` still defaults to `mistral-vibe:local`. Released versions are also published to `ghcr.io/dtump/vibe-docker` for `linux/amd64` and `linux/arm64`; point the wrapper at one with the `VIBE_DOCKER_IMAGE` override:

```bash
docker pull ghcr.io/dtump/vibe-docker:v0.1.0
export VIBE_DOCKER_IMAGE=ghcr.io/dtump/vibe-docker:v0.1.0
```

Pin the full `v`-prefixed tag — there is no `latest` and no `:0.1`. Only `linux/amd64` passes the publish pipeline's dockle, dive and grype scans; `linux/arm64` is published without them. See [Prebuilt image from GHCR](docs/installation.md#prebuilt-image-from-ghcr) for release candidates and the scan-coverage detail.

## Documentation

- [Vision and scope](docs/vision-and-scope.md) — what vibe-docker is for, its principles, defaults and options
- [Installation](docs/installation.md) — BuildKit on Colima, prebuilt image from GHCR
- [Usage](docs/usage.md) — container runtime, session flags, resuming sessions, host config parity, worktrees, tmux and iTerm2 panes, extending the image
- [Auth model](docs/auth.md) — credential opt-in flags, Mistral API key, AWS SSO, GitHub and GitLab auth proxy, Terraform Cloud, private registries, Azure DevOps Server CA
- [Security](docs/security.md) — threat model, image vulnerability scanning
- [Maintenance](docs/maintenance.md) — releasing, updating pinned tool versions, CI smoke tests
- [Windows](docs/windows.md) — PowerShell, WSL2 and Git Bash hosts
- [Scope](docs/scope.md) — what vibe-docker deliberately does not do
- [License](docs/license.md) — Apache 2.0 terms and warranty disclaimer

Behavioural requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).
