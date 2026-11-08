## REMOVED Requirements

### Requirement: Composes with the --gh auth-proxy sidecar

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Fail-closed lifecycle

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Denied hosts are reported to the user

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Model traffic reaches only the configured endpoint

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Claude Code's endpoint can't be moved by the workspace

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: The proxy runs from its own image

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: The session's egress log is saved on the host

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: The network is the boundary

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Metadata and loopback destinations are denied by resolved address

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: --egress-lock routes all network egress through the proxy

**Reason**: `--egress-lock` pinned model traffic to a custom gateway set with `--api`. vibe-docker runs vibe against the Mistral API only and has no custom endpoint, so the lock, its squid proxy sidecar and its evidence log are removed.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: --egress-allowlist needs --egress-lock and a file

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Sessions without --egress-allowlist are unchanged

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Only the effective allowlist is allowed

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Credential flags add no hosts

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: --gh and --glab need their sidecar's hosts in the file

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Sidecar upstream overrides are refused

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Sidecar policy snippets lie outside every workspace

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Allowlist rule order

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Names off the effective allowlist are not resolved

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Allowlist ports

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Allowlist file selection

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: The allowlist file is a readable text file

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: The allowlist file is read once and hashed

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: The allowlist file lies outside every workspace

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Allowlist entry grammar

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: An invalid allowlist entry is fatal

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: DNS is closed under --egress-allowlist

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

### Requirement: Allowlist evidence is saved

**Reason**: `--egress-allowlist` builds on `--egress-lock`, which is removed with the custom model endpoint: vibe-docker runs vibe against the Mistral API only, so there is no gateway to lock model traffic to.

**Migration**: None. Sessions have the open network of a default session; see the threat model.

