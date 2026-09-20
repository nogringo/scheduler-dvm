import 'dart:convert';
import 'dart:io';

import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:sembast/sembast_io.dart' as sembast;
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_file.dart';

class SqliteDvmJobStore implements DvmJobStore {
  static const int _schemaVersion = 2;

  final Database _db;
  final bool _closeDatabase;

  SqliteDvmJobStore(this._db, {this._closeDatabase = false}) {
    _migrate();
  }

  /// Opens the SQLite file at [path]. A legacy sembast file found there is
  /// imported, then kept as `<path>.sembast.bak`.
  static Future<SqliteDvmJobStore> open(String path) async {
    final legacyJobs = await _takeLegacySembastJobs(path);
    final db = sqlite3.open(path)..execute('PRAGMA journal_mode = WAL');
    final store = SqliteDvmJobStore(db, closeDatabase: true);
    if (legacyJobs.isNotEmpty) store._putJobs(legacyJobs);
    return store;
  }

  void _migrate() {
    if (_db.userVersion >= _schemaVersion) return;
    _db.execute('BEGIN');
    try {
      final rekeyed = _db.userVersion == 1 ? _dropSchemaV1() : const <DvmJob>[];
      _db.execute('''
        CREATE TABLE IF NOT EXISTS jobs (
          request_event_id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL,
          client_pubkey TEXT NOT NULL,
          status TEXT NOT NULL,
          schedule_at INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS jobs_client_pubkey_job_id
          ON jobs(client_pubkey, job_id);
        CREATE INDEX IF NOT EXISTS jobs_status_schedule_at
          ON jobs(status, schedule_at);
      ''');
      _db.userVersion = _schemaVersion;
      _insertJobs(rekeyed);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Schema 1 keyed jobs by their `job_id`, which clients pick and only holds
  /// per client, so one client's job could overwrite another's.
  List<DvmJob> _dropSchemaV1() {
    final jobs = _selectJobs('SELECT data FROM jobs');
    _db.execute('DROP TABLE jobs');
    return jobs;
  }

  @override
  Future<void> putJob(DvmJob job) async => _putJobs([job]);

  void _putJobs(List<DvmJob> jobs) {
    _db.execute('BEGIN');
    try {
      _insertJobs(jobs);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _insertJobs(List<DvmJob> jobs) {
    if (jobs.isEmpty) return;
    final statement = _db.prepare('''
      INSERT INTO jobs (
        request_event_id, job_id, client_pubkey, status, schedule_at, data
      )
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(request_event_id) DO UPDATE SET
        job_id = excluded.job_id,
        client_pubkey = excluded.client_pubkey,
        status = excluded.status,
        schedule_at = excluded.schedule_at,
        data = excluded.data
    ''');
    try {
      for (final job in jobs) {
        statement.execute([
          job.requestEventId,
          job.jobId,
          job.clientPubkey,
          job.status.name,
          job.scheduleAt,
          jsonEncode(job.toJson()),
        ]);
      }
    } finally {
      statement.close();
    }
  }

  @override
  Future<DvmJob?> getJobByRequestEventId(String requestEventId) async {
    return _selectJobs('SELECT data FROM jobs WHERE request_event_id = ?', [
      requestEventId,
    ]).firstOrNull;
  }

  @override
  Future<DvmJob?> getJobByClientJobId({
    required String clientPubkey,
    required String jobId,
  }) async {
    return _selectJobs(
      'SELECT data FROM jobs WHERE client_pubkey = ? AND job_id = ? LIMIT 1',
      [clientPubkey, jobId],
    ).firstOrNull;
  }

  @override
  Future<List<DvmJob>> listJobs() async {
    return _selectJobs('SELECT data FROM jobs ORDER BY schedule_at');
  }

  @override
  Future<List<DvmJob>> listActiveJobs() async {
    return _selectJobs(
      'SELECT data FROM jobs WHERE status = ? ORDER BY schedule_at',
      [DvmJobStatus.scheduled.name],
    );
  }

  @override
  Future<void> close() async {
    if (_closeDatabase) _db.close();
  }

  List<DvmJob> _selectJobs(String sql, [List<Object?> parameters = const []]) {
    return _db
        .select(sql, parameters)
        .map(
          (row) => DvmJob.fromJson(
            (jsonDecode(row['data'] as String) as Map).cast<String, Object?>(),
          ),
        )
        .toList();
  }

  static Future<List<DvmJob>> _takeLegacySembastJobs(String path) async {
    final file = File(path);
    if (!await file.exists() || await isSqliteFile(file)) return const [];

    final legacyDb = await sembast.databaseFactoryIo.openDatabase(path);
    final jobs = await SembastDvmJobStore(legacyDb).listJobs();
    await legacyDb.close();
    await file.rename('$path.sembast.bak');
    return jobs;
  }
}
