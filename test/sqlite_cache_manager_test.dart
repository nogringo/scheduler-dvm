import 'dart:io';

import 'package:ndk/ndk.dart';
import 'package:ndk_cache_manager_test_suite/ndk_cache_manager_test_suite.dart';
import 'package:path/path.dart' as p;
import 'package:scheduler_dvm/sqlite_cache_manager.dart';
import 'package:scheduler_dvm/sqlite_file.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  runCacheManagerTestSuite(
    name: 'SqliteCacheManager',
    createCacheManager: () async =>
        SqliteCacheManager(sqlite3.openInMemory(), closeDatabase: true),
    cleanUp: (cacheManager) => cacheManager.close(),
  );

  group('open', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sqlite_cache_test');
    });

    tearDown(() => tempDir.delete(recursive: true));

    test('replaces a legacy sembast file with a SQLite database', () async {
      final path = p.join(tempDir.path, 'ndk_cache.db');
      await File(path).writeAsString('{"version":1,"sembast":1}\n');

      final cache = await SqliteCacheManager.open(path);
      final event = Nip01Event(
        pubKey: 'pubkey',
        kind: 1,
        tags: const [],
        content: 'hello',
        createdAt: 1,
      );
      await cache.saveEvent(event);
      await cache.close();

      expect(await isSqliteFile(File(path)), isTrue);
      final reopened = await SqliteCacheManager.open(path);
      expect((await reopened.loadEvent(event.id))?.content, 'hello');
      await reopened.close();
    });
  });
}
