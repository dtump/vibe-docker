## MODIFIED Requirements

### Requirement: No credential plumbing or run.sh surface

The `openspec` CLI has no authentication or host-state requirements. Its presence SHALL NOT add any `run.sh` flag, bind-mount, env-var forward, or volume, and SHALL NOT alter any credential-handling behaviour defined by `external-cli-tools`.

#### Scenario: No new run.sh surface

- **WHEN** `vibe-docker --help` is invoked
- **THEN** no openspec-specific flag appears in the output
- **AND** neither `run.sh` nor `entrypoint.sh` contains an openspec-specific mount, env-var forward, or volume, so the set observed inside the container is identical to an image built without the CLI

#### Scenario: openspec works with zero host state

- **GIVEN** the host has no `openspec` install and no openspec-related env vars or config files
- **WHEN** the user runs `vibe-docker ~/repo` and, inside the container, `cd /workspaces/repo && openspec --help`
- **THEN** `openspec --help` succeeds

