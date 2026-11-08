## 1. Image and pins

- [x] 1.1 Install `mistral-vibe` from a hash-locked `pins/vibe-requirements.txt` into a venv on a uv-managed CPython 3.13 under `/opt/vibe`, stripped of pip/ensurepip/tkinter; symlink `vibe` and `vibe-acp` into `/usr/local/bin`
- [x] 1.2 Assert at build time that `vibe --version` prints the pinned version and that the bundled `vibe-rs` is an ELF binary
- [x] 1.3 Replace the upstream agent's image ENV with `VIBE_ENABLE_UPDATE_CHECKS=false`, `VIBE_ENABLE_AUTO_UPDATE=false`, `VIBE_ENABLE_SYSTEM_TRUST_STORE=true`; `CMD ["vibe"]`
- [x] 1.4 Add `pins/vibe.env`, drop the upstream agent's pin; `update_pins.py` resolves `vibe` from PyPI with the default soak and writes its lock like `az`
- [x] 1.5 Keep the dockle accept list and scanner suppressions in step with the new image

## 2. Wrapper and entrypoint

- [x] 2.1 Rename every wrapper-visible name to the fork (`vibe-docker`, `VIBE_DOCKER_*`, `vibe-root` / `vibe-home`, `vibe-auth-*`, `mistral-vibe:local`)
- [x] 2.2 `--vibe-dir`; stage `agents/`, `skills/`, `prompts/`, `AGENTS.md` and `~/.agents/skills` read-only; seed `config.docker.toml` to `/root/.vibe/config.toml`
- [x] 2.3 `--yolo` → `--auto-approve`; extra workspaces → `--add-dir`
- [x] 2.4 Add `--mistral`; remove `--api`, `--api-direct`, `--egress-lock`, `--egress-allowlist`, the egress sidecar, the managed settings and the auth-proxy api site
- [x] 2.5 Entrypoint: `seed_config`, user `vibe`, CA glob `vibe-docker-*.crt`, no API key approval step
- [x] 2.6 Rewrite `--help`

## 3. Tests

- [x] 3.1 Re-target bats, smoke and integration tests to vibe; replace the `api` smoke cell with a `mistral` cell
- [x] 3.2 Delete the egress and api tests and the managed-settings precedence harness

## 4. CI

- [x] 4.1 Image tag `vibe-docker:ci`; drop the egress smoke, squid harness, egress-proxy scan and managed-settings steps
- [x] 4.2 Update workflow wording (pins updater, release)

## 5. Documentation

- [x] 5.1 Rewrite README and `docs/` for vibe, with the fork attribution
- [x] 5.2 Replace `examples/settings.docker.json` with `examples/config.docker.toml`
- [x] 5.3 Update `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `NOTICE`

## 6. OpenSpec

- [x] 6.1 Write the delta specs and remove the `api-egress-policy` capability
- [x] 6.2 Validate with `--strict` and archive
