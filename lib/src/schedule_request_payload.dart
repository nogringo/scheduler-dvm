import 'dart:convert';

import 'package:ndk/ndk.dart';

class PayloadValidationException implements Exception {
  final String message;
  final String? jobId;

  const PayloadValidationException(this.message, {this.jobId});

  @override
  String toString() => message;
}

class ScheduleRequestPayload {
  static final RegExp _jobIdPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  final String jobId;
  final int scheduleAt;
  final Nip01Event signedEvent;
  final List<String> relays;

  const ScheduleRequestPayload({
    required this.jobId,
    required this.scheduleAt,
    required this.signedEvent,
    required this.relays,
  });

  static Future<ScheduleRequestPayload> parseAndValidate(
    String payload, {
    required EventVerifier eventVerifier,
  }) async {
    final Map<String, Object?> json;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const PayloadValidationException('Payload must be a JSON object');
      }
      json = decoded.cast<String, Object?>();
    } on PayloadValidationException {
      rethrow;
    } catch (error) {
      throw PayloadValidationException('Invalid JSON payload: $error');
    }

    final jobId = json['job_id'];
    if (jobId is! String || !_jobIdPattern.hasMatch(jobId)) {
      throw const PayloadValidationException(
        'job_id must be 64 hex characters',
      );
    }

    final scheduleAt = json['schedule_at'];
    if (scheduleAt is! int) {
      throw PayloadValidationException(
        'schedule_at must be an integer unix timestamp',
        jobId: jobId,
      );
    }

    final relaysJson = json['relays'];
    if (relaysJson is! List || relaysJson.isEmpty) {
      throw PayloadValidationException(
        'relays must be a non-empty array',
        jobId: jobId,
      );
    }
    final relays = <String>[];
    for (final relay in relaysJson) {
      if (relay is! String || relay.trim().isEmpty) {
        throw PayloadValidationException(
          'relays must contain only non-empty strings',
          jobId: jobId,
        );
      }
      relays.add(relay.trim());
    }

    final signedEventJson = json['signed_event'];
    if (signedEventJson is! Map) {
      throw PayloadValidationException(
        'signed_event must be an object',
        jobId: jobId,
      );
    }
    final signedEvent = _eventFromJson(
      signedEventJson.cast<String, Object?>(),
      jobId: jobId,
    );

    if (signedEvent.sig == null || signedEvent.sig!.isEmpty) {
      throw PayloadValidationException(
        'signed_event must include sig',
        jobId: jobId,
      );
    }

    final valid = await eventVerifier.verify(signedEvent);
    if (!valid) {
      throw PayloadValidationException(
        'signed_event signature or id is invalid',
        jobId: jobId,
      );
    }

    return ScheduleRequestPayload(
      jobId: jobId.toLowerCase(),
      scheduleAt: scheduleAt,
      signedEvent: signedEvent,
      relays: relays,
    );
  }

  static Nip01Event _eventFromJson(
    Map<String, Object?> json, {
    required String jobId,
  }) {
    String requireString(String key) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
      throw PayloadValidationException(
        'signed_event.$key must be a non-empty string',
        jobId: jobId,
      );
    }

    int requireInt(String key) {
      final value = json[key];
      if (value is int) return value;
      throw PayloadValidationException(
        'signed_event.$key must be an integer',
        jobId: jobId,
      );
    }

    final tagsJson = json['tags'];
    if (tagsJson is! List) {
      throw PayloadValidationException(
        'signed_event.tags must be an array',
        jobId: jobId,
      );
    }
    final tags = <List<String>>[];
    for (final tag in tagsJson) {
      if (tag is! List) {
        throw PayloadValidationException(
          'signed_event.tags must contain arrays',
          jobId: jobId,
        );
      }
      final parsedTag = <String>[];
      for (final value in tag) {
        if (value is! String) {
          throw PayloadValidationException(
            'signed_event.tags values must be strings',
            jobId: jobId,
          );
        }
        parsedTag.add(value);
      }
      tags.add(parsedTag);
    }

    return Nip01Event(
      id: requireString('id'),
      pubKey: requireString('pubkey'),
      createdAt: requireInt('created_at'),
      kind: requireInt('kind'),
      tags: tags,
      content: json['content'] is String ? json['content'] as String : '',
      sig: requireString('sig'),
    );
  }
}
