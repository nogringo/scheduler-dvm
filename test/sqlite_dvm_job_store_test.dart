import 'dart:convert';
import 'dart:io';

import 'package:ndk/ndk.dart';
import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:path/path.dart' as p;
import 'package:scheduler_dvm/sqlite_dvm_job_store.dart';
import 'package:sembast/sembast_io.dart' as sembast;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

DvmJob job(
  String id, {
  String clientPubkey = 'client',
  String? requestEventId,
  int scheduleAt = 100,
  DvmJobStatus status = DvmJobStatus.scheduled,
}) {
  return DvmJob(
    jobId: id,
    requestEventId: requestEventId ?? 'request-$id',
    clientPubkey: clientPubkey,
    dvmPubkey: 'dvm',
    scheduleAt: scheduleAt,
    targetEvent: Nip01Event(
      id: 'event-$id',
      pubKey: 'author',
      createdAt: 1,
      kind: 1,
      tags: [
        ['t', 'test'],
      ],
      content: 'hello',
      sig: 'sig',
    ),
    targetRelays: ['wss://relay.example'],
    createdAt: 1,
    updatedAt: 1,
    status: status,
  );
}

void writeSchemaV1Job(Database db, DvmJob job) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS jobs (
      job_id TEXT PRIMARY KEY,
      request_event_id TEXT NOT NULL,
      status TEXT NOT NULL,
      schedule_at INTEGER NOT NULL,
      data TEXT NOT NULL
    );
  ''');
  db.userVersion = 1;
  db.execute(
    'INSERT OR REPLACE INTO jobs '
    '(job_id, request_event_id, status, schedule_at, data) '
    'VALUES (?, ?, ?, ?, ?)',
    [
      job.jobId,
      job.requestEventId,
      job.status.name,
      job.scheduleAt,
      jsonEncode(job.toJson()),
    ],
  );
}

void main() {
  late SqliteDvmJobStore store;

  setUp(() {
    store = SqliteDvmJobStore(sqlite3.openInMemory(), closeDatabase: true);
  });

  tearDown(() => store.close());

  test('puts and gets a job by client job id', () async {
    await store.putJob(job('a'));

    final loaded = await store.getJobByClientJobId(
      clientPubkey: 'client',
      jobId: 'a',
    );
    expect(loaded?.toJson(), job('a').toJson());
    expect(
      await store.getJobByClientJobId(clientPubkey: 'client', jobId: 'missing'),
      isNull,
    );
    expect(
      await store.getJobByClientJobId(clientPubkey: 'other', jobId: 'a'),
      isNull,
    );
  });

  test('upserts on the request event id', () async {
    await store.putJob(job('a'));
    await store.putJob(job('a', status: DvmJobStatus.published));

    expect(await store.listJobs(), hasLength(1));
    expect(
      (await store.getJobByClientJobId(
        clientPubkey: 'client',
        jobId: 'a',
      ))?.status,
      DvmJobStatus.published,
    );
  });

  test('keeps the jobs of two clients sharing a job id', () async {
    await store.putJob(
      job('1', clientPubkey: 'alice', requestEventId: 'request-alice'),
    );
    await store.putJob(
      job('1', clientPubkey: 'bob', requestEventId: 'request-bob'),
    );

    expect(await store.listJobs(), hasLength(2));
    expect(
      (await store.getJobByClientJobId(
        clientPubkey: 'alice',
        jobId: '1',
      ))?.requestEventId,
      'request-alice',
    );
    expect(
      (await store.getJobByClientJobId(
        clientPubkey: 'bob',
        jobId: '1',
      ))?.requestEventId,
      'request-bob',
    );
  });

  test('finds a job by request event id', () async {
    await store.putJob(job('a'));

    expect((await store.getJobByRequestEventId('request-a'))?.jobId, 'a');
    expect(await store.getJobByRequestEventId('request-b'), isNull);
  });

  test('lists jobs by schedule time and filters active ones', () async {
    await store.putJob(job('late', scheduleAt: 300));
    await store.putJob(
      job('done', scheduleAt: 200, status: DvmJobStatus.cancelled),
    );
    await store.putJob(job('early', scheduleAt: 100));

    expect((await store.listJobs()).map((j) => j.jobId), [
      'early',
      'done',
      'late',
    ]);
    expect((await store.listActiveJobs()).map((j) => j.jobId), [
      'early',
      'late',
    ]);
  });

  test('rekeys a schema 1 database on the request event id', () async {
    final db = sqlite3.openInMemory();
    writeSchemaV1Job(db, job('a'));
    final migrated = SqliteDvmJobStore(db, closeDatabase: true);

    expect((await migrated.getJobByRequestEventId('request-a'))?.jobId, 'a');
    expect(
      (await migrated.getJobByClientJobId(
        clientPubkey: 'client',
        jobId: 'a',
      ))?.requestEventId,
      'request-a',
    );
    await migrated.putJob(
      job('a', clientPubkey: 'other', requestEventId: 'request-other'),
    );
    expect(await migrated.listJobs(), hasLength(2));
    await migrated.close();
  });

  group('open', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sqlite_dvm_job_store');
    });

    tearDown(() => dir.delete(recursive: true));

    test('persists across reopen', () async {
      final path = p.join(dir.path, 'scheduler.db');
      final first = await SqliteDvmJobStore.open(path);
      await first.putJob(job('a'));
      await first.close();

      final second = await SqliteDvmJobStore.open(path);
      expect((await second.getJobByRequestEventId('request-a'))?.jobId, 'a');
      await second.close();
    });

    test('imports a legacy sembast file', () async {
      final path = p.join(dir.path, 'scheduler.db');
      final legacyDb = await sembast.databaseFactoryIo.openDatabase(path);
      final legacy = SembastDvmJobStore(legacyDb);
      await legacy.putJob(job('a'));
      await legacy.putJob(job('b', scheduleAt: 50));
      await legacyDb.close();

      final migrated = await SqliteDvmJobStore.open(path);
      expect((await migrated.listJobs()).map((j) => j.jobId), ['b', 'a']);
      await migrated.close();

      expect(File('$path.sembast.bak').existsSync(), isTrue);
    });
  });
}
