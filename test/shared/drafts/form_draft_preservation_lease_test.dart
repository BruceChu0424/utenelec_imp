@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _owner = AuthenticatedScope(
  userId: 'original-user',
  businessDatasetId: 'original-dataset',
);
const _server = 'https://original.example/api';
const _spec = FormDraftSpec(
  title: '销售订货单',
  module: BadgeModule.sales,
  route: '/sales/orders/new',
  permission: Perm.salesOrderCreate,
);

class _Storage implements FormDraftStorage {
  final values = <String, String>{};
  void Function()? afterCommit;
  bool fail = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in values.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (fail) throw StateError('local storage unavailable');
    if (values[key] != expectedValue) return false;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    final callback = afterCommit;
    afterCommit = null;
    callback?.call();
    return true;
  }
}

FormDraft _draft(String id, Map<String, dynamic> data) => FormDraft(
  id: id,
  title: _spec.title,
  module: _spec.module,
  route: _spec.route,
  permission: _spec.permission,
  updatedAt: DateTime.now(),
  data: data,
);

ProviderContainer _container(
  FormDraftStorage storage, {
  AuthenticatedScope? owner = _owner,
  String server = _server,
}) => ProviderContainer(
  overrides: [
    formDraftStorageProvider.overrideWithValue(storage),
    authenticatedScopeProvider.overrideWithValue(owner),
    apiBaseUrlProvider.overrideWithValue(server),
    currentPermissionsProvider.overrideWithValue({
      Perm.salesOrderCreate,
      Perm.salesOrderView,
    }),
  ],
);

void main() {
  setUp(() => webUpdateSafety.setReady(true));
  tearDown(() => webUpdateSafety.setReady(false));

  for (final boundary in ['logout', 'account', 'issuer', 'dataset']) {
    test(
      'retired lease saves only original namespace after $boundary',
      () async {
        final storage = _Storage();
        final original = _container(storage);
        final store = original.read(formDraftsProvider.notifier);
        await store.ready;
        final lease = store.capturePreservationLease(
          draftId: 'one',
          spec: _spec,
          route: _spec.route,
        )!;
        original.dispose();
        final next = _container(
          storage,
          owner: boundary == 'logout'
              ? null
              : AuthenticatedScope(
                  userId: boundary == 'account' ? 'next-user' : _owner.userId,
                  businessDatasetId: boundary == 'dataset'
                      ? 'next-dataset'
                      : _owner.businessDatasetId,
                ),
          server: boundary == 'issuer' ? 'https://next.example/api' : _server,
        );
        addTearDown(next.dispose);
        await lease.preserve({
          'rawQty': '0001.',
          'note': 'last original input',
        });
        expect(
          storage.values.keys.single,
          '${formDraftStoragePrefix(_server, _owner)}one',
        );
        await next.read(formDraftsProvider.notifier).ready;
        expect(next.read(formDraftsProvider), isEmpty);
      },
    );
  }

  test(
    'CAS committed before owner retirement records its revision before final preservation',
    () async {
      final storage = _Storage();
      final original = _container(storage);
      final store = original.read(formDraftsProvider.notifier);
      await store.ready;
      final lease = store.capturePreservationLease(
        draftId: 'one',
        spec: _spec,
        route: _spec.route,
      )!;
      storage.afterCommit = original.dispose;
      final writing = store.save(
        _draft('one', {'note': 'in-flight'}),
        preservationLease: lease,
      );
      await writing;
      await lease.preserve({
        'note': 'latest after in-flight',
      }, pendingWrite: writing.then((_) {}));
      expect(storage.values, hasLength(1));
      final stored = jsonDecode(storage.values.values.single) as Map;
      expect((stored['data'] as Map)['note'], 'latest after in-flight');
      expect(stored['lifecycle'], isNull);
    },
  );

  for (final terminal in ['completed', 'deleted']) {
    test(
      'retirement never revives $terminal original; conflict copy is history-only',
      () async {
        final storage = _Storage();
        final original = _container(storage);
        final store = original.read(formDraftsProvider.notifier);
        await store.ready;
        final lease = store.capturePreservationLease(
          draftId: 'one',
          spec: _spec,
          route: _spec.route,
        )!;
        await store.save(
          _draft('one', {'note': 'first'}),
          preservationLease: lease,
        );
        final key = storage.values.keys.single;
        final marker = jsonEncode({
          'version': 1,
          'id': 'one',
          'completed': true,
          'historyAction': terminal,
          'revision': 'terminal',
        });
        storage.values[key] = marker;
        final backup = await lease.preserve({
          'note': 'last input',
          'idempotencyKey': 'unchanged-command',
        });
        expect(storage.values[key], marker);
        final retained =
            jsonDecode(storage.values['${lease.ownerKey}${backup.id}']!)
                as Map<String, dynamic>;
        expect(retained['lifecycle'], 'RETIRED');
        expect(isActiveFormDraftRecord(retained), isFalse);
        expect(backup.data['idempotencyKey'], 'unchanged-command');
        expect(backup.hasUnknownSubmission, isTrue);
        await expectLater(
          store.save(backup, expectedRevision: backup.revision),
          throwsA(isA<FormDraftConflict>()),
        );
        original.dispose();
        final reopened = _container(storage);
        addTearDown(reopened.dispose);
        await reopened.read(formDraftsProvider.notifier).ready;
        expect(reopened.read(formDraftsProvider), isEmpty);
      },
    );
  }

  test(
    'retirement cannot clear stored Unknown or replace its original command proof',
    () async {
      final storage = _Storage();
      final original = _container(storage);
      addTearDown(original.dispose);
      final store = original.read(formDraftsProvider.notifier);
      await store.ready;
      final lease = store.capturePreservationLease(
        draftId: 'one',
        spec: _spec,
        route: _spec.route,
      )!;
      await store.save(
        _draft('one', {
          formDraftUnknownSubmissionKey: true,
          'idempotencyKey': 'original-command',
          'frozenBody': {'rawQty': '0001.', 'price': 'PRIVATE_PRICE'},
        }),
        preservationLease: lease,
      );
      final key = storage.values.keys.single,
          previous = storage.values.values.single;
      final backup = await lease.preserve({
        formDraftUnknownSubmissionKey: false,
        'note': 'latest editable input',
      });
      expect(storage.values[key], previous);
      expect(backup.hasUnknownSubmission, isTrue);
      final retained = backup.data['_formDraftRetiredPreviousSnapshot'] as Map;
      expect(retained['idempotencyKey'], 'original-command');
      expect((retained['frozenBody'] as Map)['rawQty'], '0001.');
      expect(
        (jsonDecode(storage.values['${lease.ownerKey}${backup.id}']!)
            as Map<String, dynamic>)['lifecycle'],
        'RETIRED',
      );
    },
  );

  test(
    'clean discard resets lease revision without generating a conflict copy',
    () async {
      final storage = _Storage();
      final original = _container(storage);
      addTearDown(original.dispose);
      final store = original.read(formDraftsProvider.notifier);
      await store.ready;
      final lease = store.capturePreservationLease(
        draftId: 'one',
        spec: _spec,
        route: _spec.route,
      )!;
      final saved = await store.save(
        _draft('one', {'note': 'first'}),
        preservationLease: lease,
      );
      await store.discardClean(
        'one',
        expectedRevision: saved.revision,
        preservationLease: lease,
      );
      final finalSaved = await lease.preserve({'note': 'new dirty input'});
      expect(finalSaved.id, 'one');
      expect(storage.values, hasLength(1));
      expect(
        (jsonDecode(storage.values.values.single)
            as Map<String, dynamic>)['lifecycle'],
        isNull,
      );
    },
  );

  test(
    'failed preservation keeps exit blocked and retries the detached original snapshot',
    () async {
      final storage = _Storage();
      final original = _container(storage);
      final store = original.read(formDraftsProvider.notifier);
      await store.ready;
      final lease = store.capturePreservationLease(
        draftId: 'one',
        spec: _spec,
        route: _spec.route,
      )!;
      original.dispose();
      storage.fail = true;
      final snapshot = <String, dynamic>{'note': 'original input'};
      final failed = lease.preserve(snapshot);
      snapshot['note'] = 'mutated caller';
      await expectLater(failed, throwsStateError);
      expect(webUpdateSafety.snapshot.blocked, isTrue);
      expect(await webUpdateSafety.prepareServerReload(), isFalse);
      storage.fail = false;
      expect(await webUpdateSafety.prepareServerReload(), isTrue);
      expect(
        ((jsonDecode(storage.values.values.single)
                as Map<String, dynamic>)['data']
            as Map)['note'],
        'original input',
      );
    },
  );

  test(
    'original reset generation fence rejects retirement without resurrecting old records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'uten-retirement-reset-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = NativeFormDraftStorage(
        directoryProvider: () async => directory,
      );
      final original = _container(storage);
      final store = original.read(formDraftsProvider.notifier);
      await store.ready;
      final lease = store.capturePreservationLease(
        draftId: 'one',
        spec: _spec,
        route: _spec.route,
      )!;
      original.dispose();
      await storage.synchronizeBusinessReset(
        formDraftStorageOwnerPrefix(_server, _owner),
        1,
      );
      await expectLater(
        lease.preserve({'note': 'old dataset input'}),
        throwsA(isA<FormDraftGenerationMismatch>()),
      );
      expect(webUpdateSafety.snapshot.blocked, isFalse);
      expect(
        await storage.readAll(
          '${formDraftStorageOwnerPrefix(_server, _owner)}g1_',
        ),
        isEmpty,
      );
    },
  );

  test(
    'initial lower-generation mismatch retains detached input and keeps exit protected',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'uten-retirement-restore-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = NativeFormDraftStorage(
        directoryProvider: () async => directory,
      );
      await storage.synchronizeBusinessReset(
        formDraftStorageOwnerPrefix(_server, _owner),
        2,
      );
      final restored = _container(storage);
      final store = restored.read(formDraftsProvider.notifier);
      await expectLater(
        store.ready,
        throwsA(isA<FormDraftGenerationMismatch>()),
      );
      final lease = store.capturePreservationLease(
        draftId: 'one',
        spec: _spec,
        route: _spec.route,
      )!;
      addTearDown(() => webUpdateSafety.unregister(lease));
      restored.dispose();
      await expectLater(
        lease.preserve({
          'note': 'original input after unavailable draft initialization',
        }),
        throwsA(isA<FormDraftGenerationMismatch>()),
      );
      expect(webUpdateSafety.snapshot.blocked, isTrue);
      expect(await webUpdateSafety.prepareServerReload(), isFalse);
      expect(
        await storage.readAll(
          '${formDraftStorageOwnerPrefix(_server, _owner)}g2_',
        ),
        isEmpty,
      );
    },
  );
}
