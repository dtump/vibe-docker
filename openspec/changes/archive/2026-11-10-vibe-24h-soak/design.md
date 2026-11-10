## Context

`update_pins.py` already supports per-tool soak windows: `Tool` carries
`soak_days` (default `DEFAULT_SOAK_DAYS = 7`), `soak_days_for()` resolves the
window for a run (`--soak` overrides every tool), and both the refresh flow and
`--audit` read it. The 2026-11-08 change that replaced Claude Code with vibe
deliberately gave `vibe` no exception; this change reintroduces one, matching
the upstream fork's 24h window for its agent
(`openspec/changes/archive/2026-09-25-claude-code-24h-soak`).

## Decisions

**Set `soak_days=1` on the `vibe` `Tool` entry.** The per-tool mechanism already
exists and is exercised by tests; only the exception has to be declared.

**Keep `--soak` as a uniform run-wide override.** When passed, every tool —
`vibe` included — uses it for that run. This leaves existing invocations
unchanged and keeps the semantics simple.

**No workflow change.** `pins-updater.yml` passes `--soak` only when the dispatch
input is filled in; the schedule trigger passes nothing, so per-tool windows
apply. `--audit` in CI likewise calls the script without `--soak` and follows
`soak_days_for`, so it never rejects a `vibe` pin the refresh just selected.

## Risks

A 24-hour window gives less time to catch a compromised `vibe` release before it
lands in a pins PR. Two things limit that exposure: the pins PR is still
reviewed and built by a human before it merges, and the release is hash-locked
in `pins/vibe-requirements.txt` (`uv pip compile --generate-hashes`), so the
exact bytes are pinned and auditable regardless of the window.
