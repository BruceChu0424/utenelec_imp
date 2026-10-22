import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_merged_table.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/uten_page_prefs_notifier.dart';

const _tableKey =
    'features.warehouse.widgets.warehouse_quality_merged_table.WarehouseQualityMergedTable.build.1';
const _server = 'https://unit.test/api';
const _singleOrder = [
  'verdict',
  'supplier',
  'goods',
  'goodsCode',
  'colorName',
  'remaining',
  'warehouse',
  'place',
  'received',
  'passed',
  'failed',
  'expectedAllocation',
  'release',
];

class _NoSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _Fixture {
  _Fixture(this.preferences, this.cacheKey)
    : container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue(_server),
          sharedPreferencesProvider.overrideWithValue(preferences),
          sessionSnapshotProvider.overrideWith(_NoSnapshot.new),
        ],
      );

  final SharedPreferences preferences;
  final String cacheKey;
  final ProviderContainer container;
  final projection = TableColumnProjectionController();
  final rows = UtenEditableGridController<WarehouseQualityMergedRow>(
    initial: [
      WarehouseQualityMergedRow(
        line: const WarehouseQualityInspectionLine(
          inspectionItemId: 'inspection-a',
          goodsId: 'goods-a',
          goodsName: '塑胶件',
          receivedBaseQty: 10,
          passedBaseQty: 10,
          failedBaseQty: 0,
          warehouseStockedBaseQty: 10,
          pendingStockBaseQty: 0,
          lineStatus: 'DONE',
        ),
        receiptNo: 'RCPT-1',
        receiptTypeLabel: '采购收货',
        supplierName: '供应商甲',
      ),
    ],
  );

  static Future<_Fixture> create(PlatformTableLayout seed) async {
    final prefKey = 'platform.table.${platformTableFingerprint(_tableKey)}';
    final cacheKey = scopedPagePreferenceCacheKey(
      'page_prefs_cache_${prefKey}_anonymous_self',
      _server,
      null,
    );
    SharedPreferences.setMockInitialValues({
      cacheKey: jsonEncode(seed.toJson()),
    });
    return _Fixture(await SharedPreferences.getInstance(), cacheKey);
  }

  Future<void> pump(WidgetTester tester, {required bool batch}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: TableColumnProjectionScope(
              controller: projection,
              child: ListView(
                children: [
                  WarehouseQualityMergedTable(
                    key: ValueKey(batch),
                    controller: rows,
                    editable: false,
                    saving: false,
                    showReceipt: batch,
                    onChanged: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<TableProjectedColumn> get columns =>
      projection.resolve(_tableKey)!.columns;
  List<String?> get order => columns.map((column) => column.sourceKey).toList();
  PlatformTableLayout get stored =>
      container.read(platformTableLayoutProvider(_tableKey));

  void dispose() {
    container.dispose();
    projection.dispose();
    rows.dispose();
  }
}

Finder _headerGrip(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenColumnResizeHandle && widget.label == label,
);

void main() {
  Future<_Fixture> setup(
    WidgetTester tester,
    PlatformTableLayout layout,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await _Fixture.create(layout);
    addTearDown(fixture.dispose);
    return fixture;
  }

  testWidgets('单页旧缓存缺少收货单列时，批量页将其接在判定之后且保留偏好', (tester) async {
    const saved = PlatformTableLayout(
      order: _singleOrder,
      hidden: {'goodsCode'},
      widths: {'goods': 285, 'warehouse': 210},
    );
    final fixture = await setup(tester, saved);
    await fixture.pump(tester, batch: false);
    expect(fixture.order, isNot(contains('receipt')));
    expect(fixture.order.take(2), ['verdict', 'supplier']);
    await fixture.pump(tester, batch: true);
    await fixture.pump(tester, batch: true);
    expect(fixture.order.take(3), ['verdict', 'receipt', 'supplier']);
    expect(
      tester.getTopLeft(_headerGrip('判定结果')).dx,
      lessThan(tester.getTopLeft(_headerGrip('来源收货单')).dx),
    );
    expect(
      tester.getTopLeft(_headerGrip('来源收货单')).dx,
      lessThan(tester.getTopLeft(_headerGrip('供应商 / 委外商')).dx),
    );
    expect(fixture.order, isNot(contains('goodsCode')));
    expect(
      fixture.columns
          .singleWhere((column) => column.sourceKey == 'goods')
          .width,
      285,
    );
    expect(fixture.stored.toJson(), saved.toJson());
    expect(
      jsonDecode(fixture.preferences.getString(fixture.cacheKey)!),
      saved.toJson(),
    );
    expect(tester.takeException(), isNull);
  });

  for (final hiddenReceipt in [false, true]) {
    testWidgets('已有收货单列自定义位置、列宽和显隐保持 $hiddenReceipt', (tester) async {
      final order = [
        'goods',
        'verdict',
        'supplier',
        'receipt',
        ..._singleOrder.where(
          (key) => !{'goods', 'verdict', 'supplier'}.contains(key),
        ),
      ];
      final saved = PlatformTableLayout(
        order: order,
        hidden: {'colorName', if (hiddenReceipt) 'receipt'},
        widths: const {'receipt': 320, 'goods': 275},
      );
      final fixture = await setup(tester, saved);
      await fixture.pump(tester, batch: false);
      await fixture.pump(tester, batch: true);
      await fixture.pump(tester, batch: true);
      expect(
        fixture.order,
        order.where((key) => !saved.hidden.contains(key)).toList(),
      );
      if (hiddenReceipt) {
        expect(find.text('来源收货单'), findsNothing);
      } else {
        expect(
          fixture.columns
              .singleWhere((column) => column.sourceKey == 'receipt')
              .width,
          320,
        );
        expect(fixture.order.take(4), [
          'goods',
          'verdict',
          'supplier',
          'receipt',
        ]);
      }
      expect(fixture.stored.toJson(), saved.toJson());
      expect(
        jsonDecode(fixture.preferences.getString(fixture.cacheKey)!),
        saved.toJson(),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
