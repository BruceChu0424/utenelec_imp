import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/admin/providers/server_operations_access.dart';
import 'package:uten_imp/features/admin/providers/server_storage_request_store.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  for (final grant in [
    Perm.serverStatusView,
    Perm.serverUpdate,
    Perm.serverCleanup,
    Perm.authorizationManage,
  ]) {
    test(
      '$grant preserves separate operations viewing and superadmin source authority',
      () {
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(
              () => _Session(
                AppUser(
                  id: 'operator',
                  code: 'OP',
                  name: '运维',
                  permissions: [grant],
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        expect(
          container.read(serverOperationsVisibleProvider),
          grant != Perm.authorizationManage,
        );
        expect(container.read(serverSourceVisibleProvider), false);
      },
    );
  }
  test(
    'source configuration requires both superadmin and authorization grant',
    () {
      for (final hasGrant in [false, true]) {
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(
              () => _Session(
                AppUser(
                  id: 'admin',
                  code: 'A',
                  name: '超管',
                  superAdmin: true,
                  permissions: hasGrant ? [Perm.authorizationManage] : [],
                ),
              ),
            ),
          ],
        );
        expect(container.read(serverOperationsVisibleProvider), true);
        expect(container.read(serverSourceVisibleProvider), hasGrant);
        container.dispose();
      }
    },
  );
  test(
    'mutations require confirmed own writable session, never impersonation',
    () async {
      for (final scope in [
        const AuthenticatedScope(userId: 'operator'),
        const AuthenticatedScope(userId: 'operator', readOnly: true),
        const AuthenticatedScope(userId: 'operator', actorId: 'admin'),
      ]) {
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(
              () => _Session(
                const AppUser(id: 'operator', code: 'OP', name: '运维'),
              ),
            ),
            authenticatedScopeProvider.overrideWithValue(scope),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
          ],
        );
        expect(
          container.read(serverOperationsWritableProvider),
          false,
          reason: 'unconfirmed session cannot mutate',
        );
        await container.read(sessionSnapshotProvider.future);
        expect(
          container.read(serverOperationsWritableProvider),
          !scope.readOnly && scope.actorId == null,
        );
        container.dispose();
      }
    },
  );

  test(
    'receipt ownership survives same-user login, isolates server/account/business reset',
    () {
      final identity = StateProvider<AuthenticatedScope?>(
        (ref) => const AuthenticatedScope(userId: 'operator', epoch: 1),
      );
      final endpoint = StateProvider((ref) => 'https://company-a/api');
      final container = ProviderContainer(
        overrides: [
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(endpoint)),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(identity)),
        ],
      );
      addTearDown(container.dispose);
      final first = container.read(serverStorageRequestOwnerProvider);
      container.read(identity.notifier).state = const AuthenticatedScope(
        userId: 'operator',
        epoch: 2,
      );
      expect(container.read(serverStorageRequestOwnerProvider), first);
      container.read(endpoint.notifier).state = 'https://company-b/api';
      expect(container.read(serverStorageRequestOwnerProvider), isNot(first));
      container.read(endpoint.notifier).state = 'https://company-a/api';
      container.read(identity.notifier).state = const AuthenticatedScope(
        userId: 'operator',
        businessResetGeneration: 1,
      );
      expect(container.read(serverStorageRequestOwnerProvider), isNot(first));
      container.read(identity.notifier).state = const AuthenticatedScope(
        userId: 'other',
      );
      expect(container.read(serverStorageRequestOwnerProvider), isNot(first));
      container.read(identity.notifier).state = const AuthenticatedScope(
        userId: 'operator',
        actorId: 'admin',
      );
      expect(container.read(serverStorageRequestOwnerProvider), isNull);
    },
  );
  test(
    'receipt store contains only validated UUIDs and never mixes owner records',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ServerStorageRequestStore(preferences);
      const request = '11111111-2222-3333-4444-555555555555';
      await store.remember('owner-a', request);
      expect(store.read('owner-a'), request);
      expect(store.read('owner-b'), isNull);
      await expectLater(
        store.remember('owner-a', 'not-a-request'),
        throwsStateError,
      );
      expect(store.read('owner-a'), request);
      expect(preferences.getKeys(), {'serverStorage.lastRequest.v1.owner-a'});
    },
  );
}

class _Session extends SessionNotifier {
  _Session(this.user);
  final AppUser user;
  @override
  SessionState build() =>
      SessionState(status: AuthStatus.authenticated, user: user);
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);
}
