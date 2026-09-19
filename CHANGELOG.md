## 0.3.0

- Store DVM jobs in SQLite (`sqlite3`) instead of sembast. An existing sembast
  job file at `DVM_DB_PATH` is imported on startup and kept as a `.sembast.bak`
  backup.
- Wire the persistent NDK cache and the sync engine required by
  `nostr_scheduler_dvm` 0.3.0.
- Back the NDK cache with SQLite (`SqliteCacheManager`) instead of sembast. A
  former sembast `ndk_cache.db` is deleted on startup and rebuilt from relays.

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
