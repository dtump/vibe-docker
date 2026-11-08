## MODIFIED Requirements

### Requirement: Pinned Go toolchain installed on the default PATH

The container image SHALL ship exactly one Go toolchain, installed from the
official `go.dev` release tarball into `/usr/local/go` as
[go.dev/doc/install](https://go.dev/doc/install) prescribes, with
`/usr/local/go/bin` on the default PATH. The install SHALL be arch-aware for
both `amd64` and `arm64`. The toolchain SHALL NOT come from the distribution
archive (`golang-go`), which tracks an older release and splits GOROOT across
paths the upstream layout assumes are one tree.

Unlike `terraform` (deliberately absent, fetched per-project by `tfenv`) and
project Python (fetched by `uv`; the CPython under `/opt/vibe` exists only to
run `vibe` and is not on PATH), the Go toolchain is baked into the image: the Go
distribution is a single self-contained tree with no per-project variant to
choose, and `go` itself resolves a project's required toolchain at build time
(see the runtime code-fetch requirement below).

#### Scenario: go present on PATH

- **WHEN** the container launches
- **THEN** `go version` succeeds without an absolute path
- **AND** the reported version equals the `GO_VERSION` pinned in the Dockerfile
- **AND** `go env GOROOT` reports `/usr/local/go`

#### Scenario: builds on Apple Silicon

- **WHEN** `docker build -t mistral-vibe:local ~/vibe-docker` runs on arm64
- **THEN** the build succeeds
- **AND** `go version` does not fail with an exec-format error

#### Scenario: unsupported architecture fails the build loudly

- **GIVEN** a build on an architecture that is neither `amd64` nor `arm64`
- **WHEN** the Go install step runs
- **THEN** the build exits non-zero with a message naming the unsupported
  architecture
- **AND** no partial Go tree is left under `/usr/local/go`


### Requirement: PATH ordering keeps volume-persisted directories non-shadowing

The default PATH SHALL place `/usr/local/go/bin` ahead of every system path,
and SHALL place both agent-writable directories that live in the persistent
`vibe-root` volume — `/root/.local/bin` (the `pip install --user` /
`uv tool install` prefix) and `/root/go/bin` (the GOPATH `bin` directory, where
`go install` writes) — after every system path.

Both directories are writable by the agent and survive the session: `/root` is
a named volume shared across sessions and workspaces, and the image PATH
reaches the agent unchanged because the entrypoint execs `runuser -u` rather
than `runuser -l`. A binary one session leaves in either directory MUST NOT be
able to shadow a system binary (`git`, `gh`, `aws`, …) on a later run. They MAY
be on the default PATH for convenience, but only after every system path.

Neither directory is distinguishable from the other by anything the image can
check — same volume, same writer, same lifetime — so the usual convention that
a user-local prefix precedes the system paths SHALL NOT be applied to
`/root/.local/bin`. `/usr/local/go/bin` precedes the system paths so the
image's pinned toolchain wins over anything installed into the volume.

#### Scenario: a persisted GOPATH binary cannot shadow a system tool

- **GIVEN** a previous session left an executable named `git` in `/root/go/bin`
  in the persistent volume
- **WHEN** a new container starts and `git` is invoked
- **THEN** the system `git` runs, not the one from `/root/go/bin`

#### Scenario: a persisted user-prefix binary cannot shadow a system tool

- **GIVEN** a previous session left an executable named `gh` in
  `/root/.local/bin` in the persistent volume
- **WHEN** a new container starts, in any workspace, and `gh` is invoked
- **THEN** the system `gh` runs, not the one from `/root/.local/bin`

#### Scenario: go install output is runnable without an absolute path

- **WHEN** the user runs `go install <module>@<version>` and then invokes the
  installed command by name
- **THEN** the command resolves from `/root/go/bin` on PATH

#### Scenario: user-prefix installs are runnable without an absolute path

- **WHEN** the user installs a tool whose entry point lands in
  `/root/.local/bin` (for example `uv tool install` or `pip install --user`)
  and then invokes it by name
- **THEN** the command resolves from `/root/.local/bin` on PATH, provided no
  system binary of that name exists

#### Scenario: the smoke suite enforces the ordering

- **WHEN** `tests/smoke/smoke.sh` runs against a built image
- **THEN** the in-container assertions confirm `/usr/local/go/bin` precedes
  `/usr/bin`, that `/usr/bin` precedes both `/root/.local/bin` and
  `/root/go/bin`, and that `git` resolves to `/usr/bin/git`
- **AND** they confirm the exported `GOROOT`, `GOPATH`, and `GOBIN` values

