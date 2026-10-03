import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import 'helpers/badge_summary_fixture.dart';

Widget _app(Widget page, Set<String> permissions, {BadgeSummary? badges}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_preferences),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      // 徽章数字只有一个源头(汇总), 固定成空汇总即不发任何计数请求。
      fixedBadgeSummaryOverride(badges),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: page,
    ),
  );
}

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets('purchase hub hides every page without its view permission', (
    tester,
  ) async {
    // 2026-09-24 三段式：申请只读卡已撤、单据卡 creator-only 带新建前缀；
    // 仅申请查看权限的人新建区全隐藏（浏览在任务中心）。
    await tester.pumpWidget(
      _app(const PurchaseHubPage(), const {Perm.purchaseRequestView}),
    );
    await tester.pumpAndSettle();

    expect(find.text('任务中心'), findsOneWidget);
    expect(find.text('计划下达的采购申请'), findsNothing);
    expect(find.text('新建采购订货单'), findsNothing);
    expect(find.text('新建采购收货单'), findsNothing);
    expect(find.text('新建采购退货单'), findsNothing);
  });

  testWidgets('warehouse hub filters task centers, documents and queries', (
    tester,
  ) async {
    // 仅库存查看：任务中心、新建区与报表全部隐藏，只留库存查询三张卡
    // (ADR-135 称重计数随 stock:view；库存分析是管理口径，要 stock_report:view)。
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockView}),
    );
    await tester.pumpAndSettle();

    expect(find.text('即时库存'), findsOneWidget);
    expect(find.text('货架目视化清单'), findsOneWidget);
    expect(find.text('称重计数'), findsOneWidget);
    expect(find.text('库存分析'), findsNothing);
    expect(find.text('仓库任务中心'), findsNothing);
    expect(find.text('新建调拨单'), findsNothing);
    expect(find.text('新建盘点单'), findsNothing);

    // 2026-09-24 合并：库存单据查看 = 任务中心一张卡 + 新建区六卡（creator 另需
    // stock_doc:create；本用例只给 view，新建卡守卫含 create 故隐藏）。
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockDocView}),
    );
    await tester.pumpAndSettle();
    expect(find.text('仓库任务中心'), findsOneWidget);
    expect(find.text('新建调拨单'), findsNothing);
    expect(find.text('新建盘点单'), findsNothing);
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {
        Perm.stockDocView,
        Perm.stockDocCreate,
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('新建调拨单'), findsOneWidget);
    expect(find.text('新建盘点单'), findsOneWidget);
    expect(find.text('新建其它出库'), findsOneWidget);
    expect(find.text('采购收货单'), findsNothing);
  });

  testWidgets('审核角色各自有入口，旧调整权限不暴露新盘点审核', (tester) async {
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockBalanceAdjust}),
    );
    await tester.pumpAndSettle();
    expect(find.text('车间内料仓盘点审核'), findsNothing);
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockCountWarehouseReview}),
    );
    await tester.pumpAndSettle();
    expect(find.text('车间内料仓盘点审核'), findsNothing);
    expect(find.text('仓库任务中心'), findsOneWidget);
    await tester.pumpWidget(
      _app(const FinanceHubPage(), const {Perm.stockCountFinanceReview}),
    );
    await tester.pumpAndSettle();
    expect(find.text('普通仓盘点审核'), findsOneWidget);
  });

  testWidgets('仓库任务中心只有统一待办徽章，进行中不重复相加', (tester) async {
    await tester.pumpWidget(
      _app(
        const WarehouseHubPage(),
        const {Perm.stockCountWarehouseReview},
        badges: badgeSummaryFixture(
          entries: {
            BadgeEntry.warehouseStockCountReview: (1, 0),
            BadgeEntry.warehouseWorkshopMaterial: (0, 1),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byWidgetPredicate(
      (widget) => widget is UtenHubCard && widget.label == '仓库任务中心',
    );
    expect(card, findsOneWidget);
    final badge = find.descendant(
      of: card,
      matching: find.byType(UtenNotificationBadge),
    );
    expect(badge, findsOneWidget);
    expect(tester.widget<UtenNotificationBadge>(badge).count, 1);
    expect(
      find.descendant(of: card, matching: find.byType(UtenInProgressBadge)),
      findsNothing,
    );
    expect(find.text('车间内料仓盘点审核'), findsNothing);
  });

  testWidgets('warehouse insights card follows the stock report permission', (
    tester,
  ) async {
    // 库存分析 (ADR-135) 与仓库报表同权：只持 stock_report:view 也能看到这张卡。
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockReportView}),
    );
    await tester.pumpAndSettle();
    expect(find.text('库存分析'), findsOneWidget);
    expect(find.text('称重计数'), findsNothing);
    expect(find.text('即时库存'), findsNothing);
  });

  testWidgets('warehouse quality-result card follows either view permission', (
    tester,
  ) async {
    // 2026-09-24 合并页：品质检查结果并入「仓库任务中心」一张卡，
    // 两块仓库视图权限任一满足即可见。
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.warehouseIqcStockInView}),
    );
    await tester.pumpAndSettle();
    expect(find.text('仓库任务中心'), findsOneWidget);

    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.warehouseIqcReturnView}),
    );
    await tester.pumpAndSettle();
    expect(find.text('仓库任务中心'), findsOneWidget);

    await tester.pumpWidget(_app(const WarehouseHubPage(), const {}));
    await tester.pumpAndSettle();
    expect(find.text('仓库任务中心'), findsNothing);
  });
}
