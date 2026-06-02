@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broadcast_queue_shim_for_ndk/broadcast_queue_shim_for_ndk.dart';
import 'package:ndk/domain_layer/entities/nip_65.dart';
import 'package:ndk/domain_layer/entities/read_write_marker.dart';
import 'package:ndk/domain_layer/entities/user_relay_list.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/shared/nips/nip01/key_pair.dart';
import 'package:nostr_event_scheduler/nostr_event_scheduler.dart';
import 'package:scheduler_dvm/scheduler_dvm.dart';
import 'package:sembast/sembast_io.dart' as sembast_io;
import 'package:sembast/sembast_memory.dart' as sembast_memory;
import 'package:test/test.dart';

import 'support/mock_relay.dart';

void main() {
  late MockRelay relay;
  late KeyPair clientKey;
  late KeyPair dvmKey;
  late Ndk clientNdk;
  late Ndk dvmNdk;
  late OfflineBroadcast clientBroadcast;
  late EventScheduler clientScheduler;
  late SchedulerDvm dvm;
  late SembastDvmJobStore dvmStore;
  final dbsToClose = <dynamic>[];
  final dvmsToDispose = <SchedulerDvm>[];
  final ndksToDestroy = <Ndk>[];
  final broadcastsToDispose = <OfflineBroadcast>[];

  setUp(() async {
    relay = MockRelay(name: 'scheduler relay');
    await relay.startServer();

    clientKey = Bip340.generatePrivateKey();
    dvmKey = Bip340.generatePrivateKey();

    clientNdk = _createNdk(relay.url);
    dvmNdk = _createNdk(relay.url);
    ndksToDestroy.addAll([clientNdk, dvmNdk]);

    clientNdk.accounts.loginPrivateKey(
      pubkey: clientKey.publicKey,
      privkey: clientKey.privateKey!,
    );
    dvmNdk.accounts.loginPrivateKey(
      pubkey: dvmKey.publicKey,
      privkey: dvmKey.privateKey!,
    );

    await _injectNip65(clientNdk, relay, clientKey);
    await _injectNip65(dvmNdk, relay, dvmKey);
    await _injectMetadata(dvmNdk, relay, dvmKey);

    final broadcastDb = await sembast_memory.databaseFactoryMemory.openDatabase(
      'broadcast-${relay.url}.db',
    );
    final schedulerDb = await sembast_memory.databaseFactoryMemory.openDatabase(
      'scheduler-${relay.url}.db',
    );
    dbsToClose.addAll([broadcastDb, schedulerDb]);

    clientBroadcast = OfflineBroadcast.withNdk(clientNdk, db: broadcastDb);
    clientBroadcast.start();
    broadcastsToDispose.add(clientBroadcast);

    clientScheduler = EventScheduler(
      ndk: clientNdk,
      broadcast: clientBroadcast,
      db: schedulerDb,
    );
    await clientScheduler.startListening();

    final dvmDb = await sembast_memory.databaseFactoryMemory.openDatabase(
      'dvm-${relay.url}.db',
    );
    dbsToClose.add(dvmDb);
    dvmStore = SembastDvmJobStore(dvmDb);
    dvm = _createDvm(
      ndk: dvmNdk,
      signer: dvmNdk.accounts.getLoggedAccount()!.signer,
      store: dvmStore,
      bootstrapRelayUrl: relay.url,
    );
    dvmsToDispose.add(dvm);
    await dvm.start();
  });

  tearDown(() async {
    await clientScheduler.dispose();
    for (final dvm in dvmsToDispose.reversed) {
      await dvm.dispose();
    }
    dvmsToDispose.clear();
    for (final broadcast in broadcastsToDispose.reversed) {
      await broadcast.dispose();
    }
    broadcastsToDispose.clear();
    for (final ndk in ndksToDestroy.reversed) {
      await ndk.destroy();
    }
    ndksToDestroy.clear();
    for (final db in dbsToClose.reversed) {
      await db.close();
    }
    dbsToClose.clear();
    await relay.stopServer();
  });

  test('resolves runtime relays from the DVM NIP-65 list', () {
    expect(dvm.relays.fromNip65, isTrue);
    expect(dvm.relays.requestRelays, contains(relay.url));
    expect(dvm.relays.feedbackRelays, contains(relay.url));
  });

  test('uses NDK bootstrap relays when DVM bootstrap relays are omitted', () {
    final config = SchedulerDvmConfig(
      ndk: dvmNdk,
      signer: dvmNdk.accounts.getLoggedAccount()!.signer,
      store: dvmStore,
      eventVerifier: Bip340EventVerifier(useIsolate: false),
      announceNip89: false,
    );

    expect(config.bootstrapRelays, [relay.url]);
  });

  test('resolves NIP-89 profile from the DVM kind:0 metadata', () {
    expect(dvm.profile.fromMetadata, isTrue);
    expect(dvm.profile.name, 'Metadata Scheduler DVM');
    expect(dvm.profile.about, 'Metadata powered scheduler.');
  });

  test(
    'accepts a scheduler client request and emits private scheduled feedback',
    () async {
      final target = await _signedTextEvent(
        clientNdk,
        clientKey,
        'scheduled feedback',
        DateTime.now().add(const Duration(minutes: 1)),
      );

      final job = await clientScheduler.schedule(
        target,
        dvmKey.publicKey,
        at: DateTime.now().add(const Duration(minutes: 1)),
        relays: [relay.url],
      );

      await _waitFor(() async {
        final stored = await dvmStore.getJob(job.jobId);
        return stored?.status == DvmJobStatus.scheduled;
      });

      await _waitForFeedbackStatus(
        relay: relay,
        clientNdk: clientNdk,
        jobId: job.jobId,
        status: 'scheduled',
      );

      final feedback = _feedbackEvents(relay, job.jobId).first;
      expect(feedback.getFirstTag('p'), isNull);
      expect(feedback.pubKey, dvmKey.publicKey);
      expect(
        await Bip340EventVerifier(useIsolate: false).verify(feedback),
        isTrue,
      );
    },
  );

  test('publishes due events and reports published', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'publish me',
      DateTime.now(),
    );

    final job = await clientScheduler.schedule(
      target,
      dvmKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 1)),
      relays: [relay.url],
    );

    await _waitFor(
      () => relay.storedEvents.any((event) => event.id == target.id),
    );
    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.published;
    });
    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: job.jobId,
      status: 'published',
    );
  });

  test('cancels scheduled jobs before publication', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'do not publish',
      DateTime.now(),
    );

    final job = await clientScheduler.schedule(
      target,
      dvmKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 10)),
      relays: [relay.url],
    );

    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.scheduled;
    });

    await clientScheduler.cancel(job.jobId);

    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.cancelled;
    });
    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: job.jobId,
      status: 'cancelled',
    );

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(relay.storedEvents.any((event) => event.id == target.id), isFalse);
  });

  test('sends error feedback for invalid payloads', () async {
    const jobId =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final request = await _signedScheduleRequest(
      clientNdk: clientNdk,
      clientKey: clientKey,
      dvmPubkey: dvmKey.publicKey,
      payload: {
        'job_id': jobId,
        'schedule_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'signed_event': {
          'id': 'bad',
          'pubkey': clientKey.publicKey,
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'kind': 1,
          'tags': [],
          'content': 'invalid',
          'sig': 'bad',
        },
        'relays': [relay.url],
      },
    );

    await _broadcast(clientNdk, request, relay.url);

    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: jobId,
      status: 'error',
    );
    expect(await dvmStore.getJob(jobId), isNull);
  });

  test('is idempotent for repeated request events', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'idempotent',
      DateTime.now().add(const Duration(minutes: 1)),
    );

    final job = await clientScheduler.schedule(
      target,
      dvmKey.publicKey,
      at: DateTime.now().add(const Duration(minutes: 1)),
      relays: [relay.url],
    );

    await _waitFor(() async => (await dvmStore.listJobs()).length == 1);
    final requestEvent = relay.storedEvents.firstWhere(
      (event) => event.kind == SchedulerDvm.requestKind,
    );
    relay.sendEvent(event: requestEvent, subId: 'scheduler-dvm-5905');

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final jobs = await dvmStore.listJobs();
    expect(jobs.where((stored) => stored.jobId == job.jobId), hasLength(1));
  });

  test('marks a job failed when every target relay fails', () async {
    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'fail me',
      DateTime.now(),
    );

    final job = await clientScheduler.schedule(
      target,
      dvmKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 1)),
      relays: ['ws://127.0.0.1:59999'],
    );

    await _waitFor(() async {
      final stored = await dvmStore.getJob(job.jobId);
      return stored?.status == DvmJobStatus.failed;
    }, timeout: const Duration(seconds: 8));
    await _waitForFeedbackStatus(
      relay: relay,
      clientNdk: clientNdk,
      jobId: job.jobId,
      status: 'failed',
    );
  });

  test('publishes persisted jobs after restart', () async {
    final tempDir = await Directory.systemTemp.createTemp('scheduler-dvm-test');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    await dvm.dispose();
    dvmsToDispose.remove(dvm);
    await dvmNdk.destroy();
    ndksToDestroy.remove(dvmNdk);

    dvmNdk = _createNdk(relay.url);
    ndksToDestroy.add(dvmNdk);
    dvmNdk.accounts.loginPrivateKey(
      pubkey: dvmKey.publicKey,
      privkey: dvmKey.privateKey!,
    );

    final firstDb = await sembast_io.databaseFactoryIo.openDatabase(
      '${tempDir.path}/scheduler.db',
    );
    dvmStore = SembastDvmJobStore(firstDb, closeDatabase: true);
    dvm = _createDvm(
      ndk: dvmNdk,
      signer: dvmNdk.accounts.getLoggedAccount()!.signer,
      store: dvmStore,
      bootstrapRelayUrl: relay.url,
    );
    await dvm.start();

    final target = await _signedTextEvent(
      clientNdk,
      clientKey,
      'after restart',
      DateTime.now(),
    );
    await clientScheduler.schedule(
      target,
      dvmKey.publicKey,
      at: DateTime.now().add(const Duration(seconds: 2)),
      relays: [relay.url],
    );

    await _waitFor(() async => (await dvmStore.listActiveJobs()).isNotEmpty);
    await dvm.dispose();
    await dvmNdk.destroy();
    ndksToDestroy.remove(dvmNdk);

    dvmNdk = _createNdk(relay.url);
    ndksToDestroy.add(dvmNdk);
    dvmNdk.accounts.loginPrivateKey(
      pubkey: dvmKey.publicKey,
      privkey: dvmKey.privateKey!,
    );
    final secondDb = await sembast_io.databaseFactoryIo.openDatabase(
      '${tempDir.path}/scheduler.db',
    );
    dvmStore = SembastDvmJobStore(secondDb, closeDatabase: true);
    dvm = _createDvm(
      ndk: dvmNdk,
      signer: dvmNdk.accounts.getLoggedAccount()!.signer,
      store: dvmStore,
      bootstrapRelayUrl: relay.url,
    );
    dvmsToDispose.add(dvm);
    await dvm.start();

    await _waitFor(
      () => relay.storedEvents.any((event) => event.id == target.id),
    );
  });
}

Ndk _createNdk(String relayUrl) {
  return Ndk(
    NdkConfig(
      eventVerifier: Bip340EventVerifier(useIsolate: false),
      cache: MemCacheManager(),
      bootstrapRelays: [relayUrl],
      fetchedRangesEnabled: true,
      defaultQueryTimeout: const Duration(seconds: 2),
      defaultBroadcastTimeout: const Duration(seconds: 2),
    ),
  );
}

SchedulerDvm _createDvm({
  required Ndk ndk,
  required EventSigner signer,
  required DvmJobStore store,
  required String bootstrapRelayUrl,
}) {
  return SchedulerDvm(
    SchedulerDvmConfig(
      ndk: ndk,
      signer: signer,
      store: store,
      eventVerifier: Bip340EventVerifier(useIsolate: false),
      bootstrapRelays: [bootstrapRelayUrl],
      announceNip89: false,
      queryTimeout: const Duration(milliseconds: 500),
      publishTimeout: const Duration(milliseconds: 700),
      feedbackTimeout: const Duration(milliseconds: 700),
    ),
  );
}

Future<void> _injectNip65(Ndk ndk, MockRelay relay, KeyPair keyPair) async {
  final nip65 = Nip65(
    pubKey: keyPair.publicKey,
    relays: {relay.url: ReadWriteMarker.readWrite},
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  final signed = await ndk.accounts.getLoggedAccount()!.signer.sign(
    nip65.toEvent(),
  );
  relay.storedEvents.add(signed);
  await ndk.config.cache.saveEvent(signed);
  await ndk.config.cache.saveUserRelayList(UserRelayList.fromNip65(nip65));
}

Future<void> _injectMetadata(Ndk ndk, MockRelay relay, KeyPair keyPair) async {
  final metadata = Metadata(
    pubKey: keyPair.publicKey,
    name: 'Metadata Scheduler DVM',
    displayName: 'Display Scheduler DVM',
    about: 'Metadata powered scheduler.',
    updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  final signed = await ndk.accounts.getLoggedAccount()!.signer.sign(
    metadata.toEvent(),
  );
  relay.storedEvents.add(signed);
  await ndk.config.cache.saveEvent(signed);
  await ndk.config.cache.saveMetadata(Metadata.fromEvent(signed));
}

Future<Nip01Event> _signedTextEvent(
  Ndk ndk,
  KeyPair keyPair,
  String content,
  DateTime createdAt,
) {
  final event = Nip01Event(
    pubKey: keyPair.publicKey,
    kind: Nip01Event.kTextNodeKind,
    tags: [],
    content: content,
    createdAt: createdAt.millisecondsSinceEpoch ~/ 1000,
  );
  return ndk.accounts.getLoggedAccount()!.signer.sign(event);
}

Future<Nip01Event> _signedScheduleRequest({
  required Ndk clientNdk,
  required KeyPair clientKey,
  required String dvmPubkey,
  required Map<String, Object?> payload,
}) async {
  final encrypted = await clientNdk.accounts
      .getLoggedAccount()!
      .signer
      .encryptNip44(plaintext: jsonEncode(payload), recipientPubKey: dvmPubkey);
  final event = Nip01Event(
    pubKey: clientKey.publicKey,
    kind: SchedulerDvm.requestKind,
    tags: [
      ['p', dvmPubkey],
      ['encrypted'],
    ],
    content: encrypted!,
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  return clientNdk.accounts.getLoggedAccount()!.signer.sign(event);
}

Future<void> _broadcast(Ndk ndk, Nip01Event event, String relayUrl) async {
  final response = ndk.broadcast.broadcast(
    nostrEvent: event,
    specificRelays: [relayUrl],
    timeout: const Duration(seconds: 2),
  );
  await response.broadcastDoneFuture.timeout(const Duration(seconds: 3));
}

List<Nip01Event> _feedbackEvents(MockRelay relay, String jobId) {
  return relay.storedEvents
      .where(
        (event) =>
            event.kind == FeedbackPublisher.feedbackKind &&
            event.getFirstTag('r') == jobId,
      )
      .toList();
}

Future<void> _waitForFeedbackStatus({
  required MockRelay relay,
  required Ndk clientNdk,
  required String jobId,
  required String status,
}) {
  return _waitFor(() async {
    for (final event in _feedbackEvents(relay, jobId)) {
      final ephemeralPubkey = event.getFirstTag('ephemeral-pubkey');
      if (ephemeralPubkey == null) continue;
      final decrypted = await clientNdk.accounts
          .getLoggedAccount()!
          .signer
          .decryptNip44(
            ciphertext: event.content,
            senderPubKey: ephemeralPubkey,
          );
      if (decrypted == null) continue;
      final payload = jsonDecode(decrypted) as Map<String, dynamic>;
      if (payload['status'] == status) return true;
    }
    return false;
  });
}

Future<void> _waitFor(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('Condition not met after $timeout');
}
