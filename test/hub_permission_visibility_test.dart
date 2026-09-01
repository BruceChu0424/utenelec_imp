import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/features/warehouse/providers/warehouse_quality_result_count_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Widget _app(Widget page, Set<String> permissions) {
  return ProviderScope(
    overrides: [
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      warehouseQualityResultPendingCountProvider.overrideWith((ref) async => 0),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: page,
    ),
  );
}

void main() {
  testWidgets('purchase hub hides every page without its view permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const PurchaseHubPage(), const {Perm.purchaseRequestView}),
    );
    await tester.pump();

    expect(find.text('计划下达的采购申请'), findsOneWidget);
    expect(find.text('采购订货单'), findsNothing);
    expect(find.text('采购收货单'), findsNothing);
    expect(find.text('采购退货单'), findsNothing);
  });

  testWidgets('warehouse hub filters task centers, documents and queries', (
    tester,
  ) async {
    // 仅库存查看：三张任务中心、内部单据与报表全部隐藏，只留库存查询两张卡。
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockView}),
    );
    await tester.pump();

    expect(find.text('即时库存'), findsOneWidget);
    expect(find.text('货架目视化清单'), findsOneWidget);
    expect(find.text('出库任务中心'), findsNothing);
    expect(find.text('入库任务中心'), findsNothing);
    expect(find.text('生产领料任务中心'), findsNothing);
    expect(find.text('仓库调拨'), findsNothing);
    expect(find.text('盘点'), findsNothing);
    expect(find.text('委外成品退货单'), findsNothing);
    expect(find.text('委外损耗单'), findsNothing);

    // 库存单据查看：三张任务中心与调拨/盘点单据可见，其它出库等已并入任务中心
    // 不再是独立卡。
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.stockDocView}),
    );
    await tester.pump();
    expect(find.text('出库任务中心'), findsOneWidget);
    expect(find.text('入库任务中心'), findsOneWidget);
    expect(find.text('生产领料任务中心'), findsOneWidget);
    expect(find.text('仓库调拨'), findsOneWidget);
    expect(find.text('盘点'), findsOneWidget);
    expect(find.text('其它出库'), findsNothing);
    expect(find.text('产成品进仓'), findsNothing);
    expect(find.text('采购收货单'), findsNothing);
  });

  testWidgets('warehouse quality-result card follows either view permission', (
    tester,
  ) async {
    // 合并卡：两块仓库视图权限任一满足即可见。
    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.warehouseIqcStockInView}),
    );
    await tester.pump();
    expect(find.text('品质部检查结果'), findsOneWidget);

    await tester.pumpWidget(
      _app(const WarehouseHubPage(), const {Perm.warehouseIqcReturnView}),
    );
    await tester.pump();
    expect(find.text('品质部检查结果'), findsOneWidget);

    await tester.pumpWidget(_app(const WarehouseHubPage(), const {}));
    await tester.pump();
    expect(find.text('品质部检查结果'), findsNothing);
  });
}
