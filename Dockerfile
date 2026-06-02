FROM dart:stable

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    cargo \
    clang \
    cmake \
    git \
    pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .
RUN dart pub get --offline

VOLUME ["/data"]

ENTRYPOINT ["dart", "run", "bin/scheduler_dvm.dart"]
