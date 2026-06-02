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
- `DVM_DB_PATH`, default `/data/scheduler.db`
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

## Protocol

- Schedule requests: `kind:5905`, NIP-44 encrypted to the DVM pubkey, tagged
  with `["p", "<dvm_pubkey>"]` and `["encrypted"]`.
- Feedback: `kind:7000`, encrypted with a one-time ephemeral key, tagged with
  `["r", "<job_id>"]` and `["ephemeral-pubkey", "<ephemeral_pubkey>"]`.
- Cancellation: standard `kind:5` delete event tagging the original
  `kind:5905` event id.
- Discovery: optional NIP-89 `kind:31990` announcement for `kind:5905`.

## Checks

```sh
dart format --set-exit-if-changed .
dart analyze
dart test
docker compose config
docker compose -f compose.local.yaml config
```
