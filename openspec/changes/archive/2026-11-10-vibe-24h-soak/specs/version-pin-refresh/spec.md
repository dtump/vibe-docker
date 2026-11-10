## REMOVED Requirements

### Requirement: Soak-gated version resolution

**Reason**: `vibe` no longer shares the 7-day default window with every other tool; like the upstream fork's agent it gets a 1-day window.

**Migration**: Replaced by "Per-tool soak-gated version resolution" below, which gives `vibe` a 1-day default window and keeps 7 days for every other tool.

## ADDED Requirements

### Requirement: Per-tool soak-gated version resolution

For each automated tool the refresh tooling SHALL select the highest stable (non-prerelease) version published longer ago than the tool's soak window, else keep the current pin. Each tool SHALL carry its own default window: 1 day for `vibe`, 7 days for all others. `--soak` MAY set one window for every tool in that run; the soak gate that verifies committed pins SHALL apply the same per-tool windows.

#### Scenario: newest soaked version selected

- **GIVEN** tool X has versions 1.2.0 (published 20 days ago) and 1.3.0 (published 10 days ago) and the soak window is 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the resolved pin for X is 1.3.0

#### Scenario: too-new version held back by the soak

- **GIVEN** tool X is pinned at 1.3.0 and a version 1.4.0 was published 3 days ago with a soak window of 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the pin for X remains 1.3.0
- **AND** the report marks X as `held`, naming the in-soak version and its age

#### Scenario: no newer version available

- **GIVEN** the pinned version is already the newest released version
- **WHEN** the operator runs the refresh script
- **THEN** the pin is unchanged and the report shows no update for that tool

#### Scenario: vibe uses the 1-day window

- **GIVEN** `vibe` is pinned at 3.1.0 and version 3.1.1 was published 30 hours ago
- **WHEN** the operator runs the refresh script without `--soak`
- **THEN** the pin for `vibe` resolves to 3.1.1

#### Scenario: vibe holds a release younger than 1 day

- **GIVEN** `vibe` is pinned at 3.1.0 and version 3.1.1 was published 12 hours ago
- **WHEN** the operator runs the refresh script without `--soak`
- **THEN** the pin for `vibe` remains 3.1.0
- **AND** the report marks `vibe` as `held`, naming 3.1.1 as the in-soak version

#### Scenario: other tools keep the 7-day window

- **GIVEN** tool X (not `vibe`) is pinned at 1.3.0 and version 1.4.0 was published 30 hours ago
- **WHEN** the operator runs the refresh script without `--soak`
- **THEN** the pin for X remains 1.3.0
- **AND** the report marks X as `held`, naming 1.4.0 as the in-soak version

#### Scenario: --soak overrides every tool's window

- **GIVEN** tool X is pinned at 1.3.0 and version 1.4.0 was published 3 days ago
- **WHEN** the operator runs the refresh script with `--soak 2`
- **THEN** the resolved pin for X is 1.4.0
