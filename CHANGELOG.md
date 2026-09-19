## 0.2.0

- Depend on the `nostr_scheduler_dvm` package for the DVM core instead of
  keeping a local copy in `lib/`. This repository now only ships the CLI
  runner and its Docker deployment.
- Move the core tests to `nostr_scheduler_dvm`.

## 0.1.0

- Implement Scheduler DVM runtime for `kind:5905`, `kind:5`, `kind:7000`,
  and NIP-89 discovery.
- Add Sembast-backed durable job persistence and restart recovery.
- Add CLI configuration, Docker Compose deployment, GHCR workflow, and
  integration tests with NDK mock relay and `nostr_event_scheduler`.
