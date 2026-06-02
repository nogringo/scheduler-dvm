import 'dart:async';
import 'dart:io';

import 'package:ndk/ndk.dart';
import 'package:scheduler_dvm/scheduler_dvm.dart';
import 'package:sembast/sembast_io.dart';

Future<void> main() async {
  final privateKeyEnv = Platform.environment['DVM_PRIVATE_KEY'];
  if (privateKeyEnv == null || privateKeyEnv.trim().isEmpty) {
    stderr.writeln('Missing DVM private key. Set DVM_PRIVATE_KEY.');
    exitCode = 64;
    return;
  }
  final String privateKey;
  try {
    privateKey = DvmPrivateKey.parse(privateKeyEnv).hex;
  } on DvmPrivateKeyException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }

  final bootstrapRelays = _parseRelays(
    Platform.environment['DVM_BOOTSTRAP_RELAYS'],
  );

  final dbPath = Platform.environment['DVM_DB_PATH'] ?? '/data/scheduler.db';
  await Directory(dbPath).parent.create(recursive: true);
  final db = await databaseFactoryIo.openDatabase(dbPath);

  final signerFactory = const Bip340EventSignerFactory();
  final pubkey = signerFactory.derivePublicKey(privateKey);
  final signer = signerFactory.create(
    privateKey: privateKey,
    publicKey: pubkey,
  );
  final verifier = Bip340EventVerifier();
  final ndk = Ndk(_createNdkConfig(verifier, bootstrapRelays));
  ndk.accounts.loginPrivateKey(pubkey: pubkey, privkey: privateKey);

  final store = SembastDvmJobStore(db, closeDatabase: true);
  final announce = _envBool('DVM_ANNOUNCE_NIP89', defaultValue: true);
  final dvm = SchedulerDvm(
    SchedulerDvmConfig(
      ndk: ndk,
      signer: signer,
      store: store,
      eventVerifier: verifier,
      bootstrapRelays: bootstrapRelays,
      name: Platform.environment['DVM_NAME'],
      about: Platform.environment['DVM_ABOUT'],
      announceNip89: announce,
    ),
  );

  await dvm.start();
  final resolvedRelays = dvm.relays;
  final resolvedProfile = dvm.profile;
  stdout.writeln('Scheduler DVM started as $pubkey');
  stdout.writeln(
    resolvedRelays.fromNip65
        ? 'NIP-65 relays resolved for DVM pubkey.'
        : 'No DVM NIP-65 relay list found; using bootstrap relays.',
  );
  stdout.writeln('Read relays: ${resolvedRelays.requestRelays.join(', ')}');
  stdout.writeln('Write relays: ${resolvedRelays.feedbackRelays.join(', ')}');
  stdout.writeln(
    resolvedProfile.fromMetadata
        ? 'NIP-89 profile loaded from kind:0 metadata.'
        : 'No kind:0 metadata found; using fallback NIP-89 profile.',
  );
  stdout.writeln('DVM name: ${resolvedProfile.name}');

  final shutdown = Completer<void>();
  void completeShutdown() {
    if (!shutdown.isCompleted) shutdown.complete();
  }

  final signalSubscriptions = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => completeShutdown()),
    ProcessSignal.sigterm.watch().listen((_) => completeShutdown()),
  ];

  await shutdown.future;
  stdout.writeln('Shutting down Scheduler DVM...');

  for (final subscription in signalSubscriptions) {
    await subscription.cancel();
  }
  await dvm.dispose();
  await ndk.destroy();
  await signer.dispose();
}

NdkConfig _createNdkConfig(
  EventVerifier verifier,
  List<String> bootstrapRelays,
) {
  if (bootstrapRelays.isEmpty) {
    return NdkConfig(eventVerifier: verifier, cache: MemCacheManager());
  }

  return NdkConfig(
    eventVerifier: verifier,
    cache: MemCacheManager(),
    bootstrapRelays: bootstrapRelays,
  );
}

List<String> _parseRelays(String? value) {
  if (value == null) return const [];
  return value
      .split(',')
      .map((relay) => relay.trim())
      .where((relay) => relay.isNotEmpty)
      .toList();
}

bool _envBool(String key, {required bool defaultValue}) {
  final value = Platform.environment[key];
  if (value == null || value.trim().isEmpty) return defaultValue;
  return switch (value.trim().toLowerCase()) {
    '1' || 'true' || 'yes' || 'on' => true,
    '0' || 'false' || 'no' || 'off' => false,
    _ => defaultValue,
  };
}
