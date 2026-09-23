// 页面偏好与会话快照的竞态回归(ADR-108 修复轮):
// 某个偏好推送成功后就地更新会话快照, 不能把其它偏好(或同一偏好推送期间的新改动)
// 冲回快照里的旧值, 更不能再把旧值推上服务端。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/production/providers/production_board_sort_provider.dart';
import 'package:uten_imp/features/stock/providers/instant_inventory_prefs_provider.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _LoggedIn extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'user-1', code: 'u1', name: 'U', roles: []),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final List<String> puts = [];
  final Map<String, Object?> server = {};
  int meCalls = 0;
  Duration putDelay = const Duration(milliseconds: 50);

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.authMe) throw StateError('unexpected $path');
    meCalls++;
    return {
      'id': 'user-1',
      'session': {
        'delegableSurfaceKeys': <String>[],
        'documentScopes': <String, dynamic>{},
        'preferences': {
          'stock.instantInventory':
              server[ApiEndpoints.userPreference('stock.instantInventory')] ??
              false,
          'productionBoard.sort':
              server[ApiEndpoints.userPreference('productionBoard.sort')] ??
              'progress',
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    puts.add('$path=$body');
    await Future<void>.delayed(putDelay);
    server[path] = body;
    return {};
  }
}

Future<(ProviderContainer, _Api)> _boot() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _Api();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      sharedPreferencesProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_LoggedIn.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'user-1'),
      ),
    ],
  );
  container.listen(instantInventoryPrefsProvider, (_, _) {});
  container.listen(productionBoardSortProvider, (_, _) {});
  await container.read(sessionSnapshotProvider.future);
  await Future<void>.delayed(Duration.zero);
  return (container, api);
}

void main() {
  test('A 键推送成功不冲掉 B 键还在防抖中的改动, 也不把旧值推上去', () async {
    final (c, api) = await _boot();
    addTearDown(c.dispose);
    expect(c.read(instantInventoryPrefsProvider), isFalse);

    // A: 改排序; 300ms 后 B: 打开即时库存(B 的防抖晚于 A 的推送完成)。
    c.read(productionBoardSortProvider.notifier).update('deliveryDate');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    c.read(instantInventoryPrefsProvider.notifier).update(true);

    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(c.read(instantInventoryPrefsProvider), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(c.read(instantInventoryPrefsProvider), isTrue);
    expect(c.read(productionBoardSortProvider), 'deliveryDate');
    expect(api.puts, [
      '${ApiEndpoints.userPreference('productionBoard.sort')}=deliveryDate',
      '${ApiEndpoints.userPreference('stock.instantInventory')}=true',
    ]);
    expect(api.meCalls, 1, reason: '推送后就地更新快照, 不重拉 /auth/me');
  });

  test('同一个键推送在途时又改了: 以最后一次改动为准', () async {
    final (c, api) = await _boot();
    addTearDown(c.dispose);
    api.putDelay = const Duration(milliseconds: 400);

    final notifier = c.read(productionBoardSortProvider.notifier);
    notifier.update('deliveryDate');
    // 防抖 800ms 后开始推送, 推送耗时 400ms; 在途期间改成第二个值。
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    notifier.update('progress');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.read(productionBoardSortProvider), 'progress');

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(c.read(productionBoardSortProvider), 'progress');
    expect(
      api.server[ApiEndpoints.userPreference('productionBoard.sort')],
      'progress',
    );
  });

  test('同一身份重取快照(授权变化)时, 本地未确认的改动不被旧值覆盖', () async {
    final (c, api) = await _boot();
    addTearDown(c.dispose);

    c.read(instantInventoryPrefsProvider.notifier).update(true);
    // 防抖期内快照被重取(服务端仍是旧值 false)。
    await c.read(sessionSnapshotProvider.notifier).refresh();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(instantInventoryPrefsProvider), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(
      api.server[ApiEndpoints.userPreference('stock.instantInventory')],
      isTrue,
    );
    // 已推送确认后, 再重取快照拿到的就是服务端值, 照常采用。
    await c.read(sessionSnapshotProvider.notifier).refresh();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(instantInventoryPrefsProvider), isTrue);
  });
}
