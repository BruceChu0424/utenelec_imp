@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_web.dart';
import 'package:web/web.dart' as web;

String _payload(String id, {String revision = 'r1'}) => jsonEncode(
  FormDraft(
    id: id,
    title: 'private title',
    module: BadgeModule.sales,
    route: '/sales/orders/new',
    permission: Perm.salesOrderCreate,
    updatedAt: DateTime.utc(2026, 10),
    revision: revision,
    data: {
      'quantity': '1.',
      'price': '234.56',
      'attachments': [
        {
          'bytes': [0, 255],
        },
      ],
    },
  ).toJson(),
);

Future<web.IDBDatabase> _open(
  String name,
  int version, {
  Map<String, String>? seed,
}) {
  final result = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(name, version);
  request.onupgradeneeded = ((web.Event event) {
    final database = request.result as web.IDBDatabase;
    final store = database.createObjectStore('drafts');
    for (final entry in seed?.entries ?? <MapEntry<String, String>>[]) {
      store.put(entry.value.toJS, entry.key.toJS);
    }
  }).toJS;
  request.onsuccess = ((web.Event event) => result.complete(
    request.result as web.IDBDatabase,
  )).toJS;
  request.onerror = ((web.Event event) => result.completeError(
    StateError('version rejected'),
  )).toJS;
  return result.future;
}

Future<void> _legacyWrite(String name, String key, String value) async {
  final database = await _open(name, 1);
  try {
    final transaction = database.transaction('drafts'.toJS, 'readwrite');
    final done = Completer<void>();
    transaction.oncomplete = ((web.Event _) => done.complete()).toJS;
    transaction.onabort = ((web.Event _) => done.completeError(
      StateError('legacy write aborted'),
    )).toJS;
    transaction.objectStore('drafts').put(value.toJS, key.toJS);
    await done.future;
  } finally {
    database.close();
  }
}

Future<String?> _rawHistory(String name, String key) async {
  final database = await _open(name, 2);
  try {
    final done = Completer<String?>();
    final request = database
        .transaction('history_payload'.toJS, 'readonly')
        .objectStore('history_payload')
        .get(key.toJS);
    request.onsuccess = ((web.Event _) => done.complete(
      request.result.isUndefinedOrNull
          ? null
          : (request.result as JSString).toDart,
    )).toJS;
    request.onerror = ((web.Event _) => done.completeError(
      StateError('raw history read failed'),
    )).toJS;
    return await done.future;
  } finally {
    database.close();
  }
}

void main() {
  late String databaseName;
  late List<BrowserFormDraftStorage> stores;
  const prefix = 'scope_server_';
  setUp(() {
    databaseName = 'uten-history-test-${DateTime.now().microsecondsSinceEpoch}';
    stores = [];
  });
  BrowserFormDraftStorage open({void Function()? fail}) {
    final store = BrowserFormDraftStorage(
      databaseName: databaseName,
      afterHistoryQueued: fail,
    );
    stores.add(store);
    return store;
  }

  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    final done = Completer<void>();
    final request = web.window.indexedDB.deleteDatabase(databaseName);
    request.onsuccess = ((web.Event event) => done.complete()).toJS;
    request.onerror = ((web.Event event) => done.completeError(
      StateError('test cleanup failed'),
    )).toJS;
    await done.future;
  });

  test(
    'large original CAS has one winner and history retains exact UTF-8/JSON text',
    () async {
      final body = jsonDecode(_payload('one')) as Map<String, dynamic>;
      (body['data'] as Map)['base64'] = 'QUJD' * (10 * 1024 * 1024 ~/ 4);
      final original = const JsonEncoder.withIndent('  ').convert(body);
      final first = open();
      final second = open();
      await first.write('${prefix}one', original);
      final a = jsonEncode({...body, 'revision': 'a'});
      final b = jsonEncode({...body, 'revision': 'b'});
      final results = await Future.wait([
        first.compareAndSet('${prefix}one', expectedValue: original, value: a),
        second.compareAndSet('${prefix}one', expectedValue: original, value: b),
      ]);
      expect(results.where((value) => value), hasLength(1));
      expect(await first.read('${prefix}one'), results.first ? a : b);
      expect((await first.readHistoryPage(prefix)).entries, hasLength(2));
      expect(
        await _rawHistory(databaseName, '$prefix:000000000000001'),
        original,
      );
      expect(
        (await first.readHistoryRecord(prefix, '1'))!.draft.data['base64'],
        (body['data'] as Map)['base64'],
      );
    },
  );

  test(
    'v1 writer racing async preparation aborts upgrade then imports only the latest original',
    () async {
      const key = '${prefix}one';
      final firstRaw = _payload('one');
      final latest = _payload('one', revision: 'late');
      (await _open(databaseName, 1, seed: {key: firstRaw})).close();
      var preparations = 0;
      final storage = BrowserFormDraftStorage(
        databaseName: databaseName,
        beforeMigrationUpgrade: () async {
          if (++preparations == 1) {
            await _legacyWrite(databaseName, key, latest);
          }
        },
      );
      stores.add(storage);
      expect(
        (await storage.readHistoryPage(prefix)).entries.single.revision,
        'late',
      );
      expect(preparations, 2);
      expect(await storage.read(key), latest);
      expect(
        await _rawHistory(databaseName, '$prefix:000000000000001'),
        latest,
      );
    },
  );

  test(
    'persistent v1 mutation exhausts bounded retries without committing a partial upgrade',
    () async {
      const key = '${prefix}one';
      (await _open(databaseName, 1, seed: {key: _payload('one')})).close();
      var preparations = 0;
      final storage = BrowserFormDraftStorage(
        databaseName: databaseName,
        beforeMigrationUpgrade: () => _legacyWrite(
          databaseName,
          key,
          _payload('one', revision: 'race-${++preparations}'),
        ),
      );
      stores.add(storage);
      await expectLater(storage.readHistoryPage(prefix), throwsStateError);
      expect(preparations, 3);
      final legacy = await _open(databaseName, 1);
      try {
        expect(legacy.objectStoreNames.contains('history_index'), isFalse);
        final done = Completer<String>();
        final request = legacy
            .transaction('drafts'.toJS, 'readonly')
            .objectStore('drafts')
            .get(key.toJS);
        request.onsuccess = ((web.Event _) => done.complete(
          (request.result as JSString).toDart,
        )).toJS;
        expect(await done.future, _payload('one', revision: 'race-3'));
      } finally {
        legacy.close();
      }
    },
  );

  test(
    'a blocked upgrade cannot write later after its open already failed',
    () async {
      const key = '${prefix}one';
      final original = _payload('one');
      (await _open(databaseName, 1, seed: {key: original})).close();
      web.IDBDatabase? blocker;
      final storage = BrowserFormDraftStorage(
        databaseName: databaseName,
        beforeMigrationUpgrade: () async {
          blocker = await _open(databaseName, 1);
        },
      );
      stores.add(storage);
      try {
        await expectLater(storage.readHistoryPage(prefix), throwsStateError);
      } finally {
        blocker?.close();
      }
      // This version-1 open is queued after the formerly blocked request. If
      // that request writes late, this open fails with a version error.
      final legacy = await _open(databaseName, 1);
      try {
        expect(legacy.objectStoreNames.contains('history_index'), isFalse);
        final done = Completer<String>();
        final request = legacy
            .transaction('drafts'.toJS, 'readonly')
            .objectStore('drafts')
            .get(key.toJS);
        request.onsuccess = ((web.Event _) => done.complete(
          (request.result as JSString).toDart,
        )).toJS;
        expect(await done.future, original);
      } finally {
        legacy.close();
      }
    },
  );

  test(
    'business reset atomically purges old drafts and history across connections',
    () async {
      final owner = '${'a' * 64}_';
      final other = '${'b' * 64}_';
      final old = open();
      final current = open();
      await old.write('${owner}one', _payload('one'));
      await old.write('${other}keep', _payload('keep'));
      await old.write(
        'daily_report_approval_${owner}pending',
        '{"pending":true}',
      );
      await current.synchronizeBusinessReset(owner, 1);
      expect(await old.read('${owner}one'), isNull);
      expect((await old.readHistoryPage(owner)).entries, isEmpty);
      expect(await old.readHistoryRecord(owner, '1'), isNull);
      expect(await old.read('daily_report_approval_${owner}pending'), isNull);
      await expectLater(
        old.write('${owner}late', _payload('late')),
        throwsStateError,
      );
      await expectLater(
        old.synchronizeBusinessReset(owner, 0),
        throwsStateError,
      );
      expect(await current.read('${other}keep'), isNotNull);
      await current.write('${owner}g1_new', _payload('new'));
      await current.synchronizeBusinessReset(owner, 1);
      expect(await current.read('${owner}g1_new'), isNotNull);
      await current.synchronizeBusinessReset(owner, 2);
      expect(await current.read('${owner}g1_new'), isNull);
    },
  );

  test(
    'a future database version stays closed and its original draft is preserved',
    () async {
      (await _open(
        databaseName,
        3,
        seed: {'${prefix}one': _payload('one')},
      )).close();
      await expectLater(open().read('${prefix}one'), throwsStateError);
      final future = await _open(databaseName, 3);
      try {
        expect(future.objectStoreNames.contains('history_index'), isFalse);
        final done = Completer<String>();
        final request = future
            .transaction('drafts'.toJS, 'readonly')
            .objectStore('drafts')
            .get('${prefix}one'.toJS);
        request.onsuccess = ((web.Event _) => done.complete(
          (request.result as JSString).toDart,
        )).toJS;
        expect(await done.future, _payload('one'));
      } finally {
        future.close();
      }
    },
  );

  test(
    'v1 migration is atomic and idempotent, damaged sources survive, old writer is fenced',
    () async {
      final legacy = await _open(
        databaseName,
        1,
        seed: {
          '${prefix}one': _payload('one'),
          '${prefix}bad': '{',
          '${prefix}future': '{"version":99,"data":{"private":"original"}}',
        },
      );
      legacy.close();
      final first = open();
      final migrated = await first.readHistoryPage(prefix);
      expect(migrated.entries.single.action, FormDraftHistoryAction.imported);
      expect(
        (await first.readHistoryRecord(prefix, '1'))!.draft.toJson(),
        jsonDecode(_payload('one')),
      );
      expect(await first.read('${prefix}bad'), '{');
      expect(
        await first.read('${prefix}future'),
        '{"version":99,"data":{"private":"original"}}',
      );
      await first.close();
      final second = open();
      expect((await second.readHistoryPage(prefix)).entries, hasLength(1));
      await expectLater(_open(databaseName, 1), throwsStateError);
      expect(
        (await second.readHistoryPage('another_server_')).entries,
        isEmpty,
      );
      expect((await second.readHistoryPage('scope_')).entries, isEmpty);
    },
  );

  test(
    'an abort rolls back draft, payload, index and sequence together',
    () async {
      final first = open();
      await first.write('${prefix}one', _payload('one'));
      final interrupted = open(
        fail: () => throw StateError('abort after queued history writes'),
      );
      await expectLater(
        interrupted.compareAndSet(
          '${prefix}one',
          expectedValue: _payload('one'),
          value: _payload('one', revision: 'failed'),
        ),
        throwsStateError,
      );
      await interrupted.close();
      expect(await first.read('${prefix}one'), _payload('one'));
      expect((await first.readHistoryPage(prefix)).entries, hasLength(1));
      expect(await first.readHistoryRecord(prefix, '2'), isNull);
      expect(
        await first.compareAndSet(
          '${prefix}one',
          expectedValue: _payload('one'),
          value: _payload('one', revision: 'success'),
        ),
        isTrue,
      );
      expect(
        (await first.readHistoryPage(prefix)).entries.map((entry) => entry.id),
        ['2', '1'],
      );
    },
  );

  for (final damage in ['missing-head', 'rolled-back-with-hole']) {
    test(
      '$damage refuses append and preserves later immutable payloads',
      () async {
        final storage = open();
        for (var i = 1; i <= 3; i++) {
          await storage.write('${prefix}d$i', _payload('d$i'));
        }
        final database = await _open(databaseName, 2);
        final transaction = database.transaction(
          [
            'history_head'.toJS,
            'history_index'.toJS,
            'history_payload'.toJS,
          ].toJS,
          'readwrite',
        );
        final done = Completer<void>();
        transaction.oncomplete = ((web.Event event) => done.complete()).toJS;
        transaction.onabort = ((web.Event event) => done.completeError(
          StateError('fixture write failed'),
        )).toJS;
        final head = transaction.objectStore('history_head');
        final missingSlot = damage == 'missing-head' ? 1 : 2;
        if (damage == 'missing-head') {
          head.delete(prefix.toJS);
        } else {
          head.put('1'.toJS, prefix.toJS);
        }
        // Leave a hole at the candidate append key. A duplicate-only check would
        // miss the later original and commit a lower head, hiding its history.
        final slotKey =
            '$prefix:${missingSlot.toString().padLeft(15, '0')}'.toJS;
        transaction.objectStore('history_index').delete(slotKey);
        transaction.objectStore('history_payload').delete(slotKey);
        await done.future;
        database.close();
        await expectLater(
          storage.write('${prefix}new', _payload('new')),
          throwsStateError,
        );
        expect(await storage.read('${prefix}new'), isNull);
        expect(
          (await storage.readHistoryRecord(prefix, '3'))!.draft.toJson(),
          jsonDecode(_payload('d3')),
        );
        expect((await storage.readHistoryPage(prefix)).entries.first.id, '3');
      },
    );
  }

  test(
    'seek and exact payload survive reopen and concurrent mutations; terminal stays permanent',
    () async {
      final first = open();
      for (var i = 1; i <= 4; i++) {
        await first.write('${prefix}d$i', _payload('d$i'));
      }
      final page = await first.readHistoryPage(prefix, limit: 2);
      expect(page.entries.map((entry) => entry.id), ['4', '3']);
      await first.close();
      final second = open();
      await second.write('${prefix}d5', _payload('d5'));
      final next = await second.readHistoryPage(
        prefix,
        before: page.nextCursor,
        limit: 2,
      );
      expect(next.entries.map((entry) => entry.id), ['2', '1']);
      final race = await Future.wait([
        first.compareAndSet(
          '${prefix}d5',
          expectedValue: _payload('d5'),
          value: _payload('d5', revision: 'a'),
        ),
        second.compareAndSet(
          '${prefix}d5',
          expectedValue: _payload('d5'),
          value: _payload('d5', revision: 'b'),
        ),
      ]);
      expect(race.where((won) => won), hasLength(1));
      expect((await second.readHistoryPage(prefix)).entries, hasLength(6));
      final beforeDelete = await second.read('${prefix}d5');
      await second.remove('${prefix}d5');
      final marker = await second.read('${prefix}d5');
      await second.remove('${prefix}d5');
      expect(await second.read('${prefix}d5'), marker);
      expect(
        await second.compareAndSet(
          '${prefix}d5',
          expectedValue: null,
          value: _payload('d5'),
        ),
        isFalse,
      );
      final archived = (await second.readHistoryPage(prefix)).entries.first;
      expect(archived.action, FormDraftHistoryAction.deleted);
      expect(
        (await second.readHistoryRecord(prefix, archived.id))!.draft.toJson(),
        jsonDecode(beforeDelete!),
      );
      expect(archived.toJson().keys, isNot(contains('data')));
      expect(archived.toJson().keys, isNot(contains('title')));
    },
  );
}
