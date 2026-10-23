import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_web.dart';
import 'package:web/web.dart' as web;

int _run = 0;

void _check(bool condition, String name) {
  if (!condition) throw StateError('B0 IndexedDB check failed: $name');
}

String _payload(String revision) => const JsonEncoder.withIndent('  ').convert(
  FormDraft(
    id: 'one',
    title: 'synthetic-only',
    module: BadgeModule.sales,
    route: '/sales/orders/new',
    permission: 'sales_order:create',
    updatedAt: DateTime.utc(2026, 10),
    revision: revision,
    data: {'qty': '1.', 'unicode': '汉字😀', 'attachmentBase64': 'QUJD' * 32768},
  ).toJson(),
);

Future<web.IDBDatabase> _openRaw(
  String name,
  int version, {
  Map<String, String>? seed,
}) {
  final done = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(name, version);
  request.onupgradeneeded = ((web.Event _) {
    final database = request.result as web.IDBDatabase;
    final drafts = database.createObjectStore('drafts');
    for (final entry in seed?.entries ?? const <MapEntry<String, String>>[]) {
      drafts.put(entry.value.toJS, entry.key.toJS);
    }
  }).toJS;
  request.onsuccess = ((web.Event _) => done.complete(
    request.result as web.IDBDatabase,
  )).toJS;
  request.onerror = ((web.Event _) => done.completeError(
    StateError('B0 raw DB open failed'),
  )).toJS;
  request.onblocked = ((web.Event _) => done.completeError(
    StateError('B0 raw DB open blocked'),
  )).toJS;
  return done.future;
}

Future<String?> _readRaw(web.IDBDatabase database, String store, String key) {
  final done = Completer<String?>();
  final request = database
      .transaction(store.toJS, 'readonly')
      .objectStore(store)
      .get(key.toJS);
  request.onsuccess = ((web.Event _) => done.complete(
    request.result.isUndefinedOrNull
        ? null
        : (request.result as JSString).toDart,
  )).toJS;
  request.onerror = ((web.Event _) => done.completeError(
    StateError('B0 raw DB read failed'),
  )).toJS;
  return done.future;
}

Future<void> _legacyWrite(String name, String key, String value) async {
  final database = await _openRaw(name, 1);
  try {
    final transaction = database.transaction('drafts'.toJS, 'readwrite');
    final done = Completer<void>();
    transaction.oncomplete = ((web.Event _) => done.complete()).toJS;
    transaction.onabort = ((web.Event _) => done.completeError(
      StateError('B0 legacy write aborted'),
    )).toJS;
    transaction.objectStore('drafts').put(value.toJS, key.toJS);
    await done.future;
  } finally {
    database.close();
  }
}

Future<void> _deleteOwned(String name) {
  final done = Completer<void>();
  final request = web.window.indexedDB.deleteDatabase(name);
  request.onsuccess = ((web.Event _) => done.complete()).toJS;
  request.onerror = ((web.Event _) => done.completeError(
    StateError('B0 disposable DB cleanup failed'),
  )).toJS;
  request.onblocked = ((web.Event _) => done.completeError(
    StateError('B0 disposable DB cleanup blocked'),
  )).toJS;
  return done.future;
}

/// Real IndexedDB transactions using production storage. Only uniquely named
/// synthetic databases created by this invocation are opened/deleted.
Future<Map<String, Object?>> runB0StorageChecks() async {
  final suffix = '${DateTime.now().microsecondsSinceEpoch}-${++_run}';
  final names = [
    for (final kind in ['race', 'continuous', 'future', 'abort', 'blocked'])
      'uten-b0-$kind-$suffix',
  ];
  const prefix = 'scope_server_';
  const key = '${prefix}one';
  const historyKey = '$prefix:000000000000001';
  final stores = <BrowserFormDraftStorage>[];
  final checks = <String, Object?>{};
  final original = _payload('r1');
  final latest = _payload('late');
  try {
    (await _openRaw(names[0], 1, seed: {key: original})).close();
    var attempts = 0;
    final raced = BrowserFormDraftStorage(
      databaseName: names[0],
      beforeMigrationUpgrade: () async {
        if (++attempts == 1) await _legacyWrite(names[0], key, latest);
      },
    );
    stores.add(raced);
    final history = await raced.readHistoryPage(prefix);
    _check(
      attempts == 2 &&
          history.entries.length == 1 &&
          history.entries.single.revision == 'late',
      'v1 race retries and appends once',
    );
    _check(await raced.read(key) == latest, 'v1 race active original');
    final racedRaw = await _openRaw(names[0], 2);
    try {
      _check(
        await _readRaw(racedRaw, 'history_payload', historyKey) == latest,
        'v1 race exact history original',
      );
    } finally {
      racedRaw.close();
    }
    checks['migrationRace'] = {
      'attempts': attempts,
      'singleLatestHistory': true,
      'exactOriginal': true,
    };

    (await _openRaw(names[1], 1, seed: {key: original})).close();
    var continuousAttempts = 0;
    String newest = original;
    final continuous = BrowserFormDraftStorage(
      databaseName: names[1],
      beforeMigrationUpgrade: () {
        newest = _payload('race-${++continuousAttempts}');
        return _legacyWrite(names[1], key, newest);
      },
    );
    stores.add(continuous);
    var rejected = false;
    try {
      await continuous.readHistoryPage(prefix);
    } on StateError {
      rejected = true;
    }
    _check(rejected && continuousAttempts == 3, 'bounded migration retry');
    final oldDatabase = await _openRaw(names[1], 1);
    try {
      _check(
        !oldDatabase.objectStoreNames.contains('history_index'),
        'no partial upgraded stores',
      );
      _check(
        await _readRaw(oldDatabase, 'drafts', key) == newest,
        'continuous race original preserved',
      );
    } finally {
      oldDatabase.close();
    }
    checks['continuousRace'] = {
      'attempts': continuousAttempts,
      'remainsV1': true,
      'noPartialHistory': true,
      'exactOriginal': true,
    };

    (await _openRaw(names[2], 3, seed: {key: original})).close();
    final future = BrowserFormDraftStorage(databaseName: names[2]);
    stores.add(future);
    rejected = false;
    try {
      await future.read(key);
    } on StateError {
      rejected = true;
    }
    _check(rejected, 'future database rejected');
    final futureRaw = await _openRaw(names[2], 3);
    try {
      _check(
        !futureRaw.objectStoreNames.contains('history_index'),
        'future database unchanged schema',
      );
      _check(
        await _readRaw(futureRaw, 'drafts', key) == original,
        'future original preserved',
      );
    } finally {
      futureRaw.close();
    }
    checks['futureVersion'] = {'rejected': true, 'exactOriginal': true};

    final healthy = BrowserFormDraftStorage(databaseName: names[3]);
    stores.add(healthy);
    await healthy.write(key, original);
    final faulty = BrowserFormDraftStorage(
      databaseName: names[3],
      afterHistoryQueued: () => throw StateError('synthetic interruption'),
    );
    stores.add(faulty);
    rejected = false;
    try {
      await faulty.compareAndSet(key, expectedValue: original, value: latest);
    } on StateError {
      rejected = true;
    }
    _check(rejected, 'fault rejects transaction');
    _check(await healthy.read(key) == original, 'fault keeps active original');
    _check(
      (await healthy.readHistoryPage(prefix)).entries.length == 1,
      'fault rolls back history and sequence',
    );
    _check(
      await healthy.readHistoryRecord(prefix, '2') == null,
      'fault leaves no payload',
    );
    checks['atomicAbort'] = {
      'activeUnchanged': true,
      'historyUnchanged': true,
      'noPartialPayload': true,
    };

    (await _openRaw(names[4], 1, seed: {key: original})).close();
    web.IDBDatabase? blocker;
    final blocked = BrowserFormDraftStorage(
      databaseName: names[4],
      beforeMigrationUpgrade: () async {
        blocker = await _openRaw(names[4], 1);
      },
    );
    stores.add(blocked);
    rejected = false;
    try {
      await blocked.readHistoryPage(prefix);
    } on StateError {
      rejected = true;
    } finally {
      blocker?.close();
    }
    _check(rejected, 'blocked open reports failure');
    final afterBlocked = await _openRaw(names[4], 1);
    try {
      _check(
        !afterBlocked.objectStoreNames.contains('history_index'),
        'failed open cannot upgrade late',
      );
      _check(
        await _readRaw(afterBlocked, 'drafts', key) == original,
        'blocked original preserved',
      );
    } finally {
      afterBlocked.close();
    }
    checks['blockedRelease'] = {
      'reportedFailure': true,
      'remainsV1': true,
      'exactOriginal': true,
    };
  } finally {
    for (final store in stores) {
      await store.close();
    }
    for (final name in names) {
      await _deleteOwned(name);
    }
  }
  return {
    'passed': true,
    'platform': 'real-indexeddb',
    'payloadCharacters': original.length,
    'checks': checks,
    'cleanedDatabases': names.length,
  };
}
