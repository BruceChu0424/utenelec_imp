// 会话快照契约(ADR-108 / perf-frontend-03、-14):
// /auth/me 一次带回「可委派页面 + 六个单据范围写能力 + 偏好整表」;
// 打开任意多个页面、反复读写能力与偏好, 都不再各自请求 capability / preferences。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/features/production/providers/production_board_sort_provider.dart';
import 'package:uten_imp/features/stock/providers/instant_inventory_prefs_provider.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _MeApi extends ApiClient {
  _MeApi({this.failuresBeforeSuccess = 0}) : super(Dio());

  final List<String> paths = [];

  /// 前几次 /auth/me 模拟网络失败。
  int failuresBeforeSuccess;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    if (path != ApiEndpoints.authMe) {
      throw StateError('unexpected GET $path');
    }
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.connectionError,
      );
    }
    return {
      'id': 'user-1',
      'session': {
        'delegableSurfaceKeys': ['purchase.orders', 'sales.orders'],
        'documentScopes': {
          for (final scope in DocumentDataScope.values)
            scope.apiValue: {
              'scope': scope.apiValue,
              'writeAll': scope == DocumentDataScope.sales,
              'writableOwnerIds': ['owner-1'],
            },
        },
        'preferences': {
          'page.sales.orders': {'density': 'compact'},
          'stock.instantInventory': false,
          'productionBoard.sort': 'progress',
        },
      },
    };
  }
}

void main() {
  test('十个页面读写能力 / 可委派 / 偏好: 只有一次 /auth/me, 0 次 capability 与偏好请求', () async {
    final api = _MeApi();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'user-1'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(sessionSnapshotProvider, (_, _) {});

    for (var page = 0; page < 10; page++) {
      for (final scope in DocumentDataScope.values) {
        final capability = await container.read(
          documentScopeCapabilityProvider(scope).future,
        );
        expect(capability.canWrite('owner-1'), isTrue);
        expect(
          capability.canWrite('someone-else'),
          scope == DocumentDataScope.sales,
        );
      }
      final snapshot = await container.read(sessionSnapshotProvider.future);
      expect(snapshot!.canDelegate('purchase.orders'), isTrue);
      expect(snapshot.canDelegate('finance.receipts'), isFalse);
      expect(snapshot.preferences['page.sales.orders'], {'density': 'compact'});
    }

    expect(api.paths, [ApiEndpoints.authMe]);
  });

  test('本端写偏好后就地更新快照, 不重拉', () async {
    final api = _MeApi();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'user-1'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(sessionSnapshotProvider, (_, _) {});
    await container.read(sessionSnapshotProvider.future);

    container.read(sessionSnapshotProvider.notifier).updatePreference(
      'page.sales.orders',
      {'density': 'comfortable'},
    );

    final snapshot = container.read(sessionSnapshotProvider).requireValue!;
    expect(snapshot.preferences['page.sales.orders'], {
      'density': 'comfortable',
    });
    expect(api.paths, hasLength(1));
  });

  test('未登录没有快照, 也不发请求; 单据范围按只读', () async {
    final api = _MeApi();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(sessionSnapshotProvider.future), isNull);
    final capability = await container.read(
      documentScopeCapabilityProvider(DocumentDataScope.finance).future,
    );
    expect(capability.canWrite('owner-1'), isFalse);
    expect(api.paths, isEmpty);
  });

  test(
    'page preference notifiers read the snapshot: 0 GET /user/preferences',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _MeApi();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'user-1'),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(instantInventoryPrefsProvider, (_, _) {});
      container.listen(productionBoardSortProvider, (_, _) {});
      await container.read(sessionSnapshotProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(instantInventoryPrefsProvider), isFalse);
      expect(container.read(productionBoardSortProvider), 'progress');
      expect(api.paths, [ApiEndpoints.authMe]);
    },
  );

  test('快照加载失败不停在失败态: 断网恢复后立即重取', () async {
    final api = _MeApi(failuresBeforeSuccess: 1);
    final recovery = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const <Duration>[Duration(milliseconds: 1)],
      restoredDisplayDuration: Duration.zero,
    );
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        connectionRecoveryProvider.overrideWith((ref) => recovery),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'user-1'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(sessionSnapshotProvider, (_, _) {});

    await expectLater(
      container.read(sessionSnapshotProvider.future),
      throwsA(isA<DioException>()),
    );
    expect(container.read(sessionSnapshotProvider).hasError, isTrue);

    recovery.markDisconnected();
    recovery.markConnected();
    final snapshot = await container.read(sessionSnapshotProvider.future);
    expect(snapshot!.canDelegate('purchase.orders'), isTrue);
    expect(api.paths, [ApiEndpoints.authMe, ApiEndpoints.authMe]);
  });

  test('快照加载失败且网络没断: 按退避自动重试', () async {
    final api = _MeApi(failuresBeforeSuccess: 1);
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'user-1'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(sessionSnapshotProvider, (_, _) {});

    await expectLater(
      container.read(sessionSnapshotProvider.future),
      throwsA(isA<DioException>()),
    );
    await Future<void>.delayed(
      SessionSnapshotNotifier.retryDelays.first +
          const Duration(milliseconds: 200),
    );
    final snapshot = container.read(sessionSnapshotProvider).valueOrNull;
    expect(snapshot?.canDelegate('purchase.orders'), isTrue);
    expect(api.paths, hasLength(2));
  });
}
