# Run Mistral Vibe instead of the upstream agent

## Why

vibe-docker is a fork of [schubergphilis/claude-docker](https://github.com/schubergphilis/claude-docker) for people who work with a Mistral subscription. The upstream image runs a different coding agent; this fork keeps everything around the agent (the hardened container, the credential opt-in model, the auth-proxy sidecar, the forge and cloud CLIs, workspaces and worktrees, the pin tooling) and swaps the agent itself for Mistral Vibe 3.1.0. The specs describe the upstream agent's mechanics (its settings file, statusline, permission-skip flag, model endpoint variables, an egress lock for its gateway) and need to describe vibe's instead.

## What Changes

- **BREAKING** The image runs `vibe` (PyPI `mistral-vibe`, pinned in `pins/vibe.env` and hash-locked in `pins/vibe-requirements.txt`) from its own uv-managed CPython 3.13 and venv under `/opt/vibe`, with `vibe` and `vibe-acp` symlinked into `/usr/local/bin`. Update checks and auto-update are off in the image; the system trust store is enabled for vibe.
- **BREAKING** Every name moves to the fork: wrapper `vibe-docker` (`vibe-docker.ps1` on PowerShell), image `mistral-vibe:local`, env prefix `VIBE_DOCKER_*`, volumes `vibe-root` (`/root`) and `vibe-home` (`/root/.vibe`), container user `vibe`, sidecar resources `vibe-auth-*` / `vibe-auth-proxy-*`, placeholder token `vibe-docker-proxy`, stage dir `$HOME/.cache/vibe-docker/`.
- **BREAKING** The config-dir flag becomes `--vibe-dir` (`VIBE_DOCKER_CONFIG_DIR`, default `~/.vibe`). Host config parity carries `agents/`, `skills/`, `prompts/`, `AGENTS.md` and `~/.agents/skills`, read-only; `config.docker.toml` is seeded to `/root/.vibe/config.toml` at every start. The upstream items without a vibe equivalent (commands, themes, the statusline script and its wrapper) are dropped.
- `--yolo` passes `--auto-approve` to vibe; extra workspaces are passed as `--add-dir`; everything after `--` still goes to the agent (`-- --resume`, `-- --continue`, `-- --trust`, `-- -p "…"`).
- New `--mistral` flag forwards the host's `MISTRAL_API_KEY` by name. Without it nothing model-related is forwarded, and vibe's setup wizard stores the key in `/root/.vibe/.env` in the `vibe-home` volume.
- **BREAKING** Removed: `--api`, `--api-direct`, `--egress-lock`, `--egress-allowlist`, the API CA, egress proxy image and egress allowlist variables, the squid egress sidecar and its image, the managed-settings mount, the api site of the auth-proxy sidecar, and the `IS_SANDBOX` image variable.
- The `vibe` pin uses the default 7-day soak; the shorter per-tool window the upstream agent had is gone.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `host-config-parity`: vibe config dir and items, `config.docker.toml` seed, `--vibe-dir`; drops the sandbox variable requirement.
- `persistent-session-storage`: `vibe-root` / `vibe-home`, session logs under `/root/.vibe/logs/session/`, the wizard's `.env` persists.
- `cli-help`: new flag list (`--mistral`, `--vibe-dir`; no api/egress flags), `config.docker.toml` note.
- `container-runtime`: names only (`VIBE_DOCKER_RUNTIME`, `vibe-docker.ps1`, `VIBE_DOCKER_ADD_HOSTS`, `VIBE_DOCKER_TRUSTED_WORKSPACES`).
- `external-cli-tools`: adds "Mistral API key opt-in"; removes "Custom model endpoint opt-in"; renames elsewhere.
- `multi-workspace-mounts`: vibe invocation, `--auto-approve`, `VIBE_DOCKER_FLAGS` instead of a statusline tag; two requirement titles lose the agent's name.
- `package-managers`: the npm install line no longer carries the agent; `VIBE_DOCKER_FLAGS` replaces the statusline tag.
- `version-pin-refresh`: one 7-day default soak for every tool; `vibe` writes a hash lock like `az`.
- `gh-auth-proxy`: sidecar and network names `vibe-auth-proxy-<id>` / `vibe-auth-<id>`, `VIBE_DOCKER_*` variables.
- `go-toolchain`: names, and the note that the CPython under `/opt/vibe` serves vibe only.
- `openspec-cli`: names only.

### Removed Capabilities

- `api-egress-policy`: every requirement. The lock existed to pin model traffic to a custom gateway, and the fork has no custom endpoint.

`image-distribution` and `image-vulnerability-scan` need no delta: their requirements name neither the registry path (it comes from the repository) nor the egress proxy image.

## Non-goals

- Custom model endpoints, gateways, other providers, or a sidecar that hides the Mistral key. vibe's own `providers` setting stays available in `config.docker.toml`, without wrapper support.
- Agents other than Mistral Vibe.
- Changing the tool set: `gh`, `glab`, `aws`, `az`, `openspec`, `uv`, `pnpm`, `tfenv`, `git-lfs`, `task`, `go` and Node stay as they are.

## Impact

- `Dockerfile`, `pins/`, `scripts/update_pins.py`, `run.sh`, `entrypoint.sh`, `vibe-docker.ps1`, the bats, smoke, integration and Python tests, CI workflows, README, `docs/`, `examples/config.docker.toml`.
- Existing upstream volumes and config dirs are not migrated: a fork user starts with fresh `vibe-root` / `vibe-home` volumes and `~/.vibe`.
