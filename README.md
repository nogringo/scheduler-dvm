# Scheduler DVM

A Dart Scheduler DVM for Nostr. It accepts encrypted `kind:5905` schedule
requests, publishes the signed event at `schedule_at`, handles `kind:5`
cancellations, and sends encrypted `kind:7000` feedback.

## Run locally

The binary is configured with environment variables only.

```sh
dart pub get
DVM_PRIVATE_KEY=<hex-private-key-or-nsec> dart run bin/scheduler_dvm.dart
```

`DVM_PRIVATE_KEY` accepts either a 64 character hex private key or a NIP-19
`nsec1...` private key.

Optional configuration:

- `DVM_BOOTSTRAP_RELAYS`, optional: override relays used to discover the DVM
  pubkey's NIP-65 relay list. If omitted, NDK uses its default bootstrap relays.
- `DVM_DB_PATH`, default `/data/scheduler.db`: SQLite file holding the jobs.
  The SQLite NDK cache (`ndk_cache.db`) and the sync engine state
  (`sync_engine.db`) are stored next to it. A sembast job file left at this path by an older
  version is imported on startup and kept as `scheduler.db.sembast.bak`, and a
  database written by 0.3.0 is rekeyed on the request event id.
- `DVM_NAME`, optional fallback if the DVM `kind:0` has no `name` or
  `display_name`
- `DVM_ABOUT`, optional fallback if the DVM `kind:0` has no `about`
- `DVM_ANNOUNCE_NIP89`, default `true`

At startup, the DVM queries NDK for its own NIP-65 `kind:10002` relay list.
It listens for `kind:5905` and `kind:5` on the DVM pubkey's read relays and
publishes feedback/discovery on the write relays. If no NIP-65 list is found,
it falls back to the configured bootstrap relays, or NDK's defaults when
`DVM_BOOTSTRAP_RELAYS` is omitted.

The NIP-89 discovery `name` and `about` are loaded from the DVM pubkey's
`kind:0` metadata. `DVM_NAME` and `DVM_ABOUT` are only fallbacks; if neither
metadata nor env fallback exists, the built-in defaults are used.

## Docker Compose

Production pulls the published GHCR image:

```sh
cp .env.example .env
# edit DVM_PRIVATE_KEY
docker compose up -d
```

Local Compose builds from the repository:

```sh
cp .env.example .env
# edit DVM_PRIVATE_KEY
docker compose -f compose.local.yaml up --build
```

Both Compose files store durable jobs in the `scheduler-dvm-data` volume.
`compose.yaml` uses `ghcr.io/nogringo/scheduler-dvm:latest`; `compose.local.yaml`
uses the local `scheduler-dvm:local` image. The GHCR workflow publishes
`linux/amd64` and `linux/arm64` images.

The container runs as the unprivileged user `dvm` (uid and gid 10001), which
owns `/data`. A volume created by an earlier image is owned by root, so give it
to `dvm` once before upgrading:

```sh
docker compose run --rm --user root --entrypoint chown scheduler-dvm -R 10001:10001 /data
```

A bind mount keeps its ownership on the host, so `chown -R 10001:10001` the
host directory instead.

## Protocol

The wire format lives in the [Scheduler DVM spec](https://openspecs.uid.ovh/spec/npub1kg4sdvz3l4fr99n2jdz2vdxe2mpacva87hkdetv76ywacsfq5leqquw5te/scheduler-dvm):
`kind:5905` schedule requests, `kind:5` cancellations, `kind:7000` feedback and
the NIP-89 `kind:31990` announcement. This DVM implements it through
[`nostr_scheduler_dvm`](https://pub.dev/packages/nostr_scheduler_dvm).
