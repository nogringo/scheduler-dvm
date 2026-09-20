## 0.4.0

- Upgrade to `nostr_scheduler_dvm` 0.4.0, which keys jobs by their request
  event id, filters the target relays a request may ask for, rejects a
  `schedule_at` beyond ten years, drops a backlog older than a week instead of
  publishing it on restart, and decides a request once instead of once per
  start.
- Key the SQLite jobs table on `request_event_id` and look a `job_id` up per
  client. Schema 1 keyed jobs on the client-chosen `job_id` alone, so two
  clients picking the same one overwrote each other's job. An existing schema 1
  database is rekeyed on startup.
- Run the container as the unprivileged user `dvm` (uid and gid 10001), which
  owns `/data`. A volume created by an earlier image is owned by root and has
  to be given to `dvm` once, see the README.

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
