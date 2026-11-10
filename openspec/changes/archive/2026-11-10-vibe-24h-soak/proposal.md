## Why

Every automated tool shares the 7-day default soak window, `vibe` included. That
window no longer matches how vibe is released: it ships almost daily, and most
users take each release within hours. A week-old pin puts the image several
releases behind what the ecosystem already runs, while the extra days add little
safety — a broken or malicious release of a tool with this many daily installs
is noticed and pulled within the first day. This is the same policy
claude-docker (the upstream fork) applied to Claude Code
(`openspec/changes/archive/2026-09-25-claude-code-24h-soak`): a 24-hour soak
for the agent itself, 7 days for everything else.

Concretely: the 2026-11-09 pins-updater run proposed *downgrading* vibe from
3.1.0 (released 2026-11-04, inside the 7-day window) to 3.0.4. With a 1-day
window the run keeps 3.1.0 and holds 3.1.1 (released 2026-11-09) until it has
soaked.

## What Changes

- `vibe` gets a per-tool soak window of 1 day in `update_pins.py`
  (`Tool(..., soak_days=1)`). Every other tool keeps `DEFAULT_SOAK_DAYS` (7).
- `--soak DAYS` stays a run-wide override and still applies to `vibe` when
  passed; `--audit` reads the same per-tool windows, so CI accepts a `vibe` pin
  that is 1 day old.
- The scheduled `pins-updater.yml` run passes no `--soak`, so it picks up the
  per-tool windows automatically.
- `docs/maintenance.md`, the `Dockerfile` comment, and the script docstring
  describe the per-tool windows.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `version-pin-refresh`: the `Soak-gated version resolution` requirement changes
  from one shared 7-day window to a 7-day default per tool with a 1-day window
  for `vibe`. An operator can still override the window for all tools in a
  single run with `--soak`.

## Impact

- `update_pins.py`: the `vibe` `Tool` sets `soak_days=1`; docstring and `--soak`
  help updated.
- `tests/test_update_pins.py`: coverage for the `vibe` 1-day default, that a
  30-hour-old release is selected under it, and that a younger one is held.
- Docs: `docs/maintenance.md`, `Dockerfile` comment.
- No runtime or image change beyond `vibe` pins moving up sooner.
