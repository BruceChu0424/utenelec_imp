// 仓库任务中心三页（2026-09-01 重组）的权限/分段/角标契约测试。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_draw_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_inbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_outbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/providers/procurement_inbound_count_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    // 列表端点回空页；其余端点回空对象（页面各自 catch 后显示空态/降级）。
    if (path == '/stock/docs' ||
        path == '/warehouse/sales-outbound' ||
        path == '/warehouse/inbound/expectations' ||
        path == '/warehouse/production-finished-in/tasks') {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{};
  }
}

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  Widget app(
    Widget page,
    Set<String> permissions, {
    ({int count, int waitingComponent}) subcontractCounts = (
      count: 2,
      waitingComponent: 0,
    ),
  }) {
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_FakeApi()),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        // 分段数字随徽章汇总一次带回(ADR-108):
        // 销售出库待出库红徽章与父分类同数(5), 已出库中性括号(12);
        // 委外待出仓红黄两数同出一个来源(ADR-103): 红 = 可出仓 / 黄 = 等子件到货.
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            facts: {
              BadgeFact.warehouseSalesOutboundPendingPick: 5,
              BadgeFact.warehouseSalesOutboundShipped: 12,
              BadgeFact.productionDraw: 3,
              BadgeFact.productionReturn: 0,
              BadgeFact.subcontractOutbound: subcontractCounts.count,
              BadgeFact.subcontractOutboundWaitingComponent:
                  subcontractCounts.waitingComponent,
              BadgeFact.warehouseArrivalException: 0,
              BadgeFact.finishedInbound: 0,
            },
          ),
        ),
        warehouseInboundExpectationTypeCountsProvider.overrideWith(
          (ref) async => const {'PURCHASE': 2, 'SUBCONTRACT': 1},
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: page,
      ),
    );
  }

  group('route permission contract', () {
    test('task centers accept any of their business view permissions', () {
      expect(requiredAnyPermFor(RouteName.warehouseOutboundTasks), const [
        Perm.salesShipmentWarehouseWork,
        Perm.subcontractOutboundView,
        Perm.stockDocView,
      ]);
      expect(
        requiredAnyPermFor('${RouteName.warehouseOutboundTasks}/x'),
        const [
          Perm.salesShipmentWarehouseWork,
          Perm.subcontractOutboundView,
          Perm.stockDocView,
        ],
      );
      expect(requiredAnyPermFor(RouteName.warehouseInboundTasks), const [
        Perm.warehouseInboundView,
        Perm.stockDocView,
        Perm.warehousePurchaseReceiptHistoryView,
        Perm.warehouseSubcontractReceiptHistoryView,
      ]);
      expect(requiredAnyPermFor(RouteName.warehouseDrawTasks), const [
        Perm.stockDocView,
      ]);
      // 库存详情与库存查询同权（/stock/ 前缀 → stock:view）。
      expect(requiredAnyPermFor(RouteName.stockItemDetail('goods-1')), const [
        Perm.stockView,
      ]);
      // 任务中心静态段不能落入 /warehouse/:code 单据回退：未知子段 fail-closed
      //（返回空列表 → 路由守卫送 notFound）。
      expect(requiredAnyPermFor('/warehouse/tasks/unknown'), isEmpty);
    });
  });

  testWidgets('outbound task center filters segments by permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const WarehouseOutboundTaskCenterPage(), const {
        Perm.salesShipmentWarehouseWork,
        Perm.stockDocView,
      }),
    );
    await tester.pump();

    expect(find.text('销售出库'), findsOneWidget);
    expect(find.text('其它出库'), findsOneWidget);
    expect(find.text('产成品出库'), findsOneWidget);
    // 无委外出仓权限：委外分段隐藏。
    expect(find.text('委外出库'), findsNothing);
    // 进页面不预选大类：内容区为引导空态，不加载任何分段数据。
    expect(find.text('在上方选择分类后开始办理'), findsOneWidget);

    // 切到「其它出库」：不再渲染 icon+标题分段头；小类行（草稿/已审/红冲/
    // 历史单据）同样默认不选，内容区仍是引导空态（不发请求）；总结行在
    // 全部分类栏最下方（总数文案 + 新建按钮按 stock_doc:create 门控）。
    await tester.tap(find.text('其它出库'));
    await tester.pump();
    await tester.pump();
    expect(find.text('新建其它出库'), findsNothing);
    expect(find.text('在上方选择分类后开始办理'), findsOneWidget);
    // 2026-09-03 分类范式：先选小类段（如「草稿」）才加载列表与「共 N 条」总结。
    await tester.tap(find.text('草稿'));
    await tester.pump();
    await tester.pump();
    expect(find.text('共 0 条 · 双击办理'), findsOneWidget);
    // 分段切换会触达 60s 轮询计数的重建，推进时钟排空再卸载页面。
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('outbound sales sub-segments carry counts like the parent', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const WarehouseOutboundTaskCenterPage(), const {
        Perm.salesShipmentWarehouseWork,
      }),
    );
    await tester.pump();
    // 父分类「销售出库」红徽章 = 5(待出库张数).
    expect(find.text('5'), findsOneWidget);

    await tester.tap(find.text('销售出库'));
    await tester.pump();
    await tester.pump();
    // 2026-09-20 用户口径: 父分类有红徽章, 小类也要有数——待出库红徽章与父分类同源
    // 同数(第二个「5」), 已出库中性括号数, 历史单据不挂(已出库本身就是历史).
    expect(find.text('待出库'), findsOneWidget);
    expect(find.text('5'), findsNWidgets(2));
    expect(find.text('(12)'), findsOneWidget);
    expect(find.text('历史单据'), findsOneWidget);
    expect(find.text('(0)'), findsNothing);
    // 小类默认不选: 仍是引导占位, 不发列表请求.
    expect(find.text('在上方选择分类后开始办理'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('outbound subcontract segment carries red and yellow badges', (
    tester,
  ) async {
    // 红 0 黄 1: 委外单财务批准后子件一件没到, 红角标按 ADR-101 不计——此前分段
    // 上什么都不显示(用户 2026-09-22 截图); 现在黄枚单独画出来, 红枚不画 0.
    await tester.pumpWidget(
      app(
        const WarehouseOutboundTaskCenterPage(),
        const {Perm.subcontractOutboundView},
        subcontractCounts: (count: 0, waitingComponent: 1),
      ),
    );
    await tester.pump();
    expect(find.text('委外出库'), findsOneWidget);
    expect(find.byType(UtenInProgressBadge), findsOneWidget);
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('0'), findsNothing);

    // 小类行「待出仓任务」与父分类同源同数: 黄枚再画一次, 仍没有红枚.
    await tester.tap(find.text('委外出库'));
    await tester.pump();
    await tester.pump();
    expect(find.text('待出仓任务'), findsOneWidget);
    expect(find.byType(UtenInProgressBadge), findsNWidgets(2));
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.text('1'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('outbound subcontract segment draws both badges when both > 0', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const WarehouseOutboundTaskCenterPage(),
        const {Perm.subcontractOutboundView},
        subcontractCounts: (count: 2, waitingComponent: 3),
      ),
    );
    await tester.pump();
    // 黄左红右(与 hub 卡右上角同序), 两枚互斥不重叠.
    expect(find.byType(UtenInProgressBadge), findsOneWidget);
    expect(find.byType(UtenNotificationBadge), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    final yellow = tester.getTopLeft(find.byType(UtenInProgressBadge));
    final red = tester.getTopLeft(find.byType(UtenNotificationBadge));
    expect(yellow.dx, lessThan(red.dx));
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('outbound generic segment offers create with permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const WarehouseOutboundTaskCenterPage(), const {
        Perm.stockDocView,
        Perm.stockDocCreate,
      }),
    );
    await tester.pump();
    await tester.tap(find.text('其它出库'));
    await tester.pump();
    await tester.pump();
    expect(find.text('新建其它出库'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('inbound task center filters segments and sub-modes', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const WarehouseInboundTaskCenterPage(), const {
        Perm.warehouseInboundView,
      }),
    );
    await tester.pump();

    expect(find.text('采购入库'), findsOneWidget);
    expect(find.text('委外入库'), findsOneWidget);
    // 无库存单据权限：产成品/其它入库分段隐藏。
    expect(find.text('产成品入库'), findsNothing);
    expect(find.text('其它入库'), findsNothing);
    // 进页面不预选大类：小类行只随选中的大类出现（大类未选时小类锁定）。
    expect(find.text('在上方选择分类后开始办理'), findsOneWidget);
    expect(find.text('预计到货'), findsNothing);

    // 选中「采购入库」后小类行出现：预计到货 / 到货异常；收货历史需历史查看权限。
    await tester.tap(find.text('采购入库'));
    await tester.pump();
    expect(find.text('预计到货'), findsOneWidget);
    expect(find.text('到货异常'), findsOneWidget);
    expect(find.text('收货历史'), findsNothing);
  });

  testWidgets('draw task center gates on stock doc view', (tester) async {
    await tester.pumpWidget(
      app(const WarehouseDrawTaskCenterPage(), const {Perm.stockDocView}),
    );
    await tester.pump();

    expect(find.text('待领任务'), findsOneWidget);
    expect(find.text('领料单'), findsOneWidget);
    expect(find.text('生产退料'), findsOneWidget);
    // 进页面不预选大类：内容区为引导空态。
    expect(find.text('在上方选择分类后开始办理'), findsOneWidget);

    await tester.pumpWidget(
      app(const WarehouseDrawTaskCenterPage(), const <String>{}),
    );
    await tester.pump();
    expect(find.text('暂无库存单据查看权限，请联系仓库主管开通。'), findsOneWidget);
  });
}
