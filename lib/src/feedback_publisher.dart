// ignore_for_file: prefer_initializing_formals, use_null_aware_elements

import 'dart:convert';

import 'package:ndk/ndk.dart';

import 'scheduler_dvm_config.dart';

class FeedbackPublisher {
  static const int feedbackKind = 7000;
  static const int discoveryKind = 31990;

  final SchedulerDvmConfig _config;
  final LocalEventSignerFactory _signerFactory;
  SchedulerDvmRelays _relays;
  SchedulerDvmProfile _profile;

  FeedbackPublisher(
    this._config,
    this._profile,
    this._relays, {
    LocalEventSignerFactory signerFactory = const Bip340EventSignerFactory(),
  }) : _signerFactory = signerFactory;

  void updateRelays(SchedulerDvmRelays relays) {
    _relays = relays;
  }

  void updateProfile(SchedulerDvmProfile profile) {
    _profile = profile;
  }

  Future<Nip01Event> publishFeedback({
    required String jobId,
    required String clientPubkey,
    required String status,
    String? message,
  }) async {
    final ephemeralSigner = _signerFactory.createWithNewKeyPair();
    try {
      final payload = jsonEncode({
        'status': status,
        if (message != null) 'message': message,
      });
      final encrypted = await ephemeralSigner.encryptNip44(
        plaintext: payload,
        recipientPubKey: clientPubkey,
      );
      if (encrypted == null) {
        throw StateError('Failed to encrypt feedback');
      }

      final event = Nip01Event(
        pubKey: _config.dvmPubkey,
        kind: feedbackKind,
        tags: [
          ['r', jobId],
          ['ephemeral-pubkey', ephemeralSigner.getPublicKey()],
        ],
        content: encrypted,
        createdAt: _nowSeconds(),
      );
      final signed = await _config.signer.sign(event);
      await _broadcast(signed, timeout: _config.feedbackTimeout);
      return signed;
    } finally {
      await ephemeralSigner.dispose();
    }
  }

  Future<Nip01Event> publishDiscovery() async {
    final event = Nip01Event(
      pubKey: _config.dvmPubkey,
      kind: discoveryKind,
      tags: [
        ['k', '5905'],
        ['t', 'scheduler'],
      ],
      content: jsonEncode({'name': _profile.name, 'about': _profile.about}),
      createdAt: _nowSeconds(),
    );
    final signed = await _config.signer.sign(event);
    await _broadcast(signed, timeout: _config.feedbackTimeout);
    return signed;
  }

  Future<void> _broadcast(Nip01Event event, {required Duration timeout}) async {
    final response = _config.ndk.broadcast.broadcast(
      nostrEvent: event,
      specificRelays: _relays.feedbackRelays,
      customSigner: _config.signer,
      timeout: timeout,
    );
    try {
      await response.broadcastDoneFuture.timeout(timeout);
    } catch (_) {
      // Feedback should not crash the DVM if every relay is temporarily down.
    }
  }

  int _nowSeconds() => _config.clock().millisecondsSinceEpoch ~/ 1000;
}
