import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/widgets/sales_plan_progress_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  final contract =
      jsonDecode(
            File(
              'contracts/sales-preparation-progress/v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cases = (contract['cases'] as List).cast<Map<String, dynamic>>();

  test(
    'shared preparation facts survive without adding manufacturing again',
    () {
      for (final row in cases) {
        final line = _line(row);
        expect(
          line.preparation!.targetQty,
          num.parse(row['target'] as String),
          reason: row['name'] as String,
        );
        expect(
          line.preparation!.preparedQty,
          num.parse(row['prepared'] as String),
          reason: row['name'] as String,
        );
        expect(line.preparation!.stockQty, num.parse(row['stock'] as String));
        expect(
          line.preparation!.sources.map((source) => (source.kind, source.qty)),
          (row['sources'] as List).cast<Map<String, dynamic>>().map(
            (source) => (source['kind'] as String, source['qty'] as num),
          ),
        );
      }
      final writtenOff = _line(
        cases.singleWhere(
          (row) => row['name'] == 'all_written_off_has_no_prepared_goods',
        ),
      );
      expect(writtenOff.preparation!.complete, isFalse);
      final legacy = OrderPlanProgressLine.fromJson({
        'orderItemId': 'old-server',
      });
      expect(legacy.preparation, isNull);
      expect(legacy.materialAnalyses, isEmpty);
    },
  );

  for (final (name, ratio) in [
    ('subcontract_qualified_20', 1.0),
    ('production_stock_not_added_twice', 1.0),
    ('returned_to_public_stock_requires_replacement', 0.85),
  ]) {
    testWidgets('$name displays the authoritative preparation ratio', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final line = _line(cases.singleWhere((row) => row['name'] == name));
      await _pump(tester, line);
      final tableFinder = find.byKey(const Key('sales-product-progress-table'));
      final table = tester.widget<MasterDataTableView<OrderPlanProgressLine>>(
        tableFinder,
      );
      expect(table.columns.first.label, '备货进度');
      final bars = tester.widgetList<LinearProgressIndicator>(
        find.descendant(
          of: tableFinder,
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(bars, isNotEmpty);
      expect(bars.map((bar) => bar.value), everyElement(closeTo(ratio, 1e-9)));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow view preserves each analysis lifecycle and quantities', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final line = OrderPlanProgressLine.fromJson({
      'orderItemId': 'multiple-analyses',
      'goodsName': '分批分析成品',
      'qty': 20,
      'materialAnalyses': [
        {
          'analysisId': 'active',
          'status': 'ACTIVE',
          'requestedQty': 20,
          'rootFulfilledQty': 8,
          'submittedQty': 4,
          'approvedQty': 1,
          'remainingQty': 7,
        },
        {
          'analysisId': 'completed',
          'status': 'COMPLETED',
          'requestedQty': 7,
          'rootFulfilledQty': 0,
          'submittedQty': 0,
          'approvedQty': 7,
          'remainingQty': 0,
        },
        {
          'analysisId': 'cancelled',
          'status': 'CANCELLED',
          'requestedQty': 9,
          'rootFulfilledQty': 0,
          'submittedQty': 0,
          'approvedQty': 0,
          'remainingQty': 9,
        },
      ],
    });
    expect(line.materialAnalyses.map((analysis) => analysis.analysisId), [
      'active',
      'completed',
      'cancelled',
    ]);
    await _pump(tester, line);
    expect(find.text('已提交待批准'), findsOneWidget);
    expect(find.text('物料分析已完成'), findsOneWidget);
    expect(find.text('物料分析已取消'), findsOneWidget);
    expect(find.text('分析 20 · 已承接 8 · 已提交 4 · 已批准 1 · 待下达 7'), findsOneWidget);
    expect(find.text('分析 7 · 已承接 0 · 已提交 0 · 已批准 7 · 待下达 0'), findsOneWidget);
    expect(find.text('分析 9 · 已承接 0 · 已提交 0 · 已批准 0 · 待下达 9'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

OrderPlanProgressLine _line(
  Map<String, dynamic> row,
) => OrderPlanProgressLine.fromJson({
  'orderItemId': row['name'],
  'goodsName': '备货成品',
  'qty': num.parse(row['qty'] as String),
  // Historical manufacturing is intentionally unrelated to physical preparation.
  'producedQty': 999,
  'preparation': {
    'targetQty': num.parse(row['target'] as String),
    'preparedQty': num.parse(row['prepared'] as String),
    'stockQty': num.parse(row['stock'] as String),
    'netShippedQty': 0,
    'sources': row['sources'],
  },
});

Future<void> _pump(WidgetTester tester, OrderPlanProgressLine line) async {
  final scope = SalesShipmentActionScope();
  addTearDown(scope.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        salesRepositoryProvider(
          SalesDocType.order,
        ).overrideWithValue(_Repository(line)),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SalesPlanProgressPanel(
              orderId: 'order-1',
              shipmentActions: scope,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Repository extends SalesRepository {
  _Repository(this.line) : super(ApiClient(Dio()), SalesDocType.order);
  final OrderPlanProgressLine line;
  @override
  Future<List<OrderPlanProgressLine>> planProgress(String id) async => [line];
}
