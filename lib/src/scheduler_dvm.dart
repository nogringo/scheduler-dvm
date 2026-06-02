import 'dart:async';

import 'package:ndk/ndk.dart';

import 'dvm_job.dart';
import 'dvm_job_status.dart';
import 'feedback_publisher.dart';
import 'schedule_request_payload.dart';
import 'schedule_runner.dart';
import 'scheduler_dvm_config.dart';

class SchedulerDvm {
  static const int requestKind = 5905;
  static const int deleteKind = 5;

  final SchedulerDvmConfig config;
  late final FeedbackPublisher _feedbackPublisher;
  late final ScheduleRunner _runner;
  late SchedulerDvmRelays _relays;
  late SchedulerDvmProfile _profile;

  final List<NdkResponse> _responses = [];
  final List<StreamSubscription<Nip01Event>> _subscriptions = [];
  final Map<String, Nip01Event> _pendingDeletions = {};

  bool _started = false;

  SchedulerDvm(this.config) {
    _relays = SchedulerDvmRelays(
      bootstrapRelays: config.bootstrapRelays,
      readRelays: config.bootstrapRelays,
      writeRelays: config.bootstrapRelays,
      fromNip65: false,
    );
    _profile = SchedulerDvmProfile(
      name: config.name ?? SchedulerDvmConfig.defaultName,
      about: config.about ?? SchedulerDvmConfig.defaultAbout,
      fromMetadata: false,
    );
    _feedbackPublisher = FeedbackPublisher(config, _profile, _relays);
    _runner = ScheduleRunner(clock: config.clock, onDue: _publishDueJob);
  }

  String get pubkey => config.dvmPubkey;

  SchedulerDvmRelays get relays => _relays;

  SchedulerDvmProfile get profile => _profile;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    await refreshRelays();
    await refreshProfile();
    _startSubscriptions();
    await resync();

    for (final job in await config.store.listActiveJobs()) {
      _runner.schedule(job);
    }

    if (config.announceNip89) {
      await _feedbackPublisher.publishDiscovery();
    }
  }

  Future<SchedulerDvmRelays> refreshRelays() async {
    _relays = await config.resolveRelays(forceRefresh: true);
    _feedbackPublisher.updateRelays(_relays);
    return _relays;
  }

  Future<SchedulerDvmProfile> refreshProfile() async {
    _profile = await config.resolveProfile(_relays);
    _feedbackPublisher.updateProfile(_profile);
    return _profile;
  }

  Future<void> resync() async {
    await _query(
      Filter(kinds: [requestKind], pTags: [config.dvmPubkey]),
      _handleScheduleRequest,
    );
    await _query(Filter(kinds: [deleteKind]), _handleDeletion);
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    for (final response in _responses) {
      await config.ndk.requests.closeSubscription(response.requestId);
    }
    _responses.clear();

    await _runner.dispose();
  }

  Future<void> dispose() async {
    await stop();
    await config.store.close();
  }

  void _startSubscriptions() {
    final scheduleResponse = config.ndk.requests.subscription(
      filter: Filter(kinds: [requestKind], pTags: [config.dvmPubkey]),
      id: 'scheduler-dvm-5905',
      explicitRelays: _relays.requestRelays,
      cacheRead: false,
      cacheWrite: false,
    );
    _responses.add(scheduleResponse);
    _subscriptions.add(
      scheduleResponse.stream.listen(
        (event) => unawaited(_handleScheduleRequest(event)),
      ),
    );

    final deletionResponse = config.ndk.requests.subscription(
      filter: Filter(kinds: [deleteKind]),
      id: 'scheduler-dvm-5',
      explicitRelays: _relays.requestRelays,
      cacheRead: false,
      cacheWrite: false,
    );
    _responses.add(deletionResponse);
    _subscriptions.add(
      deletionResponse.stream.listen(
        (event) => unawaited(_handleDeletion(event)),
      ),
    );
  }

  Future<void> _query(
    Filter filter,
    Future<void> Function(Nip01Event event) handler,
  ) async {
    final response = config.ndk.requests.query(
      filter: filter,
      explicitRelays: _relays.requestRelays,
      cacheRead: false,
      cacheWrite: false,
      timeout: config.queryTimeout,
    );
    await for (final event in response.stream) {
      await handler(event);
    }
  }

  Future<void> _handleScheduleRequest(Nip01Event event) async {
    if (!_isScheduleRequestForThisDvm(event)) return;
    if (await config.store.getJobByRequestEventId(event.id) != null) return;

    final decrypted = await _decryptRequest(event);
    if (decrypted == null) return;

    final ScheduleRequestPayload payload;
    try {
      payload = await ScheduleRequestPayload.parseAndValidate(
        decrypted,
        eventVerifier: config.eventVerifier,
      );
    } on PayloadValidationException catch (error) {
      if (error.jobId != null) {
        await _sendFeedback(
          jobId: error.jobId!,
          clientPubkey: event.pubKey,
          status: 'error',
          message: error.message,
        );
      }
      return;
    }

    final existing = await config.store.getJob(payload.jobId);
    if (existing != null) {
      if (existing.requestEventId != event.id) {
        await _sendFeedback(
          jobId: payload.jobId,
          clientPubkey: event.pubKey,
          status: 'error',
          message: 'job_id already exists',
        );
      }
      return;
    }

    final now = _nowSeconds();
    var job = DvmJob(
      jobId: payload.jobId,
      requestEventId: event.id,
      clientPubkey: event.pubKey,
      dvmPubkey: config.dvmPubkey,
      scheduleAt: payload.scheduleAt,
      targetEvent: payload.signedEvent,
      targetRelays: payload.relays,
      createdAt: now,
      updatedAt: now,
      status: DvmJobStatus.scheduled,
    );

    final pendingDeletion = _pendingDeletions.remove(event.id);
    if (pendingDeletion != null && pendingDeletion.pubKey == event.pubKey) {
      job = job.copyWith(
        status: DvmJobStatus.cancelled,
        updatedAt: now,
        cancelledAt: now,
        lastMessage: 'Cancelled before scheduling',
      );
      await config.store.putJob(job);
      await _sendFeedback(
        jobId: job.jobId,
        clientPubkey: job.clientPubkey,
        status: 'cancelled',
        message: 'Job cancelled',
      );
      return;
    }

    await config.store.putJob(job);
    await _sendFeedback(
      jobId: job.jobId,
      clientPubkey: job.clientPubkey,
      status: 'scheduled',
      message: 'Job accepted',
    );
    _runner.schedule(job);
  }

  Future<String?> _decryptRequest(Nip01Event event) async {
    try {
      return await config.signer.decryptNip44(
        ciphertext: event.content,
        senderPubKey: event.pubKey,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _handleDeletion(Nip01Event event) async {
    final requestEventIds = event.getTags('e');
    for (final requestEventId in requestEventIds) {
      final job = await config.store.getJobByRequestEventId(requestEventId);
      if (job == null) {
        _pendingDeletions[requestEventId] = event;
        continue;
      }
      if (event.pubKey != job.clientPubkey) continue;

      if (job.isTerminal) {
        await _sendFeedback(
          jobId: job.jobId,
          clientPubkey: job.clientPubkey,
          status: 'error',
          message: 'Job is already ${job.status.name}',
        );
        continue;
      }

      final now = _nowSeconds();
      final cancelled = job.copyWith(
        status: DvmJobStatus.cancelled,
        updatedAt: now,
        cancelledAt: now,
        lastMessage: 'Job cancelled',
      );
      _runner.cancel(job.jobId);
      await config.store.putJob(cancelled);
      await _sendFeedback(
        jobId: job.jobId,
        clientPubkey: job.clientPubkey,
        status: 'cancelled',
        message: 'Job cancelled',
      );
    }
  }

  Future<void> _publishDueJob(String jobId) async {
    final job = await config.store.getJob(jobId);
    if (job == null || job.isTerminal) return;

    if (job.scheduleAt > _nowSeconds()) {
      _runner.schedule(job);
      return;
    }

    final publishResult = await _publishTargetEvent(job);
    final now = _nowSeconds();
    final status = publishResult.success
        ? DvmJobStatus.published
        : DvmJobStatus.failed;
    final updated = job.copyWith(
      status: status,
      updatedAt: now,
      publishedAt: publishResult.success ? now : null,
      lastMessage: publishResult.message,
    );

    await config.store.putJob(updated);
    await _sendFeedback(
      jobId: updated.jobId,
      clientPubkey: updated.clientPubkey,
      status: updated.status.name,
      message: publishResult.message,
    );
  }

  Future<_PublishResult> _publishTargetEvent(DvmJob job) async {
    try {
      final response = config.ndk.broadcast.broadcast(
        nostrEvent: job.targetEvent,
        specificRelays: job.targetRelays,
        customSigner: config.signer,
        timeout: config.publishTimeout,
      );
      final results = await response.broadcastDoneFuture.timeout(
        config.publishTimeout + const Duration(seconds: 1),
      );
      final successCount = results
          .where((relayResponse) => relayResponse.broadcastSuccessful)
          .length;
      if (successCount > 0) {
        return _PublishResult(
          success: true,
          message:
              'Published to $successCount/${job.targetRelays.length} relays',
        );
      }

      final errors = results
          .where((relayResponse) => relayResponse.msg.isNotEmpty)
          .map(
            (relayResponse) =>
                '${relayResponse.relayUrl}: '
                '${relayResponse.msg}',
          )
          .join('; ');
      return _PublishResult(
        success: false,
        message: errors.isEmpty ? 'All target relays failed' : errors,
      );
    } catch (error) {
      return _PublishResult(success: false, message: 'Publish failed: $error');
    }
  }

  Future<void> _sendFeedback({
    required String jobId,
    required String clientPubkey,
    required String status,
    String? message,
  }) async {
    try {
      await _feedbackPublisher.publishFeedback(
        jobId: jobId,
        clientPubkey: clientPubkey,
        status: status,
        message: message,
      );
    } catch (_) {
      // Feedback best effort; durable job state is already persisted.
    }
  }

  bool _isScheduleRequestForThisDvm(Nip01Event event) {
    if (event.kind != requestKind) return false;
    if (event.getFirstTag('p') != config.dvmPubkey) return false;
    return event.tags.any((tag) => tag.length == 1 && tag.first == 'encrypted');
  }

  int _nowSeconds() => config.clock().millisecondsSinceEpoch ~/ 1000;
}

class _PublishResult {
  final bool success;
  final String message;

  const _PublishResult({required this.success, required this.message});
}
