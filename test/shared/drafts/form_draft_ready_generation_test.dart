import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import 'memory_form_draft_storage.dart';

class _DelayedResetStorage extends MemoryFormDraftStorage
    implements BusinessResetFormDraftStorage {
  final synchronizations = <Completer<void>>[];

  @override
  Future<void> synchronizeBusinessReset(String ownerPrefix, int generation) {
    final result = Completer<void>();
    synchronizations.add(result);
    return result.future;
  }
}

const _scope = AuthenticatedScope(userId: 'user', businessResetGeneration: 1);
const _permissions = {Perm.salesOrderView, Perm.salesOrderCreate};
const _server = 'https://current/api';

ProviderContainer _container(_DelayedResetStorage storage) => ProviderContainer(
  overrides: [
    authenticatedScopeProvider.overrideWithValue(_scope),
    currentPermissionsProvider.overrideWithValue(_permissions),
    apiBaseUrlProvider.overrideWithValue(_server),
    formDraftStorageProvider.overrideWithValue(storage),
  ],
);

Future<void> _drain() => Future<void>.delayed(Duration.zero);

void main() {
  test('ready follows a permission rebuild before exposing drafts', () async {
    final storage = _DelayedResetStorage();
    final draft = FormDraft(
      id: 'retained',
      title: '未完成订货',
      module: BadgeModule.sales,
      route: '/sales/orders/new',
      permission: Perm.salesOrderCreate,
      updatedAt: DateTime.utc(2026),
      data: const {'note': '原输入'},
    );
    storage.records['${formDraftStoragePrefix(_server, _scope)}retained'] =
        jsonEncode(draft.toJson());
    final container = _container(storage);
    addTearDown(container.dispose);
    final notifier = container.read(formDraftsProvider.notifier);
    var readyFinished = false;
    final ready = notifier.ready.then((_) => readyFinished = true);
    await _drain();
    container.updateOverrides([
      authenticatedScopeProvider.overrideWithValue(_scope),
      apiBaseUrlProvider.overrideWithValue(_server),
      formDraftStorageProvider.overrideWithValue(storage),
      currentPermissionsProvider.overrideWithValue({
        ..._permissions,
        Perm.goodsView,
      }),
    ]);
    container.read(formDraftsProvider);
    await _drain();
    expect(storage.synchronizations, hasLength(2));
    storage.synchronizations.first.completeError(
      StateError('业务数据已清空，请重新登录后使用草稿'),
    );
    await _drain();
    expect(readyFinished, isFalse);
    storage.synchronizations.last.complete();
    await ready;
    expect(container.read(formDraftsProvider).single.id, 'retained');
  });

  test('ready preserves a current reset fence failure', () async {
    final storage = _DelayedResetStorage();
    final container = _container(storage);
    addTearDown(container.dispose);
    final notifier = container.read(formDraftsProvider.notifier);
    final ready = expectLater(
      notifier.ready,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          '业务数据已清空，请重新登录后使用草稿',
        ),
      ),
    );
    await _drain();
    storage.synchronizations.single.completeError(
      StateError('业务数据已清空，请重新登录后使用草稿'),
    );
    await ready;
    expect(container.read(formDraftsProvider), isEmpty);
  });

  for (final change in ['account', 'server', 'epoch']) {
    test(
      'ready rejects an old $change even after the new build succeeds',
      () async {
        final storage = _DelayedResetStorage();
        final container = _container(storage);
        addTearDown(container.dispose);
        final notifier = container.read(formDraftsProvider.notifier);
        final oldReady = expectLater(
          notifier.ready,
          throwsA(isA<StateError>()),
        );
        await _drain();
        container.updateOverrides([
          currentPermissionsProvider.overrideWithValue(_permissions),
          formDraftStorageProvider.overrideWithValue(storage),
          authenticatedScopeProvider.overrideWithValue(
            change == 'account'
                ? const AuthenticatedScope(userId: 'other')
                : change == 'epoch'
                ? const AuthenticatedScope(
                    userId: 'user',
                    epoch: 2,
                    businessResetGeneration: 1,
                  )
                : _scope,
          ),
          apiBaseUrlProvider.overrideWithValue(
            change == 'server' ? 'https://other/api' : _server,
          ),
        ]);
        container.read(formDraftsProvider);
        await _drain();
        storage.synchronizations.last.complete();
        await container.read(formDraftsProvider.notifier).ready;
        storage.synchronizations.first.complete();
        await oldReady;
      },
    );
  }
}
