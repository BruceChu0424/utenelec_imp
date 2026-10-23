import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_status_repository.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

final _testPermissionsProvider =
    NotifierProvider<_TestPermissions, Set<String>>(_TestPermissions.new);

class _TestPermissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void replace(Set<String> permissions) => state = permissions;
}

class _GoodsRepository extends Fake implements GoodsRepository {
  @override
  Future<GoodsDetail> detail(String id) async => const GoodsDetail(
    id: 'goods-1',
    code: 'P-001',
    name: '测试货品',
    status: '使用',
    sourceType: '自制',
  );
}

class _BomRepository extends Fake implements GoodsBomRepository {
  @override
  Future<List<GoodsBomItem>> list(String goodsId) async => const [];
}

class _StatusRepository extends Fake implements MasterStatusRepository {
  String status = '使用';
  int changes = 0;
  @override
  Future<void> change({
    required String resourcePath,
    required String status,
    int? version,
  }) async {
    changes++;
    this.status = status;
  }
}

class _StatusGoodsRepository extends Fake implements GoodsRepository {
  _StatusGoodsRepository(this.status);
  final _StatusRepository status;
  @override
  Future<GoodsDetail> detail(String id) async => GoodsDetail(
    id: id,
    name: '确认停用货品',
    code: 'QA001',
    status: status.status,
    sourceType: '采购',
    writable: true,
    version: 1,
  );
}

void main() {
  testWidgets('停用先确认，取消零请求，停用后切换启用样式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final status = _StatusRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'goods-test'),
          ),
          apiClientProvider.overrideWithValue(ApiClient(Dio())),
          currentPermissionsProvider.overrideWithValue({
            Perm.goodsView,
            Perm.goodsStatus,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          goodsRepositoryProvider.overrideWithValue(
            _StatusGoodsRepository(status),
          ),
          masterStatusRepositoryProvider.overrideWithValue(status),
          colorDictProvider.overrideWith((ref) async => const []),
          unitDictProvider.overrideWith((ref) async => const []),
          localServerReachableProvider.overrideWith(
            (ref) => LocalServerReachabilityNotifier(null, web: true),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: GoodsDetailPage(goodsId: 'qa-status'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('goods-detail-toggle-status'));
    expect(tester.widget<UtenButton>(toggle).type, UtenButtonType.danger);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(status.changes, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(status.changes, 0);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(status.changes, 1);
    expect(find.text('启用'), findsOneWidget);
    expect(tester.widget<UtenButton>(toggle).type, UtenButtonType.secondary);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'BOM entry requires edit permission and creation stays behind edit mode',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final container = ProviderContainer(
        overrides: [
          sensitiveReadBoundaryProvider.overrideWith(
            (ref) => SensitiveReadBoundary(
              identity: const AuthenticatedScope(userId: 'goods-test'),
              api: ApiClient(Dio()),
              permissions: ref.watch(currentPermissionsProvider),
              superAdmin: false,
            ),
          ),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(_testPermissionsProvider),
          ),
          isSuperAdminProvider.overrideWithValue(false),
          goodsRepositoryProvider.overrideWithValue(_GoodsRepository()),
          goodsBomRepositoryProvider.overrideWithValue(_BomRepository()),
          colorDictProvider.overrideWith((ref) async => const []),
          unitDictProvider.overrideWith((ref) async => const []),
          // 详情页挂链会同步拉起 apiBaseUrl → 本地可达性探针的 60s 周期定时器，
          // 假时钟收尾必炸；web: true 不起探针（仓库既有口径）。
          localServerReachableProvider.overrideWith(
            (ref) => LocalServerReachabilityNotifier(null, web: true),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: GoodsDetailPage(goodsId: 'goods-1', initialTab: 'bom'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      container.read(_testPermissionsProvider.notifier).replace({
        Perm.goodsView,
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);

      container.read(_testPermissionsProvider.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomCreate,
      });
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(find.byKey(const Key('goods-bom-edit-mode')), findsNothing);

      container.read(_testPermissionsProvider.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomCreate,
        Perm.goodsBomEdit,
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-edit-mode')), findsOneWidget);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);

      container.read(_testPermissionsProvider.notifier).replace({
        Perm.goodsView,
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
    },
  );
}
