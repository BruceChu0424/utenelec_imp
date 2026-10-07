import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

FormDraft _draft(
  String id, {
  String revision = 'r1',
  String permission = Perm.salesOrderCreate,
}) => FormDraft(
  id: id,
  title: 'do not index this free text',
  module: BadgeModule.sales,
  route: '/sales/orders/new',
  permission: permission,
  updatedAt: DateTime.utc(2026, 10),
  revision: revision,
  data: {
    'qty': '1.',
    'unitPrice': '123.45',
    'attachments': [
      {
        'bytes': [0, 127, 255],
      },
    ],
  },
);

String _json(String id, {String revision = 'r1'}) =>
    jsonEncode(_draft(id, revision: revision).toJson());

ProviderContainer _container(
  FormDraftStorage storage, {
  AuthenticatedScope scope = const AuthenticatedScope(userId: 'one'),
  Set<String> permissions = const {Perm.salesOrderView, Perm.salesOrderCreate},
}) => ProviderContainer(
  overrides: [
    formDraftStorageProvider.overrideWithValue(storage),
    authenticatedScopeProvider.overrideWithValue(scope),
    currentPermissionsProvider.overrideWithValue(permissions),
    apiBaseUrlProvider.overrideWithValue('https://history/api'),
  ],
);

class _DelayedHistoryStorage
    implements FormDraftStorage, FormDraftHistoryStorage {
  _DelayedHistoryStorage(this.storage);
  final NativeFormDraftStorage storage;
  final gate = Completer<void>();
  @override
  Future<FormDraftHistoryPage> readHistoryPage(
    String prefix, {
    String? before,
    int limit = 30,
  }) async {
    final page = await storage.readHistoryPage(
      prefix,
      before: before,
      limit: limit,
    );
    await gate.future;
    return page;
  }

  @override
  Future<FormDraftHistoryRecord?> readHistoryRecord(String prefix, String id) =>
      storage.readHistoryRecord(prefix, id);
  @override
  Future<Map<String, String>> readAll(String prefix) => storage.readAll(prefix);
  @override
  Future<String?> read(String key) => storage.read(key);
  @override
  Future<void> write(String key, String value) => storage.write(key, value);
  @override
  Future<void> remove(String key) => storage.remove(key);
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) => storage.compareAndSet(key, expectedValue: expectedValue, value: value);
}

void main() {
  late Directory directory;
  late NativeFormDraftStorage storage;
  const prefix = 'owner_server_';
  const key = '${prefix}one';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('uten-draft-history-');
    storage = NativeFormDraftStorage(directoryProvider: () async => directory);
  });
  tearDown(() async {
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  test('legal history-v2 draft ID cannot alias its scope lock', () async {
    const id = 'history-v2';
    const recordKey = '$prefix$id';
    await storage
        .write(recordKey, _json(id))
        .timeout(const Duration(seconds: 5));
    final page = await storage
        .readHistoryPage(prefix)
        .timeout(const Duration(seconds: 5));
    expect(page.entries.single.draftId, id);
    expect(
      await storage.read(recordKey).timeout(const Duration(seconds: 5)),
      _json(id),
    );
    expect(
      (await storage.readHistoryRecord(
        prefix,
        page.entries.single.id,
      ))!.draft.id,
      id,
    );
  });

  test(
    'business reset deletes old payloads and history and fences late writers',
    () async {
      final owner = '${'a' * 64}_';
      final other = '${'b' * 64}_';
      await storage.write('${owner}old', _json('old'));
      await storage.write('${other}keep', _json('keep'));
      final interrupted = File(
        '${directory.path}/${owner}abandoned.json.00000000-0000-0000-0000-000000000000.tmp',
      );
      await interrupted.writeAsString(_json('abandoned'));
      await storage.write(
        'daily_report_approval_${owner}pending',
        '{"pending":true}',
      );
      await storage.synchronizeBusinessReset(owner, 0);
      expect(await storage.read('${owner}old'), isNotNull);
      await storage.synchronizeBusinessReset(owner, 1);
      await expectLater(storage.read('${owner}old'), throwsStateError);
      await expectLater(
        storage.write('${owner}late', _json('late')),
        throwsStateError,
      );
      await expectLater(
        storage.synchronizeBusinessReset(owner, 0),
        throwsStateError,
      );
      expect(
        await File('${directory.path}/${owner}old.json').exists(),
        isFalse,
      );
      expect(await interrupted.exists(), isFalse);
      expect(
        await Directory('${directory.path}/history_v2/$owner').exists(),
        isFalse,
      );
      expect(
        await File(
          '${directory.path}/daily_report_approval_${owner}pending.json',
        ).exists(),
        isFalse,
      );
      expect(await storage.read('${other}keep'), isNotNull);
      final current = '${owner}g1_';
      await storage.write('${current}new', _json('new'));
      final reopened = NativeFormDraftStorage(
        directoryProvider: () async => directory,
      );
      await reopened.synchronizeBusinessReset(owner, 1);
      expect(await reopened.read('${current}new'), isNotNull);
      await reopened.synchronizeBusinessReset(owner, 2);
      await expectLater(
        storage.write('${current}late', _json('late')),
        throwsStateError,
      );
      expect(
        await Directory('${directory.path}/history_v2/$current').exists(),
        isFalse,
      );
    },
  );

  test(
    'native CAS remains pending until durable apply and lock cleanup complete',
    () async {
      final journalFlushed = Completer<void>();
      final releaseApply = Completer<void>();
      final gated = NativeFormDraftStorage(
        directoryProvider: () async => directory,
        afterJournalFlush: () async {
          journalFlushed.complete();
          await releaseApply.future;
        },
      );
      var returned = false;
      final mutation = gated
          .compareAndSet(key, expectedValue: null, value: _json('one'))
          .then((matched) {
            returned = true;
            return matched;
          });
      await journalFlushed.future;
      final history = '${directory.path}/history_v2/$prefix';
      expect(returned, isFalse);
      expect(await File('$history/pending.json').exists(), isTrue);
      expect(await File('$history/active/$key.json').exists(), isFalse);
      releaseApply.complete();
      expect(await mutation, isTrue);
      expect(returned, isTrue);
      expect(await File('$history/pending.json').exists(), isFalse);
      expect(await File('$history/head').readAsString(), '1');
      expect(await File('$history/high-water').readAsString(), '1');
      expect(
        await File('$history/active/$key.json').readAsString(),
        _json('one'),
      );
      expect(await storage.read(key), _json('one'));
      expect(
        (await storage.readHistoryRecord(prefix, '1'))!.draft.toJson(),
        jsonDecode(_json('one')),
      );
    },
  );

  test(
    'delete and complete retain exact payload and repeated removal keeps the fence',
    () async {
      final original = _json('one');
      await storage.write(key, original);
      await storage.remove(key);
      final marker = await storage.read(key);
      expect((jsonDecode(marker!) as Map)['completed'], isTrue);
      expect((jsonDecode(marker) as Map).containsKey('data'), isFalse);
      await storage.remove(key);
      expect(await storage.read(key), marker);
      expect(
        await storage.compareAndSet(key, expectedValue: null, value: original),
        isFalse,
      );
      final page = await storage.readHistoryPage(prefix);
      expect(page.entries.map((entry) => entry.action), [
        FormDraftHistoryAction.deleted,
        FormDraftHistoryAction.saved,
      ]);
      expect(
        (await storage.readHistoryRecord(
          prefix,
          page.entries.first.id,
        ))!.draft.toJson(),
        jsonDecode(original),
      );
      expect(page.entries.first.toJson().keys, isNot(contains('title')));
      expect(page.entries.first.toJson().keys, isNot(contains('data')));

      await storage.write('${prefix}two', _json('two'));
      await storage.compareAndSet(
        '${prefix}two',
        expectedValue: _json('two'),
        value: jsonEncode({
          'version': 1,
          'id': 'two',
          'completed': true,
          'historyAction': 'completed',
          'revision': 'r2',
        }),
      );
      final completed = (await storage.readHistoryPage(prefix)).entries.first;
      expect(completed.action, FormDraftHistoryAction.completed);
      expect(
        (await storage.readHistoryRecord(prefix, completed.id))!.draft.data,
        _draft('two').data,
      );
    },
  );

  test(
    'seek survives reopen and new writes without rewriting old history',
    () async {
      for (var i = 1; i <= 4; i++) {
        await storage.write('${prefix}d$i', _json('d$i'));
      }
      final oldPayload = File(
        '${directory.path}/history_v2/$prefix/payload/0/1.json',
      );
      final sentinel = DateTime.utc(2020);
      await oldPayload.setLastModified(sentinel);
      final first = await storage.readHistoryPage(prefix, limit: 2);
      expect(first.entries.map((entry) => entry.id), ['4', '3']);
      final reopened = NativeFormDraftStorage(
        directoryProvider: () async => directory,
      );
      await reopened.write('${prefix}d5', _json('d5'));
      expect(await oldPayload.lastModified(), sentinel.toLocal());
      final second = await reopened.readHistoryPage(
        prefix,
        before: first.nextCursor,
        limit: 2,
      );
      expect(second.entries.map((entry) => entry.id), ['2', '1']);
      expect(second.nextCursor, isNull);
    },
  );

  test(
    'bad index consumes a bounded slot and pages do not parse history payloads',
    () async {
      for (var i = 1; i <= 4; i++) {
        await storage.write('${prefix}d$i', _json('d$i'));
      }
      await File(
        '${directory.path}/history_v2/$prefix/index/0/2.json',
      ).writeAsString('{');
      await File(
        '${directory.path}/history_v2/$prefix/payload/0/3.json',
      ).writeAsString('{');
      final first = await storage.readHistoryPage(prefix, limit: 2);
      expect(first.entries.map((entry) => entry.id), ['4', '3']);
      expect(await storage.readHistoryRecord(prefix, '3'), isNull);
      final second = await storage.readHistoryPage(
        prefix,
        before: first.nextCursor,
        limit: 1,
      );
      expect(second.entries, isEmpty);
      expect(second.nextCursor, '2');
      final third = await storage.readHistoryPage(
        prefix,
        before: second.nextCursor,
        limit: 1,
      );
      expect(third.entries.single.id, '1');
      expect(
        await File(
          '${directory.path}/history_v2/$prefix/index/0/2.json',
        ).readAsString(),
        '{',
      );
    },
  );

  test(
    'history rejects metadata and payload policy identity mismatch',
    () async {
      await storage.write(key, _json('one'));
      final file = File('${directory.path}/history_v2/$prefix/index/0/1.json');
      final metadata =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      metadata['permission'] = 'revoked-or-forged';
      await file.writeAsString(jsonEncode(metadata));
      expect(await storage.readHistoryRecord(prefix, '1'), isNull);
    },
  );

  test(
    'WAL interruption replays once, then permits the next revision',
    () async {
      final interrupted = NativeFormDraftStorage(
        directoryProvider: () async => directory,
        afterJournalFlush: () async =>
            throw StateError('simulated interruption'),
      );
      await expectLater(interrupted.write(key, _json('one')), throwsStateError);
      expect(await storage.read(key), _json('one'));
      expect((await storage.readHistoryPage(prefix)).entries, hasLength(1));
      expect(
        await storage.compareAndSet(
          key,
          expectedValue: _json('one'),
          value: _json('one', revision: 'r2'),
        ),
        isTrue,
      );
      expect(
        (await storage.readHistoryPage(
          prefix,
        )).entries.map((entry) => entry.revision),
        ['r2', 'r1'],
      );
      expect(
        await File(
          '${directory.path}/history_v2/$prefix/pending.json',
        ).exists(),
        isFalse,
      );
    },
  );

  for (final damage in [
    'missing-head',
    'missing-controls',
    'rolled-head',
    'rolled-controls',
  ]) {
    test(
      '$damage refuses append without changing any original history bytes',
      () async {
        await storage.write(key, _json('one'));
        await storage.write('${prefix}two', _json('two'));
        final history = '${directory.path}/history_v2/$prefix';
        final originals = [
          for (final kind in ['index', 'payload'])
            for (final sequence in [1, 2])
              File('$history/$kind/0/$sequence.json'),
        ];
        final hashes = [
          for (final file in originals)
            sha256.convert(await file.readAsBytes()).toString(),
        ];
        final head = File('$history/head');
        final witness = File('$history/high-water');
        if (damage.startsWith('missing')) {
          await head.delete();
          if (damage == 'missing-controls') await witness.delete();
        } else {
          await head.writeAsString('1');
          if (damage == 'rolled-controls') await witness.writeAsString('1');
        }
        await expectLater(
          storage.write('${prefix}three', _json('three')),
          throwsStateError,
        );
        expect([
          for (final file in originals)
            sha256.convert(await file.readAsBytes()).toString(),
        ], hashes);
        expect(
          await File('$history/active/${prefix}three.json').exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'WAL replay accepts identical immutable bytes without rewriting them',
    () async {
      final interrupted = NativeFormDraftStorage(
        directoryProvider: () async => directory,
        afterJournalFlush: () async =>
            throw StateError('before applying slots'),
      );
      await expectLater(interrupted.write(key, _json('one')), throwsStateError);
      final history = '${directory.path}/history_v2/$prefix';
      final journal =
          jsonDecode(await File('$history/pending.json').readAsString())
              as Map<String, dynamic>;
      final payload = File('$history/payload/0/1.json');
      final index = File('$history/index/0/1.json');
      await payload.parent.create(recursive: true);
      await index.parent.create(recursive: true);
      await payload.writeAsString(journal['payload'] as String);
      await index.writeAsString(jsonEncode(journal['entry']));
      final sentinel = DateTime.utc(2020);
      await payload.setLastModified(sentinel);
      await index.setLastModified(sentinel);
      expect(await storage.read(key), _json('one'));
      expect(await payload.lastModified(), sentinel.toLocal());
      expect(await index.lastModified(), sentinel.toLocal());
    },
  );

  test(
    'migration interruption resumes once and late v1 IDs are imported on encounter',
    () async {
      await File('${directory.path}/$key.json').writeAsString(_json('one'));
      await File('${directory.path}/${prefix}broken.json').writeAsString('{');
      final interrupted = NativeFormDraftStorage(
        directoryProvider: () async => directory,
        afterJournalFlush: () async =>
            throw StateError('migration interruption'),
      );
      await expectLater(interrupted.readHistoryPage(prefix), throwsStateError);
      expect(
        (await storage.readHistoryPage(prefix)).entries.single.action,
        FormDraftHistoryAction.imported,
      );
      final fence =
          jsonDecode(await File('${directory.path}/$key.json').readAsString())
              as Map;
      expect(fence['completed'], isTrue);
      expect(fence['storageVersion'], 2);
      expect(
        await File('${directory.path}/${prefix}broken.json').readAsString(),
        '{',
      );
      await File(
        '${directory.path}/${prefix}late.json',
      ).writeAsString(_json('late'));
      await storage.readAll(prefix);
      expect(
        (await storage.readHistoryPage(
          prefix,
        )).entries.map((entry) => entry.draftId),
        ['late', 'one'],
      );
      await storage.readAll(prefix);
      expect((await storage.readHistoryPage(prefix)).entries, hasLength(2));
    },
  );

  test(
    'v1 writer during an interrupted commit is preserved and fenced on reopen',
    () async {
      final interrupted = NativeFormDraftStorage(
        directoryProvider: () async => directory,
        afterJournalFlush: () async => throw StateError('before source fence'),
      );
      await expectLater(interrupted.write(key, _json('one')), throwsStateError);
      await File(
        '${directory.path}/$key.json',
      ).writeAsString(_json('one', revision: 'legacy-late'));
      expect(await storage.read(key), _json('one', revision: 'legacy-late'));
      expect(
        (await storage.readHistoryPage(
          prefix,
        )).entries.map((entry) => entry.revision),
        ['legacy-late', 'r1'],
      );
    },
  );

  test(
    'two writers have one CAS winner and history remains scope isolated',
    () async {
      await storage.write(key, _json('one'));
      final second = NativeFormDraftStorage(
        directoryProvider: () async => directory,
      );
      final results = await Future.wait([
        storage.compareAndSet(
          key,
          expectedValue: _json('one'),
          value: _json('one', revision: 'a'),
        ),
        second.compareAndSet(
          key,
          expectedValue: _json('one'),
          value: _json('one', revision: 'b'),
        ),
      ]);
      expect(results.where((result) => result), hasLength(1));
      expect((await storage.readHistoryPage(prefix)).entries, hasLength(2));
      expect(
        (await storage.readHistoryPage('different_server_')).entries,
        isEmpty,
      );
      expect(await storage.readHistoryRecord('different_server_', '1'), isNull);
      expect(
        () => storage.readHistoryPage('../escape_'),
        throwsFormatException,
      );
    },
  );

  test(
    'readonly and revoked-create users can read authorized history but cannot mutate',
    () async {
      final writer = _container(storage);
      addTearDown(writer.dispose);
      final notifier = writer.read(formDraftsProvider.notifier);
      await notifier.ready;
      final saved = await notifier.save(_draft('one'));
      await notifier.delete(saved.id, expectedRevision: saved.revision);
      final reader = _container(
        storage,
        scope: const AuthenticatedScope(userId: 'one', readOnly: true),
        permissions: {Perm.salesOrderView},
      );
      addTearDown(reader.dispose);
      final readonly = reader.read(formDraftsProvider.notifier);
      await readonly.ready;
      final page = await readonly.historyPage();
      expect(page.entries, hasLength(2));
      expect(await readonly.readHistory(page.entries.first.id), isNotNull);
      expect(reader.read(formDraftsProvider), isEmpty);
      await expectLater(readonly.save(_draft('other')), throwsStateError);
      await expectLater(readonly.delete('one'), throwsStateError);
      await expectLater(readonly.complete('one'), throwsStateError);
      final revoked = _container(storage, permissions: {});
      addTearDown(revoked.dispose);
      final denied = revoked.read(formDraftsProvider.notifier);
      await denied.ready;
      final deniedPage = await denied.historyPage(limit: 1);
      expect(deniedPage.entries, isEmpty);
      expect(deniedPage.nextCursor, isNotNull);
      expect(await denied.readHistory(page.entries.first.id), isNull);
    },
  );

  test(
    'forged empty historical permission cannot obtain current authorization',
    () async {
      final owner = formDraftStoragePrefix(
        'https://history/api',
        const AuthenticatedScope(userId: 'one'),
      );
      await storage.write(
        '${owner}forged',
        jsonEncode(_draft('forged', permission: '').toJson()),
      );
      final reader = _container(storage);
      addTearDown(reader.dispose);
      final notifier = reader.read(formDraftsProvider.notifier);
      await notifier.ready;
      expect(reader.read(formDraftsProvider), isEmpty);
      expect((await notifier.historyPage()).entries, isEmpty);
      expect(await notifier.readHistory('1'), isNull);
    },
  );

  test(
    'disposed readonly scope cannot deliver an in-flight history page',
    () async {
      final owner = formDraftStoragePrefix(
        'https://history/api',
        const AuthenticatedScope(userId: 'one'),
      );
      await storage.write('${owner}one', _json('one'));
      final delayed = _DelayedHistoryStorage(storage);
      final reader = _container(
        delayed,
        scope: const AuthenticatedScope(userId: 'one', readOnly: true),
      );
      final notifier = reader.read(formDraftsProvider.notifier);
      final reading = notifier.historyPage();
      final assertion = expectLater(reading, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      reader.dispose();
      delayed.gate.complete();
      await assertion;
    },
  );
}
