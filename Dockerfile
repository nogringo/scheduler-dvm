FROM dart:stable AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    cmake \
    git \
    pkg-config \
    rustup \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile

COPY . .
RUN dart pub get --offline --enforce-lockfile
RUN dart build cli -o build/cli -t bin/scheduler_dvm.dart

FROM debian:trixie-slim AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 dvm \
  && useradd --system --uid 10001 --gid dvm --home-dir /app --no-create-home dvm

WORKDIR /app

COPY --from=build /app/build/cli/bundle /app

# A fresh named volume inherits this ownership, so the dvm user can write to it.
RUN install -d -o dvm -g dvm /data

VOLUME ["/data"]

USER dvm

ENTRYPOINT ["/app/bin/scheduler_dvm"]
