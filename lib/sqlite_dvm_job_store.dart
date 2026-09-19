import 'dart:convert';
import 'dart:io';

import 'package:nostr_scheduler_dvm/nostr_scheduler_dvm.dart';
import 'package:sembast/sembast_io.dart' as sembast;
import 'package:sqlite3/sqlite3.dart';

class SqliteDvmJobStore implements DvmJobStore {
  static const int _schemaVersion = 1;
  static const String _sqliteHeader = 'SQLite format 3\u0000';

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
    _db.execute('''
      CREATE TABLE IF NOT EXISTS jobs (
        job_id TEXT PRIMARY KEY,
        request_event_id TEXT NOT NULL,
        status TEXT NOT NULL,
        schedule_at INTEGER NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS jobs_request_event_id
        ON jobs(request_event_id);
      CREATE INDEX IF NOT EXISTS jobs_status_schedule_at
        ON jobs(status, schedule_at);
    ''');
    _db.userVersion = _schemaVersion;
  }

  @override
  Future<void> putJob(DvmJob job) async => _putJobs([job]);

  void _putJobs(List<DvmJob> jobs) {
    final statement = _db.prepare('''
      INSERT INTO jobs (job_id, request_event_id, status, schedule_at, data)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(job_id) DO UPDATE SET
        request_event_id = excluded.request_event_id,
        status = excluded.status,
        schedule_at = excluded.schedule_at,
        data = excluded.data
    ''');
    _db.execute('BEGIN');
    try {
      for (final job in jobs) {
        statement.execute([
          job.jobId,
          job.requestEventId,
          job.status.name,
          job.scheduleAt,
          jsonEncode(job.toJson()),
        ]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      statement.close();
    }
  }

  @override
  Future<DvmJob?> getJob(String jobId) async {
    return _selectJobs('SELECT data FROM jobs WHERE job_id = ?', [
      jobId,
    ]).firstOrNull;
  }

  @override
  Future<DvmJob?> getJobByRequestEventId(String requestEventId) async {
    return _selectJobs(
      'SELECT data FROM jobs WHERE request_event_id = ? LIMIT 1',
      [requestEventId],
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
    if (!await file.exists() || await _isSqliteFile(file)) return const [];

    final legacyDb = await sembast.databaseFactoryIo.openDatabase(path);
    final jobs = await SembastDvmJobStore(legacyDb).listJobs();
    await legacyDb.close();
    await file.rename('$path.sembast.bak');
    return jobs;
  }

  static Future<bool> _isSqliteFile(File file) async {
    if (await file.length() == 0) return true;
    final raf = await file.open();
    try {
      final header = await raf.read(_sqliteHeader.length);
      return String.fromCharCodes(header) == _sqliteHeader;
    } finally {
      await raf.close();
    }
  }
}
