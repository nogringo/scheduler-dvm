import 'package:ndk/ndk.dart';

import 'dvm_job_status.dart';

class DvmJob {
  final String jobId;
  final String requestEventId;
  final String clientPubkey;
  final String dvmPubkey;
  final int scheduleAt;
  final Nip01Event targetEvent;
  final List<String> targetRelays;
  final int createdAt;
  final int updatedAt;
  final int? publishedAt;
  final int? cancelledAt;
  final DvmJobStatus status;
  final String? lastMessage;

  const DvmJob({
    required this.jobId,
    required this.requestEventId,
    required this.clientPubkey,
    required this.dvmPubkey,
    required this.scheduleAt,
    required this.targetEvent,
    required this.targetRelays,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    this.publishedAt,
    this.cancelledAt,
    this.lastMessage,
  });

  bool get isTerminal => status.isTerminal;

  DvmJob copyWith({
    int? updatedAt,
    int? publishedAt,
    int? cancelledAt,
    DvmJobStatus? status,
    String? lastMessage,
  }) {
    return DvmJob(
      jobId: jobId,
      requestEventId: requestEventId,
      clientPubkey: clientPubkey,
      dvmPubkey: dvmPubkey,
      scheduleAt: scheduleAt,
      targetEvent: targetEvent,
      targetRelays: targetRelays,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      publishedAt: publishedAt ?? this.publishedAt,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      status: status ?? this.status,
      lastMessage: lastMessage ?? this.lastMessage,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'jobId': jobId,
      'requestEventId': requestEventId,
      'clientPubkey': clientPubkey,
      'dvmPubkey': dvmPubkey,
      'scheduleAt': scheduleAt,
      'targetEvent': _eventToJson(targetEvent),
      'targetRelays': targetRelays,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'publishedAt': publishedAt,
      'cancelledAt': cancelledAt,
      'status': status.name,
      'lastMessage': lastMessage,
    };
  }

  factory DvmJob.fromJson(Map<String, Object?> json) {
    return DvmJob(
      jobId: json['jobId'] as String,
      requestEventId: json['requestEventId'] as String,
      clientPubkey: json['clientPubkey'] as String,
      dvmPubkey: json['dvmPubkey'] as String,
      scheduleAt: json['scheduleAt'] as int,
      targetEvent: _eventFromJson(
        (json['targetEvent'] as Map).cast<String, Object?>(),
      ),
      targetRelays: (json['targetRelays'] as List).cast<String>(),
      createdAt: json['createdAt'] as int,
      updatedAt: json['updatedAt'] as int,
      publishedAt: json['publishedAt'] as int?,
      cancelledAt: json['cancelledAt'] as int?,
      status: DvmJobStatus.values.byName(json['status'] as String),
      lastMessage: json['lastMessage'] as String?,
    );
  }

  static Map<String, Object?> _eventToJson(Nip01Event event) {
    return {
      'id': event.id,
      'pubkey': event.pubKey,
      'created_at': event.createdAt,
      'kind': event.kind,
      'tags': event.tags,
      'content': event.content,
      'sig': event.sig,
    };
  }

  static Nip01Event _eventFromJson(Map<String, Object?> json) {
    return Nip01Event(
      id: json['id'] as String,
      pubKey: json['pubkey'] as String,
      createdAt: json['created_at'] as int,
      kind: json['kind'] as int,
      tags: (json['tags'] as List)
          .map((tag) => (tag as List).cast<String>())
          .toList(),
      content: json['content'] as String,
      sig: json['sig'] as String?,
    );
  }
}
