## ADDED Requirements

### Requirement: One session store for every workspace

Sessions from every workspace MUST live under the same `/root/.vibe/logs/session/` tree in the `vibe-home` volume, so a session started from one workspace can be resumed by ID from a container launched for another.

#### Scenario: Cross-workspace resume

- **GIVEN** a session with ID `abc123` was started in a container whose first workspace was `~/repo-a`
- **WHEN** the user runs `vibe-docker ~/repo-b -- --resume abc123`
- **THEN** vibe finds the session in the shared store and resumes it

## MODIFIED Requirements

### Requirement: Sessions persist across container runs

All vibe session logs, credentials (`/root/.vibe/.env`, written by vibe's setup wizard), trusted-folder answers and history SHALL live in named Docker volumes that survive `--rm` container lifecycles: `vibe-root` mounted at `/root` and `vibe-home` mounted at `/root/.vibe`.

#### Scenario: Sessions survive exit

- **WHEN** the user exits a vibe session and relaunches the container
- **THEN** prior session logs under `/root/.vibe/logs/session/` remain readable
- **AND** `vibe-docker ~/repo -- --continue` can resume the previous session of that workspace

#### Scenario: The API key from the setup wizard persists

- **GIVEN** a prior run completed vibe's setup wizard, which wrote `MISTRAL_API_KEY` to `/root/.vibe/.env`
- **WHEN** user runs `vibe-docker ~/repo` without `--mistral`
- **THEN** vibe starts without asking for a key again

### Requirement: Ephemeral mode opts out of persistence

`run.sh` SHALL support a `--ephemeral` flag that skips the `vibe-root` and `vibe-home` named-volume mounts. In this mode no API key from the setup wizard, `gh` login, shell history, trusted-folder answer, or session history persists between container runs. Intended for one-shot or untrusted-workspace sessions.

#### Scenario: --ephemeral leaves no trace

- **GIVEN** a prior run completed with session history in `vibe-home`
- **WHEN** user runs `vibe-docker --ephemeral ~/repo`
- **THEN** `/root/.vibe/logs/session/` starts empty inside the new container
- **AND** on exit, no writes under `/root/` or `/root/.vibe/` are retained in either named volume

## REMOVED Requirements

### Requirement: Single shared store across workspaces

**Reason**: vibe keeps sessions under `/root/.vibe/logs/session/` and resumes them by ID; the upstream agent's all-projects picker scenario no longer applies.

**Migration**: Replaced by "One session store for every workspace".

