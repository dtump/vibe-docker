## Context

vibe-docker forks [schubergphilis/claude-docker](https://github.com/schubergphilis/claude-docker) to run Mistral Vibe 3.1.0. Everything around the agent stays: the privilege drop and capability set, the credential opt-in flags, the `--gh` auth-proxy sidecar, the forge and cloud CLIs, workspaces and the git overlays, the pin tooling and the scans. This change swaps the agent and removes what only made sense for the upstream agent.

Facts about vibe 3.1.0 the design relies on, checked against its source and README:

- PyPI package `mistral-vibe` (Apache-2.0). `vibe` is a small Python launcher that execs the bundled Rust TUI `vibe/_bin/vibe-rs` and finds `vibe-app-server` next to `sys.argv[0]` after `Path.resolve()`. It needs a GIL-enabled CPython 3.12 or later; manylinux_2_28 wheels exist for x86_64 and aarch64.
- State lives in `VIBE_HOME` (default `~/.vibe`): `config.toml`, `.env` (API keys from the setup wizard, mode 0600), `logs/session/` (needed by `--resume` / `--continue`), `trusted_folders.toml`, history, worktrees and caches. `~/.agents/skills/` is read as well.
- Auth: `MISTRAL_API_KEY` from the environment or `~/.vibe/.env`, the environment winning. With no key, the first run starts the setup wizard (`vibe --setup`).
- Config layers, low to high: defaults, user `~/.vibe/config.toml`, project `./.vibe/config.toml` (trusted folders only), `VIBE_*` environment, CLI, agent profile, admin. A `VIBE_*` variable set in the image beats both files.
- CLI: `--add-dir` (repeatable), `--auto-approve` / `--yolo`, `-p`, `--continue`, `--resume [ID]`, `--trust`, `--setup`, `--max-price`, and more.

## Goals / Non-Goals

**Goals:**

- Run vibe in the same hardened container, with the same opt-in model and the same tool set.
- Carry the user's vibe setup (agents, skills, prompts, global `AGENTS.md`, shared `~/.agents/skills`) into the container read-only, plus a container-specific `config.toml`.
- Keep the image reproducible from committed, hash-checked pins.

**Non-Goals:**

- Custom model endpoints, gateways or a key-hiding sidecar for the Mistral API.
- Migrating upstream volumes or config dirs.
- Supporting more than one agent.

## Decisions

### D1. vibe installed like `az`, hash-locked, in its own venv

uv installs a managed CPython 3.13 at `/opt/vibe/python`, a venv at `/opt/vibe/venv`, and `uv pip install --require-hashes -r pins/vibe-requirements.txt`. The lock is generated with `uv pip compile --universal --generate-hashes`, so one file covers both architectures. pip, ensurepip and tkinter are stripped from that Python as for `az`. `vibe` and `vibe-acp` are **symlinked** into `/usr/local/bin`: the launcher resolves `sys.argv[0]` to find `vibe-app-server`, so a copied wrapper script would break it. The Python is not on PATH; projects still fetch their own Python with `uv`.

*Alternatives:* `uv tool install` (no hash lock, state in a home directory that becomes a volume), the distribution's Python (outside the pin tooling). Both lose the reproducibility the `az` block already has.

The build asserts that `vibe --version` prints the pinned version and that `vibe-rs` is an ELF binary. The image sets `VIBE_ENABLE_UPDATE_CHECKS=false` and `VIBE_ENABLE_AUTO_UPDATE=false`, because updates come through pins, and `VIBE_ENABLE_SYSTEM_TRUST_STORE=true`, so the CAs the entrypoint installs (the `--gh` sidecar CA, `VIBE_DOCKER_AZ_CA`) are trusted by vibe's HTTP client too.

### D2. Pins

`update_pins.py` gains `Tool("vibe", "pypi", "mistral-vibe", …)` with the default 7-day soak and writes `pins/vibe-requirements.txt` the way `az` writes its lock. The upstream agent's one-day window existed because it shipped almost daily; vibe gets no exception, so every tool now shares one default window.

### D3. Wrapper mapping

- `--yolo` appends `--auto-approve`; extra workspaces become `--add-dir /workspaces/<name>`; arguments after `--` pass through unchanged.
- `--vibe-dir` / `VIBE_DOCKER_CONFIG_DIR` (default `~/.vibe`) name the host config dir. Copied read-only under `/root/.vibe/`: `agents/`, `skills/`, `prompts/`, `AGENTS.md`. `~/.agents/skills` is read from `$HOME/.agents` and mounted at `/root/.agents/skills`, with the same symlink rules. `hooks.toml` is not forwarded: host hooks are host-specific.
- `<config-dir>/config.docker.toml` is mounted at `/run/vibe-docker/config.toml` and copied by the entrypoint to `/root/.vibe/config.toml` (0600) at every start. A copy, not a bind mount, because vibe rewrites `config.toml` in place from `/config`, `/theme` and `/model`, and replacing a mountpoint fails with `EBUSY`.
- `VIBE_DOCKER_FLAGS` is still exported (the CSV of active opt-ins) for hooks and prompts to read. There is no statusline wrapper: vibe has no statusline script, and it shows cost in its own UI (`--max-price` caps it).
- `--tmux` / `--iterm` stay, for extended keys (Shift+Enter) and panes.

### D4. Model credentials: `--mistral`, nothing else

The fork is used with a Mistral subscription, so the wrapper supports exactly that:

- Default: nothing is forwarded. vibe's setup wizard stores the key in `/root/.vibe/.env` in the `vibe-home` volume, the same persistence model the upstream login had. Under `--ephemeral` it asks every session.
- `--mistral`: forward the host's `MISTRAL_API_KEY` by name, refuse to start when it is unset or empty. The key is readable in the container, like `--gh-direct`'s token; the threat model says so and lists the key in the rotation steps.

`--api`, `--api-direct`, `--egress-lock`, `--egress-allowlist`, their env vars, the squid sidecar, the managed-settings mount and the api site of the auth-proxy sidecar are removed. They existed to point the upstream agent at a gateway and pin it there. Without a custom endpoint the lock has nothing to pin, and keeping a large, security-relevant subsystem nobody uses would only be attack surface and maintenance.

*Alternative considered:* a sidecar holding the Mistral key, as `--gh` does. Deferred: vibe's provider config would have to point at the sidecar, and a session-writable `config.toml` could undo that; it needs its own design.

### D5. Names

Every user-visible name moves to the fork (see the proposal). No legacy prefixes are swept at startup: the fork has never created the upstream's resources.

## Risks / Trade-offs

- [Python dependencies add scanner findings] → bump inside the lock when vibe allows it, otherwise accept them in `.trivyignore` / `.grype.yaml` with a reason and expiry.
- [The Mistral key is readable in a `--mistral` session] → it is opt-in, documented next to `--gh-direct`, and the default path keeps the key in the volume instead of the host shell. A sidecar is the follow-up if needed.
- [A workspace's `.vibe/config.toml` can change settings] → vibe reads project config only in trusted folders, and trust is never granted automatically; the image's `VIBE_*` variables outrank project config.
- [Losing the egress lock] → sessions have the open network a default session always had; the threat model states it.
- [vibe's Rust TUI and Linux clipboard] → no clipboard tool in the image, so image paste does not work; documented, as before.
