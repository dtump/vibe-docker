## ADDED Requirements

### Requirement: Soak-gated version resolution

For each automated tool the refresh tooling SHALL select the highest stable (non-prerelease) version published longer ago than the soak window, else keep the current pin. Every tool, `vibe` included, SHALL share one default window of 7 days; `--soak` MAY set a different window for every tool in that run. The soak gate that verifies committed pins SHALL apply the same window.

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

#### Scenario: vibe keeps the 7-day window

- **GIVEN** `vibe` is pinned at 3.1.0 and version 3.1.1 was published 30 hours ago
- **WHEN** the operator runs the refresh script without `--soak`
- **THEN** the pin for `vibe` remains 3.1.0
- **AND** the report marks `vibe` as `held`, naming 3.1.1 as the in-soak version

#### Scenario: --soak overrides every tool's window

- **GIVEN** tool X is pinned at 1.3.0 and version 1.4.0 was published 3 days ago
- **WHEN** the operator runs the refresh script with `--soak 2`
- **THEN** the resolved pin for X is 1.4.0

### Requirement: Major version bumps are taken unless blocked

By default, selection SHALL include major-version increments (e.g. 10.x → 11.x); the tooling SHALL NOT restrict resolution to the currently-pinned major line. An operator MAY pass `--block-major-bumps` to constrain a run to the currently-pinned major; when set and the newest soaked version crosses the major, the tooling SHALL select the newest soaked version within the current major and SHALL report the crossed major as blocked.

#### Scenario: major version increment is selected and flagged

- **GIVEN** tool X is pinned at 10.33.2 and version 11.5.3 was published 9 days ago with a soak window of 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the resolved pin for X is 11.5.3
- **AND** the report marks the change as a major bump, visually distinct from minor/patch updates

#### Scenario: major bump suppressed under --block-major-bumps

- **GIVEN** tool X is pinned at 10.33.2, version 10.34.1 was published 15 days ago, and version 11.5.3 was published 9 days ago, with a soak window of 7 days
- **WHEN** the operator runs the refresh script with `--block-major-bumps`
- **THEN** the resolved pin for X is 10.34.1
- **AND** the report shows 11.5.3 as available but blocked by `--block-major-bumps`

## MODIFIED Requirements

### Requirement: Pins stored as per-tool lockfile fragments

Resolved pins SHALL be written to one version-controlled fragment file per tool (e.g. `pins/<tool>.env`) containing sourceable shell assignments. npm-backed tools (npm itself, openspec, pnpm) SHALL record a version only, relying on npm's signed integrity, and so SHALL PyPI-backed tools (`az`, i.e. `azure-cli-core`, and `vibe`, i.e. `mistral-vibe`) in their fragment, whose soak date is the release's first PyPI upload; alongside `pins/az.env` the script SHALL write `pins/az-requirements.txt`, and alongside `pins/vibe.env` it SHALL write `pins/vibe-requirements.txt`, each holding the tool's package and every transitive dependency hash-locked with `uv pip compile --universal --generate-hashes`; binary-download tools SHALL additionally record, per published architecture, the resolved download URL paired with the sha256 of the bytes at that URL (a single URL+sha for an arch-independent artifact such as tfenv or the `azure-devops` extension wheel). Fragment files SHALL be committed to version control, not fetched at build time.

#### Scenario: npm tool fragment carries version only

- **WHEN** the refresh script resolves `pnpm`
- **THEN** `pins/pnpm.env` contains the version assignment and no URL or sha256

#### Scenario: binary tool fragment carries version, per-arch URL, and per-arch hashes

- **WHEN** the refresh script resolves `glab`
- **THEN** `pins/glab.env` contains the version and, per published architecture, the download URL and the sha256 of that URL's bytes

#### Scenario: az pin writes its hash lock

- **WHEN** the refresh script writes `pins/az.env` for version V
- **THEN** it also writes `pins/az-requirements.txt` pinning `azure-cli-core==V` and every transitive dependency, each with a `--hash`


#### Scenario: vibe pin writes its hash lock

- **WHEN** the refresh script writes `pins/vibe.env` for version V
- **THEN** it also writes `pins/vibe-requirements.txt` pinning `mistral-vibe==V` and every transitive dependency, each with a `--hash`

## REMOVED Requirements

### Requirement: Soak-aware version resolution

**Reason**: The one-day window for the upstream agent is gone: every tool, `vibe` included, now shares the 7-day default.

**Migration**: Replaced by "Soak-gated version resolution" and "Major version bumps are taken unless blocked".

