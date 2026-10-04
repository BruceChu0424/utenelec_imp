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
import 'package:uten_imp/features/warehouse/pages/warehouse_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_draw_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_inbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_outbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/providers/procurement_inbound_count_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
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

class _Drafts extends FormDraftsNotifier {
  @override
  List<FormDraft> build() => [
    FormDraft(
      id: 'warehouse-draft',
      title: '新建仓库',
      module: BadgeModule.warehouse,
      route: '/basicinfo/warehouse',
      permission: Perm.warehouseView,
      updatedAt: DateTime(2026, 9, 30),
      data: const {},
    ),
    FormDraft(
      id: 'arrival-draft',
      title: '采购到货登记',
      module: BadgeModule.warehouse,
      route: RouteName.warehouseArrivalReceiptNew,
      permission: Perm.warehouseInboundView,
      updatedAt: DateTime(2026, 9, 30),
      data: const {},
    ),
  ];
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  Widget app(
    Widget page,
    Set<String> permissions, {
    bool withDrafts = false,
    ({int count, int waitingComponent}) subcontractCounts = (
      count: 2,
      waitingComponent: 0,
    ),
  }) {
    return ProviderScope(
      overrides: [
        if (withDrafts) formDraftsProvider.overrideWith(_Drafts.new),
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

  testWidgets('盘点审核快捷入口已退役，审核人从「车间内料仓」分类办理', (tester) async {
    await tester.pumpWidget(
      app(const WarehouseTaskCenterPage(), const {Perm.stockDocView}),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('warehouse-count-review-entry')), findsNothing);
    await tester.pumpWidget(
      app(const WarehouseTaskCenterPage(), const {
        Perm.stockCountWarehouseReview,
      }),
    );
    await tester.pumpAndSettle();
    // 2026-10-01 用户口径：右上角快捷按钮删除，盘点审核并入「车间内料仓」大类。
    expect(find.byKey(const Key('warehouse-count-review-entry')), findsNothing);
    expect(
      requiredAnyPermFor(RouteName.warehouseTasks),
      contains(Perm.stockCountWarehouseReview),
    );
    expect(find.text('车间内料仓'), findsOneWidget);
  });

  group('route permission contract', () {
    test('task centers accept any of their business view permissions', () {
      expect(requiredAnyPermFor(RouteName.warehouseOutboundTasks), const [
        Perm.warehouseSalesOutboundView,
        Perm.subcontractOutboundView,
        Perm.stockDocView,
      ]);
      expect(
        requiredAnyPermFor('${RouteName.warehouseOutboundTasks}/x'),
        const [
          Perm.warehouseSalesOutboundView,
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
      // 2026-09-24 合并页：六大类业务域任一可看即可进入（页内再按大类显隐）。
      expect(requiredAnyPermFor(RouteName.warehouseTasks), const [
        Perm.stockCountWarehouseReview,
        Perm.warehouseSalesOutboundView,
        Perm.subcontractOutboundView,
        Perm.stockDocView,
        Perm.warehouseInboundView,
        Perm.warehousePurchaseReceiptHistoryView,
        Perm.warehouseSubcontractReceiptHistoryView,
        Perm.warehouseIqcStockInView,
        Perm.warehouseIqcReturnView,
        Perm.warehouseSubcontractFinishedReturnHistoryView,
        Perm.warehouseSubcontractWasteHistoryView,
      ]);
    });
  });

  group('merged warehouse task center (2026-09-24)', () {
    testWidgets('资料草稿放顶栏，红数只计仓库资料范围', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        app(const WarehouseTaskCenterPage(), const {
          Perm.stockDocView,
          Perm.warehouseView,
        }, withDrafts: true),
      );
      await tester.pumpAndSettle();
      final button = find.byWidgetPredicate(
        (widget) =>
            widget is FormDraftsAppBarButton &&
            widget.categoryId == 'warehouse-master',
      );
      expect(button, findsOneWidget);
      expect(find.text('资料草稿'), findsNothing);
      expect(
        tester
            .widget<UtenNotificationBadge>(
              find.descendant(
                of: button,
                matching: find.byType(UtenNotificationBadge),
              ),
            )
            .count,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('大类按权限显隐，嵌入态复用子任务中心', (tester) async {
      await tester.pumpWidget(
        app(const WarehouseTaskCenterPage(), const {
          Perm.stockDocView,
          Perm.stockDocCreate,
        }),
      );
      await tester.pump();

      // 库存单据权限：出库/入库/生产领料三大类；品质与委外两类历史隐藏。
      expect(find.text('出库'), findsOneWidget);
      expect(find.text('入库'), findsOneWidget);
      expect(find.text('生产领料'), findsOneWidget);
      expect(find.text('品质检查结果'), findsNothing);
      expect(find.text('委外成品退货'), findsNothing);
      expect(find.text('委外损耗'), findsNothing);
      // 进页面不预选大类：引导空态，不发请求。
      expect(find.text('在上方选择分类后开始办理'), findsOneWidget);

      // 切到「出库」大类：嵌入的出库任务中心小类行出现（无销售出库权限 →
      // 只见其它/产成品出库两段）。
      await tester.tap(find.text('出库'));
      await tester.pump();
      await tester.pump();
      expect(find.text('销售出库'), findsNothing);
      expect(find.text('其它出库'), findsOneWidget);
      expect(find.text('产成品出库'), findsOneWidget);
      // 小类行同样默认不选：仍是引导占位。
      expect(find.text('在上方选择分类后开始办理'), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('品质查看权限解锁品质检查结果大类（原页嵌入）', (tester) async {
      await tester.pumpWidget(
        app(const WarehouseTaskCenterPage(), const {
          Perm.warehouseIqcStockInView,
        }),
      );
      await tester.pump();
      expect(find.text('品质检查结果'), findsOneWidget);

      await tester.tap(find.text('品质检查结果'));
      await tester.pump();
      await tester.pump();
      // 嵌入的品质结果页保留自己的来源行（进页面不选来源）。
      expect(find.text('在上方选择来源和状态后开始办理'), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('深链 initialGroup 预设大类', (tester) async {
      await tester.pumpWidget(
        app(const WarehouseTaskCenterPage(initialGroup: 'draw'), const {
          Perm.stockDocView,
        }),
      );
      await tester.pump();
      // 预选生产领料大类：直接见到领料小类行，不再是引导空态。
      expect(find.text('待领任务'), findsOneWidget);
      expect(find.text('领料单'), findsOneWidget);
      expect(find.text('生产退料'), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('outbound task center filters segments by permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const WarehouseOutboundTaskCenterPage(), const {
        Perm.warehouseSalesOutboundView,
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
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('stock-doc-segment-status-OTHER_OUT')),
        matching: find.text('草稿'),
      ),
    );
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
        Perm.warehouseSalesOutboundView,
      }),
    );
    await tester.pump();
    await tester.pump();
    // 2026-10-04 起红数大类「销售出库」自动选中：小类行随挂载出现并自动选中。
    // 2026-09-20 用户口径: 父分类有红徽章, 小类也要有数——待出库红徽章与父分类
    // 同源同数(第二个「5」), 已出库中性括号数, 历史单据不挂(已出库本身是历史).
    expect(find.text('待出库'), findsOneWidget);
    expect(find.text('5'), findsNWidgets(2));
    expect(find.text('(12)'), findsOneWidget);
    expect(find.text('历史单据'), findsOneWidget);
    expect(find.text('(0)'), findsNothing);
    // 小类随红数自动选中并加载(不再有引导占位).
    expect(find.text('在上方选择分类后开始办理'), findsNothing);
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
    await tester.pump();
    // 2026-10-04 起黄数大类「委外出库」自动选中(无红看黄)：小类行随挂载出现。
    expect(find.text('委外出库'), findsOneWidget);
    expect(find.byType(UtenNotificationBadge), findsNothing);
    expect(find.text('0'), findsNothing);

    // 小类行「待出仓任务」与父分类同源同数: 黄枚再画一次, 仍没有红枚.
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
    await tester.pump();
    // 2026-10-04 起红数大类「委外出库」自动选中，小类行随之出现——两枚徽章各
    // 画两处(父分类 + 小类)。黄左红右(与 hub 卡右上角同序)在父分类栏内断言。
    final mainBar = find.byKey(
      const Key('warehouse-task-center-segments-出库任务中心'),
    );
    expect(find.byType(UtenInProgressBadge), findsNWidgets(2));
    expect(find.byType(UtenNotificationBadge), findsNWidgets(2));
    expect(find.text('3'), findsNWidgets(2));
    expect(find.text('2'), findsNWidgets(2));
    final yellow = tester.getTopLeft(
      find.descendant(of: mainBar, matching: find.byType(UtenInProgressBadge)),
    );
    final red = tester.getTopLeft(
      find.descendant(
        of: mainBar,
        matching: find.byType(UtenNotificationBadge),
      ),
    );
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
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('stock-doc-segment-status-OTHER_OUT')),
        matching: find.text('草稿'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('新建其它出库'), findsNothing);
    await tester.tap(find.text('已审'));
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
    // 2026-10-04 起红数「待领任务」大类自动选中：直接渲染对应内容，不再有
    // 引导空态（无红黄的权限组合才保持空态）。
    expect(find.text('在上方选择分类后开始办理'), findsNothing);

    await tester.pumpWidget(
      app(const WarehouseDrawTaskCenterPage(), const <String>{}),
    );
    await tester.pump();
    expect(find.text('暂无库存单据查看权限，请联系仓库主管开通。'), findsOneWidget);
  });
}
