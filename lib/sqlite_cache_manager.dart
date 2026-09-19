import 'dart:convert';
import 'dart:io';

import 'package:ndk/data_layer/repositories/cache_manager/ndk_extensions.dart';
import 'package:ndk/entities.dart';
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/event_eviction_planner.dart';
import 'package:ndk/shared/nips/nip01/event_visibility_resolver.dart';
import 'package:ndk/shared/nips/nip01/helpers.dart';
import 'package:sqlite3/sqlite3.dart';

import 'sqlite_file.dart';

/// NDK [CacheManager] backed by SQLite. Mirrors the semantics of NDK's
/// `SembastCacheManager`.
class SqliteCacheManager extends CacheManager {
  static const int _schemaVersion = 1;

  static const List<String> _tables = [
    'events',
    'event_cache_state',
    'event_sources',
    'event_delivery_records',
    'relay_delivery_targets',
    'decrypted_event_payloads',
    'metadata',
    'contact_lists',
    'relay_lists',
    'nip05',
    'relay_sets',
    'filter_fetched_ranges',
    'keysets',
    'proofs',
    'mint_infos',
    'secret_counters',
  ];

  final Database _db;
  final bool _closeDatabase;

  late final EventVisibilityResolver _visibility = EventVisibilityResolver(
    _loadRawEvents,
  );

  SqliteCacheManager(this._db, {this._closeDatabase = false}) {
    _migrate();
  }

  /// Opens the SQLite file at [path]. A file found there that is not SQLite
  /// (the former sembast cache) is deleted.
  static Future<SqliteCacheManager> open(String path) async {
    final file = File(path);
    if (await file.exists() && !await isSqliteFile(file)) await file.delete();
    final db = sqlite3.open(path)..execute('PRAGMA journal_mode = WAL');
    return SqliteCacheManager(db, closeDatabase: true);
  }

  void _migrate() {
    if (_db.userVersion >= _schemaVersion) return;
    _db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        pubkey TEXT NOT NULL,
        kind INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        content TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS events_pubkey_kind
        ON events(pubkey, kind, created_at);
      CREATE INDEX IF NOT EXISTS events_kind ON events(kind, created_at);
      CREATE INDEX IF NOT EXISTS events_created_at ON events(created_at);

      CREATE TABLE IF NOT EXISTS event_cache_state (
        event_id TEXT PRIMARY KEY,
        pubkey TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS event_cache_state_pubkey
        ON event_cache_state(pubkey);

      CREATE TABLE IF NOT EXISTS event_sources (
        event_id TEXT NOT NULL,
        relay_url TEXT NOT NULL,
        PRIMARY KEY (event_id, relay_url)
      );

      CREATE TABLE IF NOT EXISTS event_delivery_records (
        event_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        data TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS relay_delivery_targets (
        event_id TEXT NOT NULL,
        relay_url TEXT NOT NULL,
        state TEXT NOT NULL,
        next_retry_at INTEGER,
        data TEXT NOT NULL,
        PRIMARY KEY (event_id, relay_url)
      );

      CREATE TABLE IF NOT EXISTS decrypted_event_payloads (
        event_id TEXT NOT NULL,
        viewer_pubkey TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (event_id, viewer_pubkey)
      );

      CREATE TABLE IF NOT EXISTS metadata (
        pubkey TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS contact_lists (
        pubkey TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS relay_lists (
        pubkey TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS nip05 (
        pubkey TEXT PRIMARY KEY,
        nip05 TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS nip05_nip05 ON nip05(nip05);

      CREATE TABLE IF NOT EXISTS relay_sets (
        pubkey TEXT NOT NULL,
        name TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY (pubkey, name)
      );

      CREATE TABLE IF NOT EXISTS filter_fetched_ranges (
        key TEXT PRIMARY KEY,
        filter_hash TEXT NOT NULL,
        relay_url TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS filter_fetched_ranges_filter_hash
        ON filter_fetched_ranges(filter_hash, relay_url);
      CREATE INDEX IF NOT EXISTS filter_fetched_ranges_relay_url
        ON filter_fetched_ranges(relay_url);

      CREATE TABLE IF NOT EXISTS keysets (
        id TEXT PRIMARY KEY,
        mint_url TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS proofs (
        secret TEXT PRIMARY KEY,
        keyset_id TEXT NOT NULL,
        state TEXT NOT NULL,
        amount INTEGER NOT NULL,
        data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS mint_infos (
        key TEXT PRIMARY KEY,
        data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS secret_counters (
        mint_url TEXT NOT NULL,
        keyset_id TEXT NOT NULL,
        counter INTEGER NOT NULL,
        PRIMARY KEY (mint_url, keyset_id)
      );
    ''');
    _db.userVersion = _schemaVersion;
  }

  @override
  Future<void> close() async {
    if (_closeDatabase) _db.close();
  }

  // =====================
  // Events
  // =====================

  @override
  Future<void> saveEvent(Nip01Event event) async {
    _putEvents([event]);
    await _refreshDerivedStateForPubKeys({event.pubKey});
  }

  @override
  Future<bool> saveEventIfAbsent(Nip01Event event) async {
    _db.execute(
      'INSERT OR IGNORE INTO events '
      '(id, pubkey, kind, created_at, content, data) VALUES (?, ?, ?, ?, ?, ?)',
      _eventRow(event),
    );
    final inserted = _db.updatedRows > 0;
    if (inserted) await _refreshDerivedStateForPubKeys({event.pubKey});
    return inserted;
  }

  @override
  Future<void> saveEvents(List<Nip01Event> events) async {
    _putEvents(events);
    await _refreshDerivedStateForPubKeys(
      events.map((event) => event.pubKey).toSet(),
    );
  }

  void _putEvents(List<Nip01Event> events) {
    _putRows('events', [
      'id',
      'pubkey',
      'kind',
      'created_at',
      'content',
      'data',
    ], events.map(_eventRow));
  }

  List<Object?> _eventRow(Nip01Event event) => [
    event.id,
    event.pubKey,
    event.kind,
    event.createdAt,
    event.content,
    jsonEncode(event.toJsonForStorage()),
  ];

  @override
  Future<Nip01Event?> loadEvent(String id) async {
    return _selectData('SELECT data FROM events WHERE id = ?', [
      id,
    ]).map(Nip01EventExtension.fromJsonStorage).firstOrNull;
  }

  @override
  Future<List<Nip01Event>> loadEvents({
    List<String>? ids,
    List<String>? pubKeys,
    List<int>? kinds,
    Map<String, List<String>>? tags,
    int? since,
    int? until,
    String? search,
    int? limit,
  }) {
    return _loadEventsInternal(
      ids: ids,
      pubKeys: pubKeys,
      kinds: kinds,
      tags: tags,
      since: since,
      until: until,
      search: search,
      limit: limit,
      applyVisibilityRules: true,
    );
  }

  @override
  Future<List<HiddenEvent>> loadHiddenEvents({
    List<String>? ids,
    List<String>? pubKeys,
    List<int>? kinds,
    List<String>? coordinates,
    Map<String, List<String>>? tags,
    int? since,
    int? until,
    String? search,
    int? limit,
    Set<HiddenEventReason> reasons = kAllHiddenEventReasons,
  }) {
    return _visibility.loadHiddenEvents(
      ids: ids,
      pubKeys: pubKeys,
      kinds: kinds,
      coordinates: coordinates,
      tags: tags,
      since: since,
      until: until,
      search: search,
      limit: limit,
      reasons: reasons,
    );
  }

  @override
  @Deprecated('Use loadEvents() instead')
  Future<Iterable<Nip01Event>> searchEvents({
    List<String>? ids,
    List<String>? authors,
    List<int>? kinds,
    Map<String, List<String>>? tags,
    int? since,
    int? until,
    String? search,
    int limit = 100,
  }) {
    return loadEvents(
      ids: ids,
      pubKeys: authors,
      kinds: kinds,
      tags: tags,
      since: since,
      until: until,
      search: search,
      limit: limit,
    );
  }

  Future<List<Nip01Event>> _loadRawEvents({
    List<String>? ids,
    List<String>? pubKeys,
    List<int>? kinds,
    Map<String, List<String>>? tags,
    int? since,
    int? until,
    String? search,
    int? limit,
  }) {
    return _loadEventsInternal(
      ids: ids,
      pubKeys: pubKeys,
      kinds: kinds,
      tags: tags,
      since: since,
      until: until,
      search: search,
      limit: limit,
      applyVisibilityRules: false,
    );
  }

  Future<List<Nip01Event>> _loadEventsInternal({
    List<String>? ids,
    List<String>? pubKeys,
    List<int>? kinds,
    Map<String, List<String>>? tags,
    int? since,
    int? until,
    String? search,
    int? limit,
    required bool applyVisibilityRules,
  }) async {
    final where = _Where()
      ..inList('id', ids)
      ..inList('pubkey', pubKeys)
      ..inList('kind', kinds);
    if (since != null) where.add('created_at >= ?', [since]);
    if (until != null) where.add('created_at <= ?', [until]);

    final searchPattern = search != null && search.isNotEmpty
        ? RegExp(search)
        : null;
    final hasTags = tags != null && tags.isNotEmpty;
    final hasLimit = limit != null && limit > 0;
    // Pushing the limit down would spend it on rows that the visibility rules,
    // the search or the tag filter below then remove.
    final sqlLimit =
        hasLimit && !applyVisibilityRules && searchPattern == null && !hasTags
        ? ' LIMIT $limit'
        : '';

    var events = _selectData(
      'SELECT data FROM events${where.sql} '
      'ORDER BY created_at DESC, id$sqlLimit',
      where.parameters,
    ).map(Nip01EventExtension.fromJsonStorage).toList();

    if (searchPattern != null) {
      events = events
          .where((event) => searchPattern.hasMatch(event.content))
          .toList();
    }
    if (applyVisibilityRules) {
      events = await _visibility.filterVisible(events);
    }
    if (hasTags) {
      events = events.where((event) => _matchesTags(event, tags)).toList();
    }
    if (hasLimit && events.length > limit) {
      events = events.take(limit).toList();
    }
    return events;
  }

  static bool _matchesTags(Nip01Event event, Map<String, List<String>> tags) {
    return tags.entries.every((tagEntry) {
      var tagName = tagEntry.key;
      final tagValues = tagEntry.value;
      if (tagName.startsWith('#') && tagName.length > 1) {
        tagName = tagName.substring(1);
      }

      if (tagValues.isEmpty && event.tags.any((tag) => tag[0] == tagName)) {
        return true;
      }

      final eventTags = event.getTags(tagName);
      return tagValues.any((value) => eventTags.contains(value.toLowerCase()));
    });
  }

  @override
  Future<void> removeEvent(String id) async {
    final removed = await loadEvent(id);
    _db.execute('DELETE FROM events WHERE id = ?', [id]);
    _removeEventSidecarsByIds([id]);
    if (removed != null) {
      await _refreshDerivedStateForPubKeys({removed.pubKey});
    }
  }

  @override
  Future<void> removeEvents({
    List<String>? ids,
    List<String>? pubKeys,
    List<int>? kinds,
    Map<String, List<String>>? tags,
    int? since,
    int? until,
  }) async {
    if ((ids == null || ids.isEmpty) &&
        (pubKeys == null || pubKeys.isEmpty) &&
        (kinds == null || kinds.isEmpty) &&
        (tags == null || tags.isEmpty) &&
        since == null &&
        until == null) {
      return;
    }

    final matchingEvents = await _loadRawEvents(
      ids: ids,
      pubKeys: pubKeys,
      kinds: kinds,
      tags: tags,
      since: since,
      until: until,
    );
    await _removeEventsAndRefresh(matchingEvents);
  }

  @override
  Future<void> removeAllEventsByPubKey(String pubKey) async {
    final events = await _loadRawEvents(pubKeys: [pubKey]);
    _transaction(() {
      _db.execute('DELETE FROM events WHERE pubkey = ?', [pubKey]);
      _removeEventSidecarsByIds(events.map((event) => event.id));
      _db.execute('DELETE FROM contact_lists WHERE pubkey = ?', [pubKey]);
      _db.execute('DELETE FROM metadata WHERE pubkey = ?', [pubKey]);
    });
    await _refreshUserRelayListProjection(pubKey);
  }

  @override
  Future<void> removeAllEvents() async {
    _deleteAll([
      'events',
      'event_cache_state',
      'event_sources',
      'event_delivery_records',
      'relay_delivery_targets',
      'decrypted_event_payloads',
      'relay_lists',
    ]);
  }

  Future<void> _removeEventsAndRefresh(List<Nip01Event> events) async {
    if (events.isEmpty) return;
    final ids = events.map((event) => event.id).toList();
    _transaction(() {
      _deleteIn('events', 'id', ids);
      _removeEventSidecarsByIds(ids);
    });
    await _refreshDerivedStateForPubKeys(
      events.map((event) => event.pubKey).toSet(),
    );
  }

  void _removeEventSidecarsByIds(Iterable<String> eventIds) {
    final ids = eventIds.toSet().toList();
    if (ids.isEmpty) return;
    _transaction(() {
      for (final table in const [
        'event_sources',
        'event_delivery_records',
        'relay_delivery_targets',
        'decrypted_event_payloads',
        'event_cache_state',
      ]) {
        _deleteIn(table, 'event_id', ids);
      }
    });
  }

  @override
  Future<EvictionResult> evict(EvictionPolicy policy) async {
    final stateRecords = _selectData(
      'SELECT data FROM event_cache_state',
    ).map(EventCacheStateRecord.fromJson).toList();
    final deliveryRecords = await loadEventDeliveryRecords();
    final relayTargets = await loadRelayDeliveryTargets();
    final lockedEventIds = <String>{
      ...deliveryRecords
          .where((record) => record.status != EventDeliveryStatus.delivered)
          .map((record) => record.eventId),
      ...relayTargets
          .where((target) => target.state != RelayDeliveryState.acked)
          .map((target) => target.eventId),
    };
    final deliveredEventIds = deliveryRecords
        .where((record) => record.status == EventDeliveryStatus.delivered)
        .map((record) => record.eventId)
        .toSet();
    final plan = EventEvictionPlanner.planFromStateRecords(
      stateRecords: stateRecords,
      lockedEventIds: lockedEventIds,
      deliveredEventIds: deliveredEventIds,
      policy: policy,
    );

    if (plan.eventIdsToRemove.isNotEmpty) {
      await _removeEventsAndRefresh(
        await _loadRawEvents(ids: plan.eventIdsToRemove.toList()),
      );
    }

    // Sweep leftover delivery records whose event was kept (or never stored).
    // A terminally failed record swept here unpins its event for the next run.
    final deliverySweep = EventEvictionPlanner.planDeliverySweep(
      deliveryRecords: deliveryRecords
          .where((record) => !plan.eventIdsToRemove.contains(record.eventId))
          .toList(),
      policy: policy,
    );
    if (deliverySweep.deliveryEventIdsToRemove.isNotEmpty) {
      final ids = deliverySweep.deliveryEventIdsToRemove.toList();
      _transaction(() {
        _deleteIn('event_delivery_records', 'event_id', ids);
        _deleteIn('relay_delivery_targets', 'event_id', ids);
      });
    }

    return plan.toResult().copyWith(
      removedCompletedDeliveries: deliverySweep.removedCompletedDeliveries,
      removedTerminalFailedDeliveries:
          deliverySweep.removedTerminalFailedDeliveries,
    );
  }

  // =====================
  // Derived state
  // =====================

  Future<Nip01Event?> _loadLatestVisibleEvent({
    required String pubKey,
    required int kind,
  }) async {
    final events = await loadEvents(pubKeys: [pubKey], kinds: [kind], limit: 1);
    return events.firstOrNull;
  }

  Future<void> _refreshDerivedStateForPubKeys(Set<String> pubKeys) async {
    for (final pubKey in pubKeys) {
      final rawPubKeyEvents = await _loadRawEvents(pubKeys: [pubKey]);
      final stateRecords = EventCacheStateRecord.buildForEvents(
        rawPubKeyEvents,
      );
      _transaction(() {
        _db.execute('DELETE FROM event_cache_state WHERE pubkey = ?', [pubKey]);
        _putRows(
          'event_cache_state',
          ['event_id', 'pubkey', 'data'],
          stateRecords.map(
            (record) => [
              record.eventId,
              record.pubKey,
              jsonEncode(record.toJson()),
            ],
          ),
        );
      });

      final metadataEvent = await _loadLatestVisibleEvent(
        pubKey: pubKey,
        kind: Metadata.kKind,
      );
      if (metadataEvent == null) {
        _db.execute('DELETE FROM metadata WHERE pubkey = ?', [pubKey]);
      } else {
        final metadata = Metadata.fromEvent(metadataEvent);
        metadata.refreshedTimestamp = Helpers.now;
        _putJson('metadata', pubKey, metadata.toJsonForStorage());
      }

      final contactListEvent = await _loadLatestVisibleEvent(
        pubKey: pubKey,
        kind: ContactList.kKind,
      );
      if (contactListEvent == null) {
        _db.execute('DELETE FROM contact_lists WHERE pubkey = ?', [pubKey]);
      } else {
        _putJson(
          'contact_lists',
          pubKey,
          ContactList.fromEvent(contactListEvent).toJsonForStorage(),
        );
      }

      await _refreshUserRelayListProjection(pubKey);
    }
  }

  Future<void> _refreshUserRelayListProjection(String pubKey) async {
    final events = await loadEvents(
      pubKeys: [pubKey],
      kinds: [Nip65.kKind, ContactList.kKind],
    );

    Nip01Event? latestNip65;
    Nip01Event? latestContactListWithRelays;
    for (final event in events) {
      if (event.kind == Nip65.kKind) {
        latestNip65 ??= event;
      } else if (event.kind == ContactList.kKind &&
          ContactList.relaysFromContent(event).isNotEmpty) {
        latestContactListWithRelays ??= event;
      }
    }

    final UserRelayList? relayList;
    if (latestNip65 != null) {
      relayList = UserRelayList.fromNip65(Nip65.fromEvent(latestNip65));
    } else if (latestContactListWithRelays != null) {
      relayList = UserRelayList.fromNip02EventContent(
        latestContactListWithRelays,
      );
    } else {
      relayList = null;
    }

    if (relayList == null) {
      _db.execute('DELETE FROM relay_lists WHERE pubkey = ?', [pubKey]);
    } else {
      _putJson('relay_lists', pubKey, relayList.toJsonForStorage());
    }
  }

  // =====================
  // Event sources
  // =====================

  @override
  Future<void> addEventSource({
    required String eventId,
    required String relayUrl,
  }) {
    return addEventSources(eventId: eventId, relayUrls: [relayUrl]);
  }

  @override
  Future<void> addEventSources({
    required String eventId,
    required Iterable<String> relayUrls,
  }) async {
    _putRows('event_sources', [
      'event_id',
      'relay_url',
    ], relayUrls.map((relayUrl) => [eventId, relayUrl]));
  }

  @override
  Future<List<String>> loadEventSources(String eventId) async {
    return _db
        .select(
          'SELECT relay_url FROM event_sources WHERE event_id = ? '
          'ORDER BY relay_url',
          [eventId],
        )
        .map((row) => row['relay_url'] as String)
        .toList();
  }

  @override
  Future<void> removeEventSources(String eventId) async {
    _db.execute('DELETE FROM event_sources WHERE event_id = ?', [eventId]);
  }

  // =====================
  // Event delivery records
  // =====================

  @override
  Future<void> saveEventDeliveryRecord(EventDeliveryRecord record) {
    return saveEventDeliveryRecords([record]);
  }

  @override
  Future<void> saveEventDeliveryRecords(
    List<EventDeliveryRecord> records,
  ) async {
    _putRows(
      'event_delivery_records',
      ['event_id', 'status', 'created_at', 'data'],
      records.map(
        (record) => [
          record.eventId,
          record.status.name,
          record.createdAt,
          jsonEncode(record.toJson()),
        ],
      ),
    );
  }

  @override
  Future<EventDeliveryRecord?> loadEventDeliveryRecord(String eventId) async {
    return _selectData(
      'SELECT data FROM event_delivery_records WHERE event_id = ?',
      [eventId],
    ).map(EventDeliveryRecord.fromJson).firstOrNull;
  }

  @override
  Future<List<EventDeliveryRecord>> loadEventDeliveryRecords({
    EventDeliveryStatus? status,
    int? limit,
  }) async {
    final where = _Where();
    if (status != null) where.add('status = ?', [status.name]);
    return _selectData(
      'SELECT data FROM event_delivery_records${where.sql} '
      'ORDER BY created_at${_limit(limit)}',
      where.parameters,
    ).map(EventDeliveryRecord.fromJson).toList();
  }

  @override
  Future<void> removeEventDeliveryRecord(String eventId) async {
    _db.execute('DELETE FROM event_delivery_records WHERE event_id = ?', [
      eventId,
    ]);
  }

  @override
  Future<void> removeAllEventDeliveryRecords() async {
    _deleteAll(['event_delivery_records']);
  }

  // =====================
  // Relay delivery targets
  // =====================

  @override
  Future<void> saveRelayDeliveryTarget(RelayDeliveryTarget target) {
    return saveRelayDeliveryTargets([target]);
  }

  @override
  Future<void> saveRelayDeliveryTargets(
    List<RelayDeliveryTarget> targets,
  ) async {
    _putRows(
      'relay_delivery_targets',
      ['event_id', 'relay_url', 'state', 'next_retry_at', 'data'],
      targets.map(
        (target) => [
          target.eventId,
          target.relayUrl,
          target.state.name,
          target.nextRetryAt,
          jsonEncode(target.toJson()),
        ],
      ),
    );
  }

  @override
  Future<RelayDeliveryTarget?> loadRelayDeliveryTarget({
    required String eventId,
    required String relayUrl,
  }) async {
    return _selectData(
      'SELECT data FROM relay_delivery_targets '
      'WHERE event_id = ? AND relay_url = ?',
      [eventId, relayUrl],
    ).map(RelayDeliveryTarget.fromJson).firstOrNull;
  }

  @override
  Future<List<RelayDeliveryTarget>> loadRelayDeliveryTargets({
    String? eventId,
    String? relayUrl,
    RelayDeliveryState? state,
    bool excludeAcked = false,
    int? limit,
  }) async {
    final where = _Where();
    if (eventId != null) where.add('event_id = ?', [eventId]);
    if (relayUrl != null) where.add('relay_url = ?', [relayUrl]);
    if (state != null) where.add('state = ?', [state.name]);
    if (excludeAcked) {
      where.add('state != ?', [RelayDeliveryState.acked.name]);
    }
    return _selectData(
      'SELECT data FROM relay_delivery_targets${where.sql} '
      'ORDER BY next_retry_at, event_id, relay_url${_limit(limit)}',
      where.parameters,
    ).map(RelayDeliveryTarget.fromJson).toList();
  }

  @override
  Future<void> removeRelayDeliveryTarget({
    required String eventId,
    required String relayUrl,
  }) async {
    _db.execute(
      'DELETE FROM relay_delivery_targets WHERE event_id = ? AND relay_url = ?',
      [eventId, relayUrl],
    );
  }

  @override
  Future<void> removeRelayDeliveryTargets(String eventId) async {
    _db.execute('DELETE FROM relay_delivery_targets WHERE event_id = ?', [
      eventId,
    ]);
  }

  @override
  Future<void> removeAllRelayDeliveryTargets() async {
    _deleteAll(['relay_delivery_targets']);
  }

  // =====================
  // Decrypted event payloads
  // =====================

  @override
  Future<void> saveDecryptedEventPayloadRecord(
    DecryptedEventPayloadRecord record,
  ) {
    return saveDecryptedEventPayloadRecords([record]);
  }

  @override
  Future<void> saveDecryptedEventPayloadRecords(
    List<DecryptedEventPayloadRecord> records,
  ) async {
    _putRows(
      'decrypted_event_payloads',
      ['event_id', 'viewer_pubkey', 'status', 'created_at', 'data'],
      records.map(
        (record) => [
          record.eventId,
          record.viewerPubKey,
          record.status.name,
          record.createdAt,
          jsonEncode(record.toJson()),
        ],
      ),
    );
  }

  @override
  Future<DecryptedEventPayloadRecord?> loadDecryptedEventPayloadRecord({
    required String eventId,
    required String viewerPubKey,
  }) async {
    return _selectData(
      'SELECT data FROM decrypted_event_payloads '
      'WHERE event_id = ? AND viewer_pubkey = ?',
      [eventId, viewerPubKey],
    ).map(DecryptedEventPayloadRecord.fromJson).firstOrNull;
  }

  @override
  Future<List<DecryptedEventPayloadRecord>> loadDecryptedEventPayloadRecords({
    String? eventId,
    String? viewerPubKey,
    DecryptedPayloadStatus? status,
    int? limit,
  }) async {
    final where = _Where();
    if (eventId != null) where.add('event_id = ?', [eventId]);
    if (viewerPubKey != null) where.add('viewer_pubkey = ?', [viewerPubKey]);
    if (status != null) where.add('status = ?', [status.name]);
    return _selectData(
      'SELECT data FROM decrypted_event_payloads${where.sql} '
      'ORDER BY created_at${_limit(limit)}',
      where.parameters,
    ).map(DecryptedEventPayloadRecord.fromJson).toList();
  }

  @override
  Future<void> removeDecryptedEventPayloadRecord({
    required String eventId,
    required String viewerPubKey,
  }) async {
    _db.execute(
      'DELETE FROM decrypted_event_payloads '
      'WHERE event_id = ? AND viewer_pubkey = ?',
      [eventId, viewerPubKey],
    );
  }

  @override
  Future<void> removeDecryptedEventPayloadRecords(String eventId) async {
    _db.execute('DELETE FROM decrypted_event_payloads WHERE event_id = ?', [
      eventId,
    ]);
  }

  @override
  Future<void> removeAllDecryptedEventPayloadRecords() async {
    _deleteAll(['decrypted_event_payloads']);
  }

  // =====================
  // Metadata
  // =====================

  @override
  Future<void> saveMetadata(Metadata metadata) async {
    final event = metadata.toEvent();
    await saveEvent(event);
    final normalized = Metadata.fromEvent(event);
    normalized.refreshedTimestamp = metadata.refreshedTimestamp;
    _putJson('metadata', metadata.pubKey, normalized.toJsonForStorage());
  }

  @override
  Future<void> saveMetadatas(List<Metadata> metadatas) async {
    for (final metadata in metadatas) {
      await saveMetadata(metadata);
    }
  }

  @override
  Future<Metadata?> loadMetadata(String pubKey) async {
    final event = await _loadLatestVisibleEvent(
      pubKey: pubKey,
      kind: Metadata.kKind,
    );
    if (event != null) {
      return Metadata.fromEvent(event)..refreshedTimestamp = Helpers.now;
    }
    return _getJson(
      'metadata',
      pubKey,
    ).map(MetadataExtension.fromJsonStorage).firstOrNull;
  }

  @override
  Future<List<Metadata?>> loadMetadatas(List<String> pubKeys) {
    return Future.wait(pubKeys.map(loadMetadata));
  }

  @override
  Future<Iterable<Metadata>> searchMetadatas(String search, int limit) async {
    final events = await loadEvents(kinds: [Metadata.kKind]);
    final normalizedSearch = search.trim().toLowerCase();
    final matches = events.map(Metadata.fromEvent).where((metadata) {
      if (normalizedSearch.isEmpty) return true;
      return metadata.matchesSearch(normalizedSearch) ||
          (metadata.about?.toLowerCase().contains(normalizedSearch) ?? false) ||
          (metadata.cleanNip05?.contains(normalizedSearch) ?? false);
    }).toList()..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
    return matches.take(limit);
  }

  @override
  Future<void> removeMetadata(String pubKey) async {
    _db.execute('DELETE FROM metadata WHERE pubkey = ?', [pubKey]);
    await removeEvents(pubKeys: [pubKey], kinds: [Metadata.kKind]);
  }

  @override
  Future<void> removeAllMetadatas() async {
    _deleteAll(['metadata']);
    await removeEvents(kinds: [Metadata.kKind]);
  }

  // =====================
  // Contact lists
  // =====================

  @override
  Future<void> saveContactList(ContactList contactList) async {
    final event = contactList.toEvent();
    await saveEvent(event);
    _putJson(
      'contact_lists',
      contactList.pubKey,
      ContactList.fromEvent(event).toJsonForStorage(),
    );
  }

  @override
  Future<void> saveContactLists(List<ContactList> contactLists) async {
    for (final contactList in contactLists) {
      await saveContactList(contactList);
    }
  }

  @override
  Future<ContactList?> loadContactList(String pubKey) async {
    final event = await _loadLatestVisibleEvent(
      pubKey: pubKey,
      kind: ContactList.kKind,
    );
    if (event != null) return ContactList.fromEvent(event);
    return _getJson(
      'contact_lists',
      pubKey,
    ).map(ContactListExtension.fromJsonStorage).firstOrNull;
  }

  @override
  Future<void> removeContactList(String pubKey) async {
    _db.execute('DELETE FROM contact_lists WHERE pubkey = ?', [pubKey]);
    await removeEvents(pubKeys: [pubKey], kinds: [ContactList.kKind]);
  }

  @override
  Future<void> removeAllContactLists() async {
    _deleteAll(['contact_lists']);
    await removeEvents(kinds: [ContactList.kKind]);
  }

  // =====================
  // User relay lists
  // =====================

  @override
  Future<void> saveUserRelayList(UserRelayList userRelayList) {
    return saveUserRelayLists([userRelayList]);
  }

  @override
  Future<void> saveUserRelayLists(List<UserRelayList> userRelayLists) async {
    _putRows(
      'relay_lists',
      ['pubkey', 'data'],
      userRelayLists.map(
        (list) => [list.pubKey, jsonEncode(list.toJsonForStorage())],
      ),
    );
  }

  @override
  Future<UserRelayList?> loadUserRelayList(String pubKey) async {
    final stored = _getJson('relay_lists', pubKey);
    if (stored.isNotEmpty) {
      return UserRelayListExtension.fromJsonStorage(stored.first);
    }
    await _refreshUserRelayListProjection(pubKey);
    return _getJson(
      'relay_lists',
      pubKey,
    ).map(UserRelayListExtension.fromJsonStorage).firstOrNull;
  }

  @override
  Future<void> removeUserRelayList(String pubKey) async {
    _db.execute('DELETE FROM relay_lists WHERE pubkey = ?', [pubKey]);
  }

  @override
  Future<void> removeAllUserRelayLists() async {
    _deleteAll(['relay_lists']);
  }

  // =====================
  // Relay sets
  // =====================

  @override
  Future<void> saveRelaySet(RelaySet relaySet) async {
    _putRows(
      'relay_sets',
      ['pubkey', 'name', 'data'],
      [
        [
          relaySet.pubKey,
          relaySet.name,
          jsonEncode(relaySet.toJsonForStorage()),
        ],
      ],
    );
  }

  @override
  Future<RelaySet?> loadRelaySet(String name, String pubKey) async {
    return _selectData(
      'SELECT data FROM relay_sets WHERE pubkey = ? AND name = ?',
      [pubKey, name],
    ).map(RelaySetExtension.fromJsonStorage).firstOrNull;
  }

  @override
  Future<void> removeRelaySet(String name, String pubKey) async {
    _db.execute('DELETE FROM relay_sets WHERE pubkey = ? AND name = ?', [
      pubKey,
      name,
    ]);
  }

  @override
  Future<void> removeAllRelaySets() async {
    _deleteAll(['relay_sets']);
  }

  // =====================
  // NIP-05
  // =====================

  @override
  Future<void> saveNip05(Nip05 nip05) => saveNip05s([nip05]);

  @override
  Future<void> saveNip05s(List<Nip05> nip05s) async {
    _putRows(
      'nip05',
      ['pubkey', 'nip05', 'data'],
      nip05s.map(
        (nip05) => [
          nip05.pubKey,
          nip05.nip05,
          jsonEncode(nip05.toJsonForStorage()),
        ],
      ),
    );
  }

  @override
  Future<Nip05?> loadNip05({String? pubKey, String? identifier}) async {
    final List<Map<String, dynamic>> rows;
    if (pubKey != null) {
      rows = _getJson('nip05', pubKey);
    } else if (identifier != null) {
      rows = _selectData('SELECT data FROM nip05 WHERE nip05 = ? LIMIT 1', [
        identifier,
      ]);
    } else {
      return null;
    }
    return rows.map(Nip05Extension.fromJsonStorage).firstOrNull;
  }

  @override
  Future<List<Nip05?>> loadNip05s(List<String> pubKeys) async {
    final byPubKey = {
      for (final nip05 in _selectData(
        'SELECT data FROM nip05 WHERE pubkey IN (${_placeholders(pubKeys.length)})',
        pubKeys,
      ).map(Nip05Extension.fromJsonStorage))
        nip05.pubKey: nip05,
    };
    return pubKeys.map((pubKey) => byPubKey[pubKey]).toList();
  }

  @override
  Future<void> removeNip05(String pubKey) async {
    _db.execute('DELETE FROM nip05 WHERE pubkey = ?', [pubKey]);
  }

  @override
  Future<void> removeAllNip05s() async {
    _deleteAll(['nip05']);
  }

  // =====================
  // Filter fetched ranges
  // =====================

  @override
  Future<void> saveFilterFetchedRangeRecord(FilterFetchedRangeRecord record) {
    return saveFilterFetchedRangeRecords([record]);
  }

  @override
  Future<void> saveFilterFetchedRangeRecords(
    List<FilterFetchedRangeRecord> records,
  ) async {
    _putRows(
      'filter_fetched_ranges',
      ['key', 'filter_hash', 'relay_url', 'data'],
      records.map(
        (record) => [
          record.key,
          record.filterHash,
          record.relayUrl,
          jsonEncode(record.toJson()),
        ],
      ),
    );
  }

  @override
  Future<List<FilterFetchedRangeRecord>> loadFilterFetchedRangeRecords(
    String filterHash,
  ) async {
    return _selectData(
      'SELECT data FROM filter_fetched_ranges WHERE filter_hash = ?',
      [filterHash],
    ).map(FilterFetchedRangeRecord.fromJson).toList();
  }

  @override
  Future<List<FilterFetchedRangeRecord>> loadFilterFetchedRangeRecordsByRelay(
    String filterHash,
    String relayUrl,
  ) async {
    return _selectData(
      'SELECT data FROM filter_fetched_ranges '
      'WHERE filter_hash = ? AND relay_url = ?',
      [filterHash, relayUrl],
    ).map(FilterFetchedRangeRecord.fromJson).toList();
  }

  @override
  Future<List<FilterFetchedRangeRecord>>
  loadFilterFetchedRangeRecordsByRelayUrl(String relayUrl) async {
    return _selectData(
      'SELECT data FROM filter_fetched_ranges WHERE relay_url = ?',
      [relayUrl],
    ).map(FilterFetchedRangeRecord.fromJson).toList();
  }

  @override
  Future<void> removeFilterFetchedRangeRecords(String filterHash) async {
    _db.execute('DELETE FROM filter_fetched_ranges WHERE filter_hash = ?', [
      filterHash,
    ]);
  }

  @override
  Future<void> removeFilterFetchedRangeRecordsByFilterAndRelay(
    String filterHash,
    String relayUrl,
  ) async {
    _db.execute(
      'DELETE FROM filter_fetched_ranges WHERE filter_hash = ? AND relay_url = ?',
      [filterHash, relayUrl],
    );
  }

  @override
  Future<void> removeFilterFetchedRangeRecordsByRelay(String relayUrl) async {
    _db.execute('DELETE FROM filter_fetched_ranges WHERE relay_url = ?', [
      relayUrl,
    ]);
  }

  @override
  Future<void> removeAllFilterFetchedRangeRecords() async {
    _deleteAll(['filter_fetched_ranges']);
  }

  // =====================
  // Cashu
  // =====================

  @override
  Future<void> saveKeyset(CahsuKeyset keyset) async {
    _putRows(
      'keysets',
      ['id', 'mint_url', 'data'],
      [
        [keyset.id, keyset.mintUrl, jsonEncode(keyset.toJsonForStorage())],
      ],
    );
  }

  @override
  Future<List<CahsuKeyset>> getKeysets({String? mintUrl}) async {
    final where = _Where();
    if (mintUrl != null && mintUrl.isNotEmpty) {
      where.add('mint_url = ?', [mintUrl]);
    }
    return _selectData(
      'SELECT data FROM keysets${where.sql}',
      where.parameters,
    ).map(CahsuKeysetExtension.fromJsonStorage).toList();
  }

  @override
  Future<void> saveProofs({
    required List<CashuProof> proofs,
    required String mintUrl,
  }) async {
    _putRows(
      'proofs',
      ['secret', 'keyset_id', 'state', 'amount', 'data'],
      proofs.map(
        (proof) => [
          proof.secret,
          proof.keysetId,
          proof.state.toString(),
          proof.amount,
          jsonEncode(proof.toJsonForStorage()),
        ],
      ),
    );
  }

  @override
  Future<List<CashuProof>> getProofs({
    String? mintUrl,
    String? keysetId,
    CashuProofState state = CashuProofState.unspend,
  }) async {
    final where = _Where()..add('state = ?', [state.toString()]);
    if (keysetId != null && keysetId.isNotEmpty) {
      where.add('keyset_id = ?', [keysetId]);
    }
    if (mintUrl != null && mintUrl.isNotEmpty) {
      // Without a stored keyset for the mint, proofs are returned unfiltered.
      final keysets = await getKeysets(mintUrl: mintUrl);
      if (keysets.isNotEmpty) {
        where.inList('keyset_id', keysets.map((k) => k.id).toList());
      }
    }
    return _selectData(
      'SELECT data FROM proofs${where.sql} ORDER BY amount',
      where.parameters,
    ).map(CashuProofExtension.fromJsonStorage).toList();
  }

  @override
  Future<void> removeProofs({
    required List<CashuProof> proofs,
    required String mintUrl,
  }) async {
    _deleteIn('proofs', 'secret', proofs.map((p) => p.secret).toList());
  }

  @override
  Future<void> saveMintInfo({required CashuMintInfo mintInfo}) async {
    final key = mintInfo.urls.first;
    _transaction(() {
      for (final (storedKey, existing) in _loadMintInfos()) {
        if (existing.urls.contains(key)) {
          _db.execute('DELETE FROM mint_infos WHERE key = ?', [storedKey]);
        }
      }
      _putJson(
        'mint_infos',
        key,
        mintInfo.toJsonForStorage(),
        keyColumn: 'key',
      );
    });
  }

  @override
  Future<void> removeMintInfo({required String mintUrl}) async {
    _transaction(() {
      for (final (storedKey, existing) in _loadMintInfos()) {
        if (existing.isMintUrl(mintUrl)) {
          _db.execute('DELETE FROM mint_infos WHERE key = ?', [storedKey]);
        }
      }
    });
  }

  @override
  Future<List<CashuMintInfo>?> getMintInfos({List<String>? mintUrls}) async {
    final all = _loadMintInfos().map((entry) => entry.$2).toList();
    if (mintUrls == null || mintUrls.isEmpty) return all;
    return all
        .where((mintInfo) => mintUrls.any(mintInfo.urls.contains))
        .toList();
  }

  List<(String, CashuMintInfo)> _loadMintInfos() {
    return _db
        .select('SELECT key, data FROM mint_infos')
        .map(
          (row) => (
            row['key'] as String,
            CashuMintInfoExtension.fromJsonStorage(_decode(row)),
          ),
        )
        .toList();
  }

  @override
  Future<int> getCashuSecretCounter({
    required String mintUrl,
    required String keysetId,
  }) async {
    final rows = _db.select(
      'SELECT counter FROM secret_counters WHERE mint_url = ? AND keyset_id = ?',
      [mintUrl, keysetId],
    );
    return rows.isEmpty ? 0 : rows.first['counter'] as int;
  }

  @override
  Future<void> setCashuSecretCounter({
    required String mintUrl,
    required String keysetId,
    required int counter,
  }) async {
    _putRows(
      'secret_counters',
      ['mint_url', 'keyset_id', 'counter'],
      [
        [mintUrl, keysetId, counter],
      ],
    );
  }

  @override
  Future<void> clearAll() async => _deleteAll(_tables);

  // =====================
  // SQLite helpers
  // =====================

  void _transaction(void Function() body) {
    if (!_db.autocommit) return body();
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _putRows(
    String table,
    List<String> columns,
    Iterable<List<Object?>> rows,
  ) {
    final statement = _db.prepare(
      'INSERT OR REPLACE INTO $table (${columns.join(', ')}) '
      'VALUES (${_placeholders(columns.length)})',
    );
    try {
      _transaction(() {
        for (final row in rows) {
          statement.execute(row);
        }
      });
    } finally {
      statement.close();
    }
  }

  void _putJson(
    String table,
    String key,
    Map<String, Object?> data, {
    String keyColumn = 'pubkey',
  }) {
    _putRows(
      table,
      [keyColumn, 'data'],
      [
        [key, jsonEncode(data)],
      ],
    );
  }

  List<Map<String, dynamic>> _getJson(String table, String pubKey) {
    return _selectData('SELECT data FROM $table WHERE pubkey = ?', [pubKey]);
  }

  List<Map<String, dynamic>> _selectData(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    return _db.select(sql, parameters).map(_decode).toList();
  }

  static Map<String, dynamic> _decode(Row row) {
    return (jsonDecode(row['data'] as String) as Map).cast<String, dynamic>();
  }

  void _deleteIn(String table, String column, List<Object> values) {
    if (values.isEmpty) return;
    _db.execute(
      'DELETE FROM $table WHERE $column IN (${_placeholders(values.length)})',
      values,
    );
  }

  void _deleteAll(List<String> tables) {
    _transaction(() {
      for (final table in tables) {
        _db.execute('DELETE FROM $table');
      }
    });
  }

  static String _limit(int? limit) =>
      limit != null && limit > 0 ? ' LIMIT $limit' : '';
}

String _placeholders(int count) => List.filled(count, '?').join(', ');

class _Where {
  final List<String> _clauses = [];
  final List<Object?> parameters = [];

  void add(String clause, List<Object?> values) {
    _clauses.add(clause);
    parameters.addAll(values);
  }

  void inList(String column, List<Object>? values) {
    if (values == null || values.isEmpty) return;
    add('$column IN (${_placeholders(values.length)})', values);
  }

  String get sql => _clauses.isEmpty ? '' : ' WHERE ${_clauses.join(' AND ')}';
}
