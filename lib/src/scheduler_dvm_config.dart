import 'package:ndk/ndk.dart';

import 'dvm_job_store.dart';

typedef DvmClock = DateTime Function();

class SchedulerDvmRelays {
  final List<String> bootstrapRelays;
  final List<String> readRelays;
  final List<String> writeRelays;
  final bool fromNip65;

  SchedulerDvmRelays({
    required Iterable<String> bootstrapRelays,
    required Iterable<String> readRelays,
    required Iterable<String> writeRelays,
    required this.fromNip65,
  }) : bootstrapRelays = _cleanRelays(bootstrapRelays),
       readRelays = _cleanRelays(readRelays),
       writeRelays = _cleanRelays(writeRelays);

  List<String> get feedbackRelays => writeRelays.isEmpty
      ? (readRelays.isEmpty ? bootstrapRelays : readRelays)
      : writeRelays;

  List<String> get requestRelays => readRelays.isEmpty
      ? (writeRelays.isEmpty ? bootstrapRelays : writeRelays)
      : readRelays;

  List<String> get allRuntimeRelays {
    return {...requestRelays, ...feedbackRelays}.toList();
  }
}

class SchedulerDvmProfile {
  final String name;
  final String about;
  final bool fromMetadata;

  const SchedulerDvmProfile({
    required this.name,
    required this.about,
    required this.fromMetadata,
  });
}

class SchedulerDvmConfig {
  static const String defaultName = 'Scheduler DVM';
  static const String defaultAbout = 'Schedule any signed Nostr event.';

  final Ndk ndk;
  final EventSigner signer;
  final DvmJobStore store;
  final EventVerifier eventVerifier;
  final List<String> bootstrapRelays;
  final String? name;
  final String? about;
  final bool announceNip89;
  final Duration queryTimeout;
  final Duration publishTimeout;
  final Duration feedbackTimeout;
  final DvmClock clock;

  SchedulerDvmConfig({
    required this.ndk,
    required this.signer,
    required this.store,
    required this.eventVerifier,
    Iterable<String> bootstrapRelays = const [],
    this.name,
    this.about,
    this.announceNip89 = true,
    this.queryTimeout = const Duration(seconds: 8),
    this.publishTimeout = const Duration(seconds: 15),
    this.feedbackTimeout = const Duration(seconds: 8),
    DvmClock? clock,
  }) : bootstrapRelays = _resolveBootstrapRelays(ndk, bootstrapRelays),
       clock = clock ?? DateTime.now;

  String get dvmPubkey => signer.getPublicKey();

  Future<SchedulerDvmRelays> resolveRelays({bool forceRefresh = true}) async {
    final relayList = await ndk.userRelayLists.getSingleUserRelayList(
      dvmPubkey,
      forceRefresh: forceRefresh,
    );
    if (relayList == null || relayList.relays.isEmpty) {
      return SchedulerDvmRelays(
        bootstrapRelays: bootstrapRelays,
        readRelays: bootstrapRelays,
        writeRelays: bootstrapRelays,
        fromNip65: false,
      );
    }

    final readRelays = relayList.readUrls.toList();
    final writeRelays = relayList.writeUrls.toList();
    return SchedulerDvmRelays(
      bootstrapRelays: bootstrapRelays,
      readRelays: readRelays.isEmpty ? bootstrapRelays : readRelays,
      writeRelays: writeRelays.isEmpty ? bootstrapRelays : writeRelays,
      fromNip65: true,
    );
  }

  Future<SchedulerDvmProfile> resolveProfile(SchedulerDvmRelays relays) async {
    Metadata? metadata;
    try {
      final response = ndk.requests.query(
        filter: Filter(kinds: [Metadata.kKind], authors: [dvmPubkey], limit: 1),
        explicitRelays: relays.requestRelays,
        cacheRead: true,
        cacheWrite: true,
        timeout: queryTimeout,
      );
      await for (final event in response.stream) {
        final parsed = Metadata.fromEvent(event);
        if (metadata == null ||
            metadata.updatedAt == null ||
            (parsed.updatedAt ?? 0) > metadata.updatedAt!) {
          metadata = parsed;
        }
      }
    } catch (_) {
      metadata = await ndk.config.cache.loadMetadata(dvmPubkey);
    }
    metadata ??= await ndk.config.cache.loadMetadata(dvmPubkey);

    final metadataName = _firstNonBlank([
      metadata?.name,
      metadata?.displayName,
    ]);
    final metadataAbout = _firstNonBlank([metadata?.about]);

    return SchedulerDvmProfile(
      name: metadataName ?? _nonBlank(name) ?? defaultName,
      about: metadataAbout ?? _nonBlank(about) ?? defaultAbout,
      fromMetadata: metadataName != null || metadataAbout != null,
    );
  }
}

List<String> _cleanRelays(Iterable<String> relays) {
  return List.unmodifiable(
    relays.map((relay) => relay.trim()).where((relay) => relay.isNotEmpty),
  );
}

List<String> _resolveBootstrapRelays(Ndk ndk, Iterable<String> relays) {
  final configured = _cleanRelays(relays);
  if (configured.isNotEmpty) return configured;
  return _cleanRelays(ndk.config.bootstrapRelays);
}

String? _firstNonBlank(Iterable<String?> values) {
  for (final value in values) {
    final cleaned = _nonBlank(value);
    if (cleaned != null) return cleaned;
  }
  return null;
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
