import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class MemoryDraftStorage implements FormDraftStorage {
  final records = <String, String>{};
  Completer<void>? beforeCompare;
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    await beforeCompare?.future;
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

const _scope = AuthenticatedScope(userId: 'user-1');
const _perms = {Perm.salesOrderCreate, Perm.salesOrderView};

FormDraft _draft(
  String id, {
  String note = 'unfinished',
  Map<String, dynamic>? data,
  String? route,
}) => FormDraft(
  id: id,
  title: '销售订货单',
  module: BadgeModule.sales,
  route: route ?? '/sales/orders/new',
  permission: Perm.salesOrderCreate,
  updatedAt: DateTime.utc(2026, 9, 26),
  data: data ?? {'note': note},
);

ProviderContainer _container(
  FormDraftStorage storage, {
  AuthenticatedScope? scope = _scope,
  Set<String> permissions = _perms,
  String server = 'https://server-one/api',
}) => ProviderContainer(
  overrides: [
    formDraftStorageProvider.overrideWithValue(storage),
    authenticatedScopeProvider.overrideWithValue(scope),
    currentPermissionsProvider.overrideWithValue(permissions),
    apiBaseUrlProvider.overrideWithValue(server),
  ],
);

void main() {
  test('known outcomes and partial unsent remainder remain deletable', () {
    final route = RouteName.productionFqcSheetHandling('s');
    for (final state in ['notSent', 'rejected', 'confirmed']) {
      expect(
        hasUnknownFormDraftSubmission({
          '_formDraftSubmissionPending': true,
          'rows': [
            {'inspectionId': 'i', 'submissionState': state},
          ],
        }, route: route),
        isFalse,
      );
    }
    expect(
      hasUnknownFormDraftSubmission({
        '_formDraftSubmissionPending': true,
        'rows': [
          {
            'inspectionId': 'done',
            'completed': true,
            'submission': {'decision': 'PASS'},
          },
          {'inspectionId': 'remaining', 'submissionState': 'notSent'},
        ],
      }, route: route),
      isFalse,
    );
    expect(
      hasUnknownFormDraftSubmission({
        'createdOrders': ['one'],
        '_formDraftSubmissionPending': true,
      }, route: '/sales/orders/new'),
      isTrue,
    );
    expect(
      hasUnknownFormDraftSubmission({
        'createdDocId': 'one',
        '_formDraftSubmissionPending': true,
      }, route: '/sales/orders/new'),
      isFalse,
    );
  });
  test(
    'CAS local deletion prevents stale tab persisting a pending command',
    () async {
      final storage = MemoryDraftStorage();
      final first = _container(storage);
      final second = _container(storage);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final a = first.read(formDraftsProvider.notifier);
      await a.ready;
      final saved = await a.save(_draft('race'));
      final b = second.read(formDraftsProvider.notifier);
      await b.ready;
      await a.delete(saved.id, expectedRevision: saved.revision);
      await expectLater(
        b.save(
          _draft('race', data: {'_formDraftSubmissionPending': true}),
          expectedRevision: saved.revision,
        ),
        throwsA(isA<FormDraftConflict>()),
      );
      final retained = jsonDecode(storage.records.values.single) as Map;
      expect(retained['completed'], isTrue);
      expect(retained['historyAction'], 'deleted');
      expect(retained['data'], saved.data);
    },
  );
  final pendingPayloads = <String, Map<String, dynamic>>{
    'unified': {
      '_formDraftHasUnknownSubmission': true,
      'commandKey': 'same-key',
    },
    'legacy generic': {
      '_formDraftSubmissionPending': true,
      'commandKey': 'same-key',
    },
    'legacy batch': {
      'uncertain': true,
      'requestKey': 'same-key',
      'submittedDocIds': ['doc'],
    },
    'contradictory batch': {
      '_formDraftHasUnknownSubmission': false,
      'uncertain': true,
      'requestKey': 'same-key',
      'confirmedResult': {
        'issuedCount': 1,
        'skippedCount': 0,
        'replayedCount': 0,
      },
    },
    'contradictory fqc single': {
      '_formDraftHasUnknownSubmission': false,
      'row': {
        'inspectionId': 'i',
        'idempotencyKey': 'same-key',
        'completed': true,
        'submissionState': 'unknown',
        'submission': {'decision': 'PASS'},
      },
    },
    'legacy fqc single': {
      'row': {
        'inspectionId': 'i',
        'idempotencyKey': 'same-key',
        'completed': false,
        'submission': {'decision': 'PASS'},
      },
    },
    'legacy fqc sheet': {
      'rows': [
        {
          'inspectionId': 'i',
          'idempotencyKey': 'same-key',
          'submissionState': 'unknown',
          'submission': {'decision': 'PASS'},
        },
      ],
    },
  };
  for (final entry in pendingPayloads.entries) {
    test(
      'unknown deletion refuses ${entry.key} but confirmed completion remains available',
      () async {
        final storage = MemoryDraftStorage();
        final container = _container(
          storage,
          permissions: {
            ..._perms,
            Perm.stockDocView,
            Perm.stockDocIssue,
            Perm.productionQualityInspectionView,
            Perm.productionQualityInspectionApprove,
          },
        );
        addTearDown(container.dispose);
        final store = container.read(formDraftsProvider.notifier);
        await store.ready;
        final route = entry.key.contains('batch')
            ? RouteName.warehouseProductionDrawBatchIssue
            : entry.key.contains('fqc single')
            ? RouteName.productionFqcInspectionHandling('i')
            : entry.key == 'legacy fqc sheet'
            ? RouteName.productionFqcSheetHandling('s')
            : null;
        final saved = await store.save(
          _draft('unknown', data: entry.value, route: route),
        );
        await expectLater(
          store.delete(saved.id, expectedRevision: saved.revision),
          throwsA(predicate((error) => error.toString().contains('先核对提交'))),
        );
        expect(container.read(formDraftsProvider).single.data, entry.value);
        await store.complete(saved.id, expectedRevision: saved.revision);
        expect(container.read(formDraftsProvider), isEmpty);
        expect(
          (jsonDecode(storage.records.values.single) as Map)['completed'],
          isTrue,
        );
      },
    );
  }
  test(
    'unknown deletion checks persisted content rather than cached eligibility',
    () async {
      final storage = MemoryDraftStorage();
      final first = _container(storage);
      final second = _container(storage);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final a = first.read(formDraftsProvider.notifier);
      await a.ready;
      final original = await a.save(_draft('race'));
      final b = second.read(formDraftsProvider.notifier);
      await b.ready;
      final latest = await b.save(
        _draft(
          'race',
          data: {'_formDraftSubmissionPending': true, 'key': 'frozen'},
        ),
        expectedRevision: original.revision,
      );
      expect(
        first
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isNull,
      );
      await expectLater(
        a.delete(latest.id, expectedRevision: latest.revision),
        throwsA(predicate((error) => error.toString().contains('先核对提交'))),
      );
      expect(
        ((jsonDecode(storage.records.values.single) as Map)['data']
            as Map)['key'],
        'frozen',
      );
    },
  );
  test(
    'durable scope survives login epoch but separates user server actor',
    () {
      final key = formDraftStoragePrefix('one', _scope);
      expect(
        formDraftStoragePrefix(
          'one',
          const AuthenticatedScope(userId: 'user-1', epoch: 8),
        ),
        key,
      );
      expect(formDraftStoragePrefix('two', _scope), isNot(key));
      expect(
        formDraftStoragePrefix(
          'one',
          const AuthenticatedScope(userId: 'user-2'),
        ),
        isNot(key),
      );
      expect(
        formDraftStoragePrefix(
          'one',
          const AuthenticatedScope(userId: 'user-1', actorId: 'admin'),
        ),
        isNot(key),
      );
    },
  );

  test('two tabs updating same revision have exactly one winner', () async {
    final storage = MemoryDraftStorage();
    final first = _container(storage);
    final second = _container(storage);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final a = first.read(formDraftsProvider.notifier);
    await a.ready;
    final initial = await a.save(_draft('draft-1'));
    final b = second.read(formDraftsProvider.notifier);
    await b.ready;
    storage.beforeCompare = Completer<void>();
    Future<Object> attempt(FormDraftsNotifier store, String note) async {
      try {
        return await store.save(
          _draft('draft-1', note: note),
          expectedRevision: initial.revision,
        );
      } catch (error) {
        return error;
      }
    }

    final racing = [attempt(a, 'first tab'), attempt(b, 'second tab')];
    await Future<void>.delayed(Duration.zero);
    storage.beforeCompare!.complete();
    final results = await Future.wait(racing);
    expect(results.whereType<FormDraft>(), hasLength(1));
    expect(results.whereType<FormDraftConflict>(), hasLength(1));
    final winner = results.whereType<FormDraft>().single;
    expect(
      FormDraft.fromJson(
        jsonDecode(storage.records.values.single) as Map<String, dynamic>,
      ).revision,
      winner.revision,
    );
  });

  test(
    'stale delete and completion preserve another tab newer draft',
    () async {
      final storage = MemoryDraftStorage();
      final first = _container(storage);
      final second = _container(storage);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final a = first.read(formDraftsProvider.notifier);
      await a.ready;
      final initial = await a.save(_draft('draft-1'));
      final b = second.read(formDraftsProvider.notifier);
      await b.ready;
      final latest = await b.save(
        _draft('draft-1', note: 'new work'),
        expectedRevision: initial.revision,
      );
      await expectLater(
        a.delete('draft-1', expectedRevision: initial.revision),
        throwsA(isA<FormDraftConflict>()),
      );
      await expectLater(
        a.complete('draft-1', expectedRevision: initial.revision),
        throwsA(isA<FormDraftConflict>()),
      );
      expect(
        (jsonDecode(storage.records.values.single)
            as Map<String, dynamic>)['revision'],
        latest.revision,
      );
    },
  );

  test(
    'completion retains payload, survives restart, rejects stale resurrection',
    () async {
      final storage = MemoryDraftStorage();
      final first = _container(storage);
      addTearDown(first.dispose);
      final a = first.read(formDraftsProvider.notifier);
      await a.ready;
      final initial = await a.save(_draft('draft-1'));
      await a.complete('draft-1', expectedRevision: initial.revision);
      expect(first.read(formDraftsProvider), isEmpty);
      final marker = jsonDecode(storage.records.values.single) as Map;
      expect(marker['completed'], isTrue);
      expect(marker['data'], initial.data);
      await expectLater(
        a.save(_draft('draft-1'), expectedRevision: initial.revision),
        throwsA(isA<FormDraftConflict>()),
      );
      await expectLater(
        a.save(_draft('draft-1')),
        throwsA(isA<FormDraftConflict>()),
      );
      final restarted = _container(storage);
      addTearDown(restarted.dispose);
      await restarted.read(formDraftsProvider.notifier).ready;
      expect(restarted.read(formDraftsProvider), isEmpty);
      await restarted.read(formDraftsProvider.notifier).complete('draft-1');
    },
  );

  test(
    'logout readonly revoked permission and other server cannot see draft',
    () async {
      final storage = MemoryDraftStorage();
      final writer = _container(storage);
      addTearDown(writer.dispose);
      final store = writer.read(formDraftsProvider.notifier);
      await store.ready;
      await store.save(_draft('draft-1'));
      for (final container in [
        _container(storage, scope: null),
        _container(storage, permissions: {}),
        _container(storage, server: 'https://other/api'),
        _container(storage, scope: const AuthenticatedScope(userId: 'user-2')),
        _container(
          storage,
          scope: const AuthenticatedScope(
            userId: 'user-1',
            actorId: 'admin',
            readOnly: true,
          ),
        ),
      ]) {
        addTearDown(container.dispose);
        await container.read(formDraftsProvider.notifier).ready;
        expect(container.read(formDraftsProvider), isEmpty);
      }
    },
  );

  test('corrupt record does not hide healthy local draft', () async {
    final storage = MemoryDraftStorage();
    final prefix = formDraftStoragePrefix('https://server-one/api', _scope);
    storage.records['${prefix}broken'] = '{';
    storage.records['${prefix}okay'] = jsonEncode(_draft('okay').toJson());
    final container = _container(storage);
    addTearDown(container.dispose);
    await container.read(formDraftsProvider.notifier).ready;
    expect(container.read(formDraftsProvider).single.id, 'okay');
    expect(storage.records['${prefix}broken'], '{');
  });

  test(
    'native store atomically compares across instances and rejects paths',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'uten-form-drafts-',
      );
      addTearDown(() async {
        final path = directory.absolute.path;
        expect(path.startsWith(Directory.systemTemp.absolute.path), isTrue);
        await directory.delete(recursive: true);
      });
      final a = NativeFormDraftStorage(
        directoryProvider: () async => directory,
      );
      final b = NativeFormDraftStorage(
        directoryProvider: () async => directory,
      );
      await a.write('key-1', 'original');
      final results = await Future.wait([
        a.compareAndSet('key-1', expectedValue: 'original', value: 'first'),
        b.compareAndSet('key-1', expectedValue: 'original', value: 'second'),
      ]);
      expect(results.where((matched) => matched), hasLength(1));
      final saved = await a.read('key-1');
      expect(saved, anyOf('first', 'second'));
      expect(
        await a.compareAndSet('key-1', expectedValue: 'original', value: null),
        isFalse,
      );
      expect(await b.readAll('key'), {'key-1': saved});
      expect(
        await a.compareAndSet('key-1', expectedValue: saved, value: null),
        isTrue,
      );
      expect(await b.read('key-1'), isNull);
      await expectLater(a.write('../outside', 'bad'), throwsFormatException);
      expect(await File('${directory.path}/key-1.json.lock').exists(), isTrue);
    },
  );
}
