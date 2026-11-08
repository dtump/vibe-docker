## MODIFIED Requirements

### Requirement: GitHub token is isolated from the agent container

When `--gh` is passed and a host token is found, the token SHALL be provided only to the sidecar proxy container's environment. It SHALL NOT be present in the agent container's environment, process table, or filesystem, and SHALL NOT be recoverable via `gh auth token` inside the agent container. The agent container SHALL receive the fixed placeholder `GH_TOKEN=vibe-docker-proxy` so `gh` treats itself as authenticated; the sidecar SHALL replace any client-supplied `Authorization` header with the real one, so the placeholder value never reaches GitHub.

One request class is exempt from that injection. On `github.com`, a `HEAD` request whose path matches `^/[^/]+/[^/]+/releases/download/.+` SHALL be forwarded with the `Authorization` header **removed** rather than replaced, so it reaches GitHub anonymously. The header SHALL be deleted, not merely left uninjected: GitHub selects a release asset's CDN on the *presence* of an `Authorization` header regardless of its value, so forwarding the client's placeholder would have the same effect as forwarding the real token. A `HEAD` carrying any credential is answered with a redirect to a legacy `objects.githubusercontent.com` pre-signed URL that then fails `401` for every method, which makes release-asset URLs unusable for any client that probes with `HEAD` before `GET`.

The exemption SHALL be scoped to that method and path only. `GET` on the same path SHALL continue to receive the injected credential, as SHALL git smart-HTTP, git-LFS, `/archive/`, `/raw/`, and all `api.github.com` / `uploads.github.com` traffic. The exemption removes no authenticated capability: `github.com`'s web release-download endpoint does not honour token authentication, so an asset in a private repository is unreachable by that URL with or without the credential — the API asset endpoint (`GET /repos/{owner}/{repo}/releases/assets/{id}` with `Accept: application/octet-stream`, as used by `gh release download`) is the supported route and is unaffected.

#### Scenario: Token not visible inside the agent container

- **GIVEN** the host has a GitHub token (env or `gh auth token`)
- **WHEN** user runs `vibe-docker --gh ~/repo`
- **THEN** `echo $GH_TOKEN` inside the agent container prints `vibe-docker-proxy`
- **AND** `gh auth token` inside the agent container does not output the host token
- **AND** the host token appears nowhere in `/proc/1/environ` inside the agent container

#### Scenario: gh and git still work authenticated

- **GIVEN** the sidecar is active with a valid host token
- **WHEN** `gh api /user` and a `git push` to a private `https://github.com/...` remote run inside the agent container
- **THEN** both succeed as the host token's identity, without any credential prompt

#### Scenario: Release-asset HEAD probe is forwarded anonymously

- **GIVEN** the sidecar is active
- **WHEN** a `HEAD` request for `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>` is made from the agent container
- **THEN** the request reaches GitHub with no `Authorization` header, whether or not the client sent one
- **AND** the response redirects to `release-assets.githubusercontent.com` rather than `objects.githubusercontent.com`

#### Scenario: Release-asset GET keeps its injected credential

- **GIVEN** the sidecar is active
- **WHEN** a `GET` request for the same release-asset URL is made from the agent container
- **THEN** the request reaches GitHub carrying the injected `Basic base64(x-access-token:<token>)` header

#### Scenario: uv installs from a public release-asset URL with no flags

- **GIVEN** the sidecar is active
- **WHEN** `uvx --with https://github.com/<owner>/<repo>/releases/download/<tag>/<wheel> <tool>` runs inside the agent container with no additional flags or environment overrides
- **THEN** the wheel downloads and the tool runs


### Requirement: Sessions are isolated and cleaned up

Each `run.sh` invocation with an active sidecar SHALL create its own container network and sidecar with names unique to the invocation (`vibe-auth-<id>` / `vibe-auth-proxy-<id>`). Concurrent sessions SHALL NOT share networks, sidecars, CAs, or token copies. On exit, `run.sh` SHALL remove the session's sidecar and network via the existing EXIT trap.

#### Scenario: Two concurrent sessions do not interfere

- **GIVEN** two simultaneous `vibe-docker --gh` sessions
- **WHEN** both perform authenticated GitHub operations
- **THEN** each session's traffic transits only its own sidecar
- **AND** the two sidecars hold independent CAs (roots differ)

#### Scenario: Teardown removes session resources

- **WHEN** a `vibe-docker --gh` session exits
- **THEN** its sidecar container and session network no longer exist


### Requirement: Works out of the box, fails closed

The sidecar SHALL run a digest-pinned upstream Caddy image (override: `VIBE_DOCKER_PROXY_IMAGE`) requiring no user-built image and no manual configuration beyond the existing `--gh` flag. If no host token is found, `run.sh` SHALL skip the sidecar silently and behave as the legacy no-token fallback. If a token was found but the sidecar fails to start or its CA cannot be retrieved within the startup timeout, `run.sh` SHALL tear down the session resources and exit with an actionable error; it SHALL NOT silently fall back to forwarding the real token into the agent container.

#### Scenario: First use requires no setup

- **GIVEN** a host that has never used the proxy but is authenticated with `gh`
- **WHEN** user runs `vibe-docker --gh ~/repo`
- **THEN** the sidecar image is pulled automatically and authenticated GitHub access works with no additional steps

#### Scenario: Sidecar startup failure is fatal, not degraded

- **GIVEN** a host token was found but the sidecar cannot start (e.g. image unavailable)
- **WHEN** user runs `vibe-docker --gh ~/repo`
- **THEN** `run.sh` exits non-zero with an error identifying the sidecar failure
- **AND** the real token is not forwarded into the agent container


### Requirement: Request filtering policy

The sidecar SHALL enforce request policy before forwarding. The default policy SHALL block repository deletion — `DELETE` requests matching `^/(repos/[^/]+/[^/]+|repositories/[0-9]+)/?$` on `api.github.com`, i.e. both `/repos/{owner}/{repo}` and its numeric-id alias `/repositories/{id}` — with a `403` response whose body identifies the vibe-docker proxy policy. All other requests SHALL pass. Users SHALL be able to extend policy by pointing `VIBE_DOCKER_GH_POLICY` at a Caddyfile snippet that is imported into the generated sidecar config. Policy configuration SHALL NOT be readable or writable from inside the agent container.

#### Scenario: Repo deletion is blocked by default

- **WHEN** `gh api -X DELETE /repos/someorg/somerepo` runs inside the agent container
- **THEN** the response is `403` with a body identifying the vibe-docker gh-proxy policy
- **AND** the request never reaches GitHub

#### Scenario: Repo deletion by numeric id is blocked by default

- **WHEN** `gh api -X DELETE /repositories/123456` runs inside the agent container
- **THEN** the response is `403` with a body identifying the vibe-docker gh-proxy policy
- **AND** the request never reaches GitHub

#### Scenario: Non-destructive requests pass

- **WHEN** `gh pr list` and `gh api /rate_limit` run inside the agent container
- **THEN** both succeed

#### Scenario: User-supplied policy extension is honoured

- **GIVEN** `VIBE_DOCKER_GH_POLICY` points to a snippet blocking `DELETE` on `^/repos/[^/]+/[^/]+/git/refs/.*`
- **WHEN** a matching request is made from the agent container
- **THEN** it is answered `403` by the sidecar


### Requirement: Proxied requests are logged

The sidecar SHALL log every proxied request (method, path, response status) as structured output on its stdout, retrievable via `$RUNTIME logs <sidecar>` for the lifetime of the session; logs are deliberately not persisted beyond the session. Logs SHALL NOT contain the token or `Authorization` header values. `run.sh` SHALL print the sidecar container name at session start so the log stream is discoverable.

#### Scenario: API call appears in the audit log

- **WHEN** `gh api /user` runs inside the agent container
- **THEN** `docker logs vibe-auth-proxy-<id>` shows a structured entry with method `GET`, path `/user`, and status `200`
- **AND** no log entry contains the token

#### Scenario: Audit log is discoverable

- **WHEN** a `vibe-docker --gh` session starts with an active sidecar
- **THEN** `run.sh` prints the sidecar container name before the agent session begins
- **AND** `$RUNTIME logs <printed name>` succeeds

