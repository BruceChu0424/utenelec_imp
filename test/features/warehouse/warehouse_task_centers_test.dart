// 仓库任务中心三页（2026-09-01 重组）的权限/分段/角标契约测试。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_draw_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_inbound_task_center_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_outbound_task_center_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_records_view.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_center_scaffold.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_view.dart';

import '../../helpers/badge_summary_fixture.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  Map<String, dynamic>? lastStockListQuery;
  Map<String, dynamic>? lastTaskListQuery;
  String? lastTaskDirection;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/stock/docs') {
      lastStockListQuery = Map<String, dynamic>.from(query ?? const {});
    }
    if (path == '/warehouse/task-center/inbound' ||
        path == '/warehouse/task-center/outbound') {
      lastTaskListQuery = Map<String, dynamic>.from(query ?? const {});
      lastTaskDirection = path.split('/').last;
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 0,
        'facets': {
          'status': <Map<String, dynamic>>[],
          'billNo': <Map<String, dynamic>>[],
        },
      };
    }
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
      route: RouteName.warehouseArrivalRegistration,
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
    int subcontractOutboundCount = 2,
    ApiClient? api,
  }) {
    return ProviderScope(
      overrides: [
        if (withDrafts) formDraftsProvider.overrideWith(_Drafts.new),
        apiClientProvider.overrideWithValue(api ?? _FakeApi()),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        // 分段数字随徽章汇总一次带回(ADR-108):
        // 销售出库待出库红徽章与父分类同数(5), 已出库中性括号(12);
        // 委外出库红数 = 待发料的委外领料单张数(ADR-143 §4.3), 没有黄数.
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            facts: {
              BadgeFact.warehouseSalesOutboundPendingPick: 5,
              BadgeFact.warehouseSalesOutboundShipped: 12,
              BadgeFact.productionDraw: 3,
              BadgeFact.productionReturn: 0,
              BadgeFact.subcontractOutbound: subcontractOutboundCount,
              BadgeFact.warehouseArrivalException: 0,
              BadgeFact.finishedInbound: 0,
              // ADR-149: 预计到货分来源也随汇总同步带回(与列表同一仓库范围)。这里给 0:
              // 有红数时进页面会默认选中该大类, 入库用例要验证的是「没红数不预选」。
              BadgeFact.warehouseInboundExpectation: 0,
              BadgeFact.warehouseInboundExpectationPurchase: 0,
              BadgeFact.warehouseInboundExpectationSubcontract: 0,
            },
          ),
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
        Perm.warehouseSubcontractOutboundHistoryView,
        Perm.stockDocView,
      ]);
      expect(
        requiredAnyPermFor('${RouteName.warehouseOutboundTasks}/x'),
        const [
          Perm.warehouseSalesOutboundView,
          Perm.subcontractOutboundView,
          Perm.warehouseSubcontractOutboundHistoryView,
          Perm.stockDocView,
        ],
      );
      expect(requiredAnyPermFor(RouteName.warehouseInboundTasks), const [
        Perm.warehouseInboundView,
        Perm.stockDocView,
        Perm.warehousePurchaseReceiptHistoryView,
        Perm.warehouseSubcontractReceiptHistoryView,
        Perm.warehouseIqcStockInView,
        Perm.warehouseIqcReturnView,
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
        Perm.warehouseSubcontractOutboundHistoryView,
        Perm.stockDocView,
        Perm.warehouseInboundView,
        Perm.warehousePurchaseReceiptHistoryView,
        Perm.warehouseSubcontractReceiptHistoryView,
        Perm.warehouseIqcStockInView,
        Perm.warehouseIqcReturnView,
        Perm.warehouseSubcontractFinishedReturnHistoryView,
      ]);
    });
  });

  group('merged warehouse task center (2026-09-24)', () {
    testWidgets('旧scWaste预设不恢复仓库损耗主分类，旧只读权限不扩到任务中心', (tester) async {
      await tester.pumpWidget(
        app(const WarehouseTaskCenterPage(initialGroup: 'scWaste'), {
          Perm.stockDocView,
          Perm.warehouseSubcontractWasteHistoryView,
        }),
      );
      await tester.pumpAndSettle();
      final groups = tester.widget<UtenFilterToolbar<String>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFilterToolbar<String> &&
              widget.segmentsKey == const Key('warehouse-task-center-groups'),
        ),
      );
      expect(
        groups.segments.any((segment) => segment.value == 'scWaste'),
        isFalse,
      );
      expect(find.text('委外损耗'), findsNothing);
      expect(
        requiredAnyPermFor(RouteName.warehouseTasks),
        isNot(contains(Perm.warehouseSubcontractWasteHistoryView)),
      );
      expect(requiredAnyPermFor(RouteName.warehouseSubcontractWasteHistory), [
        Perm.warehouseSubcontractWasteHistoryView,
      ]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('资料草稿与仓库单据草稿分别进入顶栏且不混数', (tester) async {
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
      expect(find.text('资料草稿'), findsOneWidget);
      expect(find.text('仓库草稿'), findsOneWidget);
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

      // 生产领料归出库来源，生产退料归入库来源，不再是第三个大类。
      expect(find.text('出库'), findsOneWidget);
      expect(find.text('入库'), findsOneWidget);
      expect(find.text('生产领料'), findsNothing);
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
      expect(find.text('生产领料'), findsOneWidget);
      expect(find.text('全部任务'), findsOneWidget);
      expect(find.text('历史单据'), findsOneWidget);
      // fixture 的生产领料红数为3，会按真实规则自动选中DRAW待办来源。
      expect(find.byType(WarehouseTaskRecordsView), findsOneWidget);
      expect(
        tester
            .widget<WarehouseTaskRecordsView>(
              find.byType(WarehouseTaskRecordsView),
            )
            .source,
        'DRAW',
      );
      expect(
        tester
            .widget<WarehouseTaskRecordsView>(
              find.byType(WarehouseTaskRecordsView),
            )
            .view,
        WarehouseTaskView.active,
      );
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
      // 来源共表且作业默认全部，不由徽章隐式限定来源或作业状态。
      expect(
        find.byKey(const Key('warehouse-quality-result-table')),
        findsOneWidget,
      );
      expect(find.text('在上方选择作业阶段后开始办理'), findsNothing);
      expect(
        find.byKey(const Key('warehouse-quality-result-type')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('旧draw深链归出库的生产领料来源', (tester) async {
      final api = _FakeApi();
      await tester.pumpWidget(
        app(const WarehouseTaskCenterPage(initialGroup: 'draw'), const {
          Perm.stockDocView,
        }, api: api),
      );
      await tester.pumpAndSettle();
      expect(find.text('待领任务'), findsNothing);
      expect(find.text('生产领料'), findsOneWidget);
      expect(find.byType(WarehouseTaskRecordsView), findsOneWidget);
      expect(api.lastTaskDirection, 'outbound');
      expect(api.lastTaskListQuery?['source'], 'DRAW');
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    testWidgets('旧draw退料深链归入库的生产退料来源', (tester) async {
      final api = _FakeApi();
      await tester.pumpWidget(
        app(
          const WarehouseTaskCenterPage(
            initialGroup: 'draw',
            initialSection: 'wdraw',
          ),
          {Perm.stockDocView},
          api: api,
        ),
      );
      await tester.pumpAndSettle();
      expect(api.lastTaskDirection, 'inbound');
      expect(api.lastTaskListQuery?['source'], 'RETURN');
      expect(find.text('生产退料'), findsOneWidget);
      expect(find.text('待领任务'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('outbound task center filters segments by permission', (
    tester,
  ) async {
    final api = _FakeApi();
    await tester.pumpWidget(
      app(const WarehouseOutboundTaskCenterPage(initialSection: 'ALL'), const {
        Perm.warehouseSalesOutboundView,
        Perm.stockDocView,
      }, api: api),
    );
    await tester.pump();

    expect(find.text('销售出库'), findsOneWidget);
    expect(find.text('其它出库'), findsOneWidget);
    expect(find.text('产成品出库'), findsOneWidget);
    // 无委外出仓权限：委外分段隐藏。
    expect(find.text('委外出库'), findsNothing);
    expect(find.text('生产领料'), findsOneWidget);
    final scaffold = tester.widget<WarehouseTaskCenterScaffold>(
      find.byType(WarehouseTaskCenterScaffold),
    );
    expect(scaffold.segments.map((segment) => segment.value), [
      'SALES',
      'DRAW',
      'OTHER',
      'FINISHED',
      'ALL',
      'HISTORY',
    ]);
    expect(scaffold.segments[scaffold.segments.length - 2].label, '全部任务');
    expect(scaffold.segments.last.label, '历史单据');

    // 来源直接查询进行中；历史是同一导航行入口，不增加第三层状态分类。
    await tester.tap(find.text('其它出库'));
    await tester.pump();
    await tester.pump();
    expect(find.text('新建其它出库'), findsNothing);
    expect(find.byType(WarehouseTaskRecordsView), findsOneWidget);
    expect(
      find.byKey(const Key('stock-doc-segment-status-OTHER_OUT')),
      findsNothing,
    );
    expect(find.text('历史单据'), findsOneWidget);
    expect(api.lastTaskListQuery?['source'], 'OTHER');
    expect(api.lastTaskListQuery?['view'], 'ACTIVE');
    await tester.tap(find.text('历史单据'));
    await tester.pumpAndSettle();
    final history = tester.widget<WarehouseTaskRecordsView>(
      find.byType(WarehouseTaskRecordsView),
    );
    expect(history.source, 'ALL');
    expect(history.view, WarehouseTaskView.history);
    expect(history.sources.keys, ['SALES', 'DRAW', 'OTHER', 'FINISHED']);
    expect(api.lastTaskListQuery?['source'], 'ALL');
    expect(api.lastTaskListQuery?['view'], 'HISTORY');
    expect(find.text('委外出库'), findsNothing);
    await tester.tap(find.text('其它出库'));
    await tester.pumpAndSettle();
    expect(api.lastTaskListQuery?['source'], 'OTHER');
    expect(api.lastTaskListQuery?['view'], 'ACTIVE');
    // 分段切换会触达 60s 轮询计数的重建，推进时钟排空再卸载页面。
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('outbound sales keeps one source badge and no third status row', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const WarehouseOutboundTaskCenterPage(), const {
        Perm.warehouseSalesOutboundView,
      }),
    );
    await tester.pump();
    await tester.pump();
    // 红数只在来源入口显示一次，记录阶段由统一状态表头承接。
    expect(find.text('待出库'), findsNothing);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('(12)'), findsNothing);
    expect(find.text('历史单据'), findsOneWidget);
    expect(find.text('(0)'), findsNothing);
    // 小类随红数自动选中并加载(不再有引导占位).
    expect(find.text('在上方选择分类后开始办理'), findsNothing);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('outbound subcontract segment carries only the red draft count', (
    tester,
  ) async {
    // 红 = 委外人员已提交、仓库还没发出的领料单张数; 等物料的委外任务在委外任务
    // 中心「领料」里, 仓库这边不再画黄枚(原「等子件到货」).
    await tester.pumpWidget(
      app(const WarehouseOutboundTaskCenterPage(), const {
        Perm.subcontractOutboundView,
      }),
    );
    await tester.pump();
    await tester.pump();
    // 2026-10-04 起红数大类「委外出库」自动选中：小类行随挂载出现。
    expect(find.text('委外出库'), findsOneWidget);
    expect(find.byType(UtenInProgressBadge), findsNothing);
    // 来源自动选中后直接显示统一表，不重复挂一枚状态分类红数。
    expect(find.text('待发料'), findsNothing);
    expect(find.text('待出仓任务'), findsNothing);
    expect(find.byType(UtenNotificationBadge), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'outbound subcontract segment draws nothing when no draft waits',
    (tester) async {
      await tester.pumpWidget(
        app(const WarehouseOutboundTaskCenterPage(), const {
          Perm.subcontractOutboundView,
        }, subcontractOutboundCount: 0),
      );
      await tester.pump();
      expect(find.text('委外出库'), findsOneWidget);
      expect(find.byType(UtenNotificationBadge), findsNothing);
      expect(find.byType(UtenInProgressBadge), findsNothing);
      expect(find.text('0'), findsNothing);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

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
    expect(find.byType(WarehouseTaskRecordsView), findsOneWidget);
    expect(
      find.byKey(const Key('stock-doc-segment-status-OTHER_OUT')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'inbound source row filters permissions and separates active from history',
    (tester) async {
      final api = _FakeApi();
      await tester.pumpWidget(
        app(const WarehouseInboundTaskCenterPage(), const {
          Perm.warehouseInboundView,
        }, api: api),
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

      // 来源后直接进进行中统一表；已办结单据由同一导航行历史入口承接。
      await tester.tap(find.text('采购入库'));
      await tester.pump();
      expect(find.text('预计到货'), findsNothing);
      expect(find.text('到货异常'), findsNothing);
      expect(find.text('收货历史'), findsNothing);
      expect(find.byType(WarehouseTaskRecordsView), findsOneWidget);
      final scaffold = tester.widget<WarehouseTaskCenterScaffold>(
        find.byType(WarehouseTaskCenterScaffold),
      );
      expect(scaffold.segments.map((segment) => segment.value), [
        'PURCHASE',
        'SUBCONTRACT',
        'ALL',
        'HISTORY',
      ]);
      expect(scaffold.segments[scaffold.segments.length - 2].label, '全部任务');
      expect(scaffold.segments.last.label, '历史单据');
      expect(api.lastTaskListQuery?['source'], 'PURCHASE');
      expect(api.lastTaskListQuery?['view'], 'ACTIVE');
      await tester.tap(find.text('历史单据'));
      await tester.pumpAndSettle();
      final history = tester.widget<WarehouseTaskRecordsView>(
        find.byType(WarehouseTaskRecordsView),
      );
      expect(history.source, 'ALL');
      expect(history.view, WarehouseTaskView.history);
      expect(history.sources.keys, ['PURCHASE', 'SUBCONTRACT']);
      expect(api.lastTaskListQuery?['source'], 'ALL');
      expect(api.lastTaskListQuery?['view'], 'HISTORY');
      expect(find.text('产成品入库'), findsNothing);
      expect(find.text('其它入库'), findsNothing);
    },
  );

  for (final permission in [
    Perm.warehouseIqcStockInView,
    Perm.warehouseIqcReturnView,
  ]) {
    testWidgets(
      'quality-only $permission retains both authorized inbound sources',
      (tester) async {
        await tester.pumpWidget(
          app(const WarehouseInboundTaskCenterPage(), {permission}),
        );
        await tester.pumpAndSettle();
        expect(find.text('采购入库'), findsOneWidget);
        expect(find.text('委外入库'), findsOneWidget);
        expect(find.text('产成品入库'), findsNothing);
        expect(find.text('其它入库'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('inbound source navigation does not infer a quality view grant', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const WarehouseInboundTaskCenterPage(), const <String>{}),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无已授权的入库单据'), findsOneWidget);
    expect(find.text('采购入库'), findsNothing);
    expect(find.text('委外入库'), findsNothing);
    expect(tester.takeException(), isNull);
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

  testWidgets('draw document progress filters through its table header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _FakeApi();
    await tester.pumpWidget(
      app(const WarehouseDrawTaskCenterPage(), const {
        Perm.stockDocView,
      }, api: api),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('领料单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-doc-segment-issue-DRAW')), findsNothing);
    MasterDataTableView<StockDocListItem> table() =>
        tester.widget(find.byKey(const Key('stock-doc-segment-table-DRAW')));
    expect(table().facets['issueStatus']?.map((bucket) => bucket.value), [
      '0',
      '1',
    ]);
    expect(api.lastStockListQuery?['view'], 'ACTIVE');
    table().onFilterChanged('issueStatus', '1');
    await tester.pumpAndSettle();
    expect(api.lastStockListQuery?['status'], 1);
    expect(api.lastStockListQuery?['issueStatus'], 1);
    expect(api.lastStockListQuery?['page'], 1);
    expect(table().filters['issueStatus'], '1');
    table().onFilterChanged('issueStatus', null);
    await tester.pumpAndSettle();
    expect(api.lastStockListQuery?.containsKey('issueStatus'), isFalse);
    await tester.tap(find.text('历史单据'));
    await tester.pumpAndSettle();
    expect(api.lastStockListQuery?['view'], 'HISTORY');
    expect(api.lastStockListQuery?.containsKey('status'), isFalse);
    expect(api.lastStockListQuery?.containsKey('issueStatus'), isFalse);
    expect(table().facets.containsKey('issueStatus'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
