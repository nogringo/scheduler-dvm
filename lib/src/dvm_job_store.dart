// ignore_for_file: prefer_initializing_formals

import 'package:sembast/sembast.dart' as sembast;

import 'dvm_job.dart';

abstract class DvmJobStore {
  Future<void> putJob(DvmJob job);

  Future<DvmJob?> getJob(String jobId);

  Future<DvmJob?> getJobByRequestEventId(String requestEventId);

  Future<List<DvmJob>> listJobs();

  Future<List<DvmJob>> listActiveJobs();

  Future<void> close();
}

class SembastDvmJobStore implements DvmJobStore {
  final sembast.Database _db;
  final sembast.StoreRef<String, Map<String, Object?>> _jobs;
  final bool _closeDatabase;

  SembastDvmJobStore(
    this._db, {
    bool closeDatabase = false,
    String storeName = 'scheduler_dvm_jobs',
  }) : _closeDatabase = closeDatabase,
       _jobs = sembast.stringMapStoreFactory.store(storeName);

  @override
  Future<void> putJob(DvmJob job) {
    return _jobs.record(job.jobId).put(_db, job.toJson());
  }

  @override
  Future<DvmJob?> getJob(String jobId) async {
    final json = await _jobs.record(jobId).get(_db);
    return json == null ? null : DvmJob.fromJson(json);
  }

  @override
  Future<DvmJob?> getJobByRequestEventId(String requestEventId) async {
    final snapshots = await _jobs.find(
      _db,
      finder: sembast.Finder(
        filter: sembast.Filter.equals('requestEventId', requestEventId),
        limit: 1,
      ),
    );
    if (snapshots.isEmpty) return null;
    return DvmJob.fromJson(snapshots.first.value);
  }

  @override
  Future<List<DvmJob>> listJobs() async {
    final snapshots = await _jobs.find(
      _db,
      finder: sembast.Finder(sortOrders: [sembast.SortOrder('scheduleAt')]),
    );
    return snapshots
        .map((snapshot) => DvmJob.fromJson(snapshot.value))
        .toList();
  }

  @override
  Future<List<DvmJob>> listActiveJobs() async {
    final snapshots = await _jobs.find(
      _db,
      finder: sembast.Finder(
        filter: sembast.Filter.equals('status', 'scheduled'),
        sortOrders: [sembast.SortOrder('scheduleAt')],
      ),
    );
    return snapshots
        .map((snapshot) => DvmJob.fromJson(snapshot.value))
        .toList();
  }

  @override
  Future<void> close() async {
    if (_closeDatabase) {
      await _db.close();
    }
  }
}
