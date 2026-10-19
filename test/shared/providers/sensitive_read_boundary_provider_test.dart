import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_epoch_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

const _permissions = [Perm.stockView, Perm.productionQualityInspectionView];

SessionState _signedIn({
  String userId = 'user-1',
  String name = 'Employee',
  List<String> permissions = _permissions,
  bool superAdmin = false,
  int resetGeneration = 0,
  AppUser? actor,
  bool readOnly = false,
  AuthStatus status = AuthStatus.authenticated,
}) => SessionState(
  status: status,
  user: AppUser(
    id: userId,
    code: 'EMP',
    name: name,
    permissions: permissions,
    superAdmin: superAdmin,
    businessResetGeneration: resetGeneration,
  ),
  actor: actor,
  impersonationReadOnly: readOnly,
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => _signedIn();

  void replace(SessionState next) => state = next;
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  int scopeReads = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, ApiEndpoints.myWarehouseScope);
    scopeReads++;
    return {
      'role': 'KEEPER',
      'warehouseParticipant': true,
      'selectable': [
        {'id': 'warehouse-1', 'name': 'Warehouse'},
      ],
    };
  }
}

// The boundary must compare clients by identity even if an implementation
// later defines value equality (for example, by the endpoint URL).
class _ValueEqualApi extends _Api {
  @override
  bool operator ==(Object other) => other is _ValueEqualApi;

  @override
  int get hashCode => 1;
}

final _apiInput = StateProvider<ApiClient>((_) => _Api());

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      apiClientProvider.overrideWith((ref) => ref.watch(_apiInput)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

SensitiveReadBoundary _snapshot({
  AuthenticatedScope? identity = const AuthenticatedScope(userId: 'user-1'),
  required ApiClient api,
  required Set<String> permissions,
  bool superAdmin = false,
}) {
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWithValue(identity),
      apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(superAdmin),
    ],
  );
  try {
    return container.read(sensitiveReadBoundaryProvider);
  } finally {
    container.dispose();
  }
}

void main() {
  test(
    'boundary equality uses identity values and unordered permission content',
    () {
      final api = _Api();
      final first = _snapshot(
        api: api,
        permissions: {'stock:view', 'plan:view'},
      );
      final copied = _snapshot(
        api: api,
        permissions: {'plan:view', 'stock:view'},
      );
      expect(first, copied);
      expect(first.hashCode, copied.hashCode);
      expect({first, copied}, hasLength(1));
    },
  );

  test('permission snapshots copy the source set and cannot be mutated', () {
    final source = {'stock:view', 'plan:view'};
    final boundary = _snapshot(api: _Api(), permissions: source);
    final hash = boundary.hashCode;
    source
      ..clear()
      ..add('unrelated:view');
    expect(boundary.permissions, {'stock:view', 'plan:view'});
    expect(boundary.hashCode, hash);
    expect(() => boundary.permissions.add('write'), throwsUnsupportedError);
    expect(
      () => boundary.permissions.remove('stock:view'),
      throwsUnsupportedError,
    );
    expect(() => boundary.permissions.clear(), throwsUnsupportedError);
  });

  test('equal-looking API clients are distinct read boundaries', () {
    final firstApi = _ValueEqualApi(), secondApi = _ValueEqualApi();
    expect(firstApi, secondApi);
    expect(identical(firstApi, secondApi), isFalse);
    expect(
      _snapshot(api: firstApi, permissions: {'stock:view'}),
      isNot(_snapshot(api: secondApi, permissions: {'stock:view'})),
    );
  });

  test(
    'real session profile refresh and reordered copies never refresh consumers',
    () async {
      final container = _container();
      final changes = <SensitiveReadBoundary>[];
      container.listen(
        sensitiveReadBoundaryProvider,
        (_, next) => changes.add(next),
      );
      var reads = 0;
      final read = Provider<int>((ref) {
        ref.watch(sensitiveReadBoundaryProvider);
        return ++reads;
      });
      container.listen(read, (_, _) {});
      expect(container.read(read), 1);
      final initial = container.read(sensitiveReadBoundaryProvider);
      final originalSet = container.read(currentPermissionsProvider);
      final session = container.read(sessionProvider.notifier) as _Session;

      session.replace(
        _signedIn(
          name: 'Updated profile',
          permissions: _permissions.reversed.toList(),
        ),
      );
      expect(
        identical(originalSet, container.read(currentPermissionsProvider)),
        isFalse,
      );
      expect(container.read(sensitiveReadBoundaryProvider), initial);
      await container.pump();
      expect(container.read(read), 1);

      session.replace(
        _signedIn(name: 'Updated again', permissions: List.of(_permissions)),
      );
      await container.pump();
      expect(container.read(sensitiveReadBoundaryProvider), initial);
      expect(changes, isEmpty);
      expect(reads, 1);
    },
  );

  test(
    'real warehouse scope keeps its read for equal permissions and refreshes on authorization changes',
    () async {
      final container = _container();
      container.listen(myWarehouseScopeProvider, (_, _) {});
      final api = container.read(_apiInput) as _Api;
      final first = await container.read(myWarehouseScopeProvider.future);
      expect(api.scopeReads, 1);
      final session = container.read(sessionProvider.notifier) as _Session;
      session.replace(
        _signedIn(
          name: 'Updated profile',
          permissions: _permissions.reversed.toList(),
        ),
      );
      await container.pump();
      expect(
        await container.read(myWarehouseScopeProvider.future),
        same(first),
      );
      expect(api.scopeReads, 1);

      session.replace(_signedIn(permissions: const [Perm.stockView]));
      await container.pump();
      await container.read(myWarehouseScopeProvider.future);
      expect(api.scopeReads, 2);

      final replacement = _Api();
      container.read(_apiInput.notifier).state = replacement;
      await container.pump();
      await container.read(myWarehouseScopeProvider.future);
      expect(replacement.scopeReads, 1);
      session.replace(const SessionState());
      await container.pump();
      expect(
        await container.read(myWarehouseScopeProvider.future),
        same(MyWarehouseScope.empty),
      );
      expect(
        replacement.scopeReads,
        1,
        reason: 'logout cannot read the old account warehouse scope',
      );
    },
  );

  test(
    'permission removal and addition immediately invalidate the boundary',
    () {
      final container = _container();
      final changes = <SensitiveReadBoundary>[];
      container.listen(
        sensitiveReadBoundaryProvider,
        (_, next) => changes.add(next),
      );
      final initial = container.read(sensitiveReadBoundaryProvider);
      final session = container.read(sessionProvider.notifier) as _Session;
      session.replace(_signedIn(permissions: const [Perm.stockView]));
      final revoked = container.read(sensitiveReadBoundaryProvider);
      expect(revoked, isNot(initial));
      expect(revoked.permissions, {Perm.stockView});
      session.replace(
        _signedIn(permissions: const [Perm.stockView, Perm.purchaseOrderView]),
      );
      expect(container.read(sensitiveReadBoundaryProvider), isNot(revoked));
      expect(changes, hasLength(2));
    },
  );

  final identityChanges = <String, SessionState>{
    'account': _signedIn(userId: 'user-2'),
    'actor': _signedIn(
      actor: const AppUser(id: 'actor', code: 'A', name: 'Actor'),
    ),
    'read-only impersonation': _signedIn(readOnly: true),
    'business reset generation': _signedIn(resetGeneration: 1),
    'logout': const SessionState(),
    'password-change gate': _signedIn(status: AuthStatus.mustChangePassword),
  };
  for (final entry in identityChanges.entries) {
    test('${entry.key} immediately invalidates the boundary', () {
      final container = _container();
      container.listen(sensitiveReadBoundaryProvider, (_, _) {});
      final initial = container.read(sensitiveReadBoundaryProvider);
      (container.read(sessionProvider.notifier) as _Session).replace(
        entry.value,
      );
      expect(container.read(sensitiveReadBoundaryProvider), isNot(initial));
    });
  }

  test('same-account login epoch immediately invalidates the boundary', () {
    final container = _container();
    container.listen(sensitiveReadBoundaryProvider, (_, _) {});
    final initial = container.read(sensitiveReadBoundaryProvider);
    container.read(sessionEpochProvider.notifier).state++;
    expect(container.read(sensitiveReadBoundaryProvider), isNot(initial));
  });

  test(
    'API replacement and super-admin changes immediately invalidate the boundary',
    () {
      final container = _container();
      final changes = <SensitiveReadBoundary>[];
      container.listen(
        sensitiveReadBoundaryProvider,
        (_, next) => changes.add(next),
      );
      final initial = container.read(sensitiveReadBoundaryProvider);
      container.read(_apiInput.notifier).state = _Api();
      final changedApi = container.read(sensitiveReadBoundaryProvider);
      expect(changedApi, isNot(initial));
      final session = container.read(sessionProvider.notifier) as _Session;
      session.replace(_signedIn(superAdmin: true));
      final admin = container.read(sensitiveReadBoundaryProvider);
      expect(admin, isNot(changedApi));
      expect(admin.superAdmin, isTrue);
      session.replace(_signedIn());
      expect(container.read(sensitiveReadBoundaryProvider), isNot(admin));
      expect(changes, hasLength(3));
    },
  );
}
