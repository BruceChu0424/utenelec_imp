import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/auth/models/auth_session.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

const _datasetA = 'bd6a3b4a-474e-48d6-8c42-c8ed99030bcd';
const _datasetB = 'ae4221bb-e660-4b30-a745-44bc62c4f14c';

class _DatasetSession extends SessionNotifier {
  _DatasetSession(this.initial);
  final SessionState initial;
  @override
  SessionState build() => initial;
  void replace(SessionState next) => state = next;
}

SessionState _impersonating(
  String? targetDataset,
  String? actorDataset, {
  String actorName = '管理员',
}) => SessionState(
  status: AuthStatus.authenticated,
  user: AppUser(
    id: 'target',
    code: 'TARGET',
    name: '员工',
    businessDatasetId: targetDataset,
  ),
  actor: AppUser(
    id: 'admin',
    code: 'ADMIN',
    name: actorName,
    businessDatasetId: actorDataset,
  ),
);

void main() {
  test('profile requires a canonical dataset UUID when the field is present', () {
    final legacy = <String, dynamic>{'id': 'user', 'loginAccount': 'E001'};
    expect(UserProfile.fromJson(legacy).businessDatasetId, isNull);
    expect(
      UserProfile.fromJson({
        ...legacy,
        'businessDatasetId': _datasetA,
      }).businessDatasetId,
      _datasetA,
    );
    for (final invalid in <Object?>[
      null,
      '',
      ' ',
      4,
      false,
      _datasetA.toUpperCase(),
      ' $_datasetA',
      '$_datasetA ',
      _datasetA.replaceAll('-', ''),
      'not-a-dataset-id',
    ]) {
      expect(
        () => UserProfile.fromJson({...legacy, 'businessDatasetId': invalid}),
        throwsFormatException,
        reason:
            'A malformed identity must not reopen the legacy namespace: $invalid',
      );
    }
  });

  test('legacy owner bytes survive and each dataset has a stable owner', () {
    const server = 'https://history/api';
    const legacy = AuthenticatedScope(userId: 'one');
    const firstLogin = AuthenticatedScope(
      userId: 'one',
      epoch: 1,
      businessDatasetId: _datasetA,
    );
    const repeatedLogin = AuthenticatedScope(
      userId: 'one',
      epoch: 2,
      businessDatasetId: _datasetA,
    );
    const rebuiltDatabase = AuthenticatedScope(
      userId: 'one',
      epoch: 1,
      businessDatasetId: _datasetB,
    );
    const laterGeneration = AuthenticatedScope(
      userId: 'one',
      epoch: 1,
      businessResetGeneration: 45,
      businessDatasetId: _datasetA,
    );
    final legacyBytes =
        '${sha256.convert(utf8.encode(jsonEncode([server, 'one', null])))}_';
    expect(formDraftStorageOwnerPrefix(server, legacy), legacyBytes);
    expect(formDraftStoragePrefix(server, legacy), legacyBytes);
    final owner = formDraftStorageOwnerPrefix(server, firstLogin);
    expect(owner, isNot(legacyBytes));
    expect(formDraftStorageOwnerPrefix(server, repeatedLogin), owner);
    expect(
      formDraftStoragePrefix(server, repeatedLogin),
      formDraftStoragePrefix(server, firstLogin),
    );
    expect(formDraftStorageOwnerPrefix(server, rebuiltDatabase), isNot(owner));
    expect(formDraftStorageOwnerPrefix(server, laterGeneration), owner);
    expect(formDraftStoragePrefix(server, laterGeneration), '${owner}g45_');
    expect(firstLogin, isNot(rebuiltDatabase));
    expect({firstLogin, rebuiltDatabase}, hasLength(2));
  });

  test('dataset replacement changes both profile and session identity', () {
    AppUser user(String? dataset) => AppUser(
      id: 'one',
      code: 'ADMIN',
      name: '系统管理员',
      businessDatasetId: dataset,
    );
    final original = user(_datasetA);
    final same = user(_datasetA);
    final replacement = user(_datasetB);
    final legacy = user(null);
    expect(original, same);
    expect(original.hashCode, same.hashCode);
    expect(original, isNot(replacement));
    expect(original, isNot(legacy));
    final session = SessionState(
      status: AuthStatus.authenticated,
      user: original,
    );
    expect(
      session.isSameIdentity(
        SessionState(status: AuthStatus.authenticated, user: same),
      ),
      isTrue,
    );
    for (final changed in [replacement, legacy]) {
      expect(
        session.isSameIdentity(
          SessionState(status: AuthStatus.authenticated, user: changed),
        ),
        isFalse,
      );
    }
  });

  for (final transition in [
    (
      beforeTarget: _datasetA,
      beforeActor: _datasetA,
      target: _datasetA,
      actor: _datasetB,
    ),
    (
      beforeTarget: _datasetA,
      beforeActor: _datasetA,
      target: _datasetA,
      actor: null,
    ),
    (
      beforeTarget: _datasetA,
      beforeActor: _datasetA,
      target: null,
      actor: _datasetA,
    ),
    (beforeTarget: null, beforeActor: null, target: _datasetA, actor: null),
    (beforeTarget: null, beforeActor: null, target: null, actor: _datasetA),
  ]) {
    test('impersonation dataset mismatch fences scope: $transition', () {
      final initial = _impersonating(
        transition.beforeTarget,
        transition.beforeActor,
      );
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => _DatasetSession(initial)),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(authenticatedScopeProvider), isNotNull);
      final replacement = _impersonating(transition.target, transition.actor);
      (container.read(sessionProvider.notifier) as _DatasetSession).replace(
        replacement,
      );
      expect(replacement.isSameIdentity(initial), isFalse);
      expect(container.read(authenticatedScopeProvider), isNull);
    });
  }

  for (final dataset in <String?>[null, _datasetA]) {
    test('same-dataset actor profile refresh preserves scope: $dataset', () {
      final initial = _impersonating(dataset, dataset);
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(() => _DatasetSession(initial)),
        ],
      );
      addTearDown(container.dispose);
      final before = container.read(authenticatedScopeProvider);
      expect(before, isNotNull);
      var scopeNotifications = 0;
      container.listen(
        authenticatedScopeProvider,
        (_, _) => scopeNotifications++,
      );
      final refreshed = _impersonating(dataset, dataset, actorName: '最新管理员姓名');
      (container.read(sessionProvider.notifier) as _DatasetSession).replace(
        refreshed,
      );
      expect(refreshed.isSameIdentity(initial), isTrue);
      expect(
        identical(container.read(authenticatedScopeProvider), before),
        isTrue,
      );
      expect(scopeNotifications, 0);
    });
  }
}
