// 销售单据详情页明细合计条（UtenTotalsSummaryBar）契约：
//  - 明细表下渲染合计条；「合计数量」按 unitId 分组，不同单位绝不相加；
//  - 「合计金额(币种)」标红，币种取表头币种名（不硬编码 ¥）；
//  - priceMasked（无 sales_order:price:view）时金额项整体不渲染，只剩数量。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('订货详情：合计数量按单位分组、合计金额标红且币种取表头', (tester) async {
    await _pumpDetail(tester, priceMasked: false);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('合计数量: '), findsOneWidget);
    // 12 个 + 3 箱 绝不合并成 15。
    expect(find.text('3 箱 · 12 个'), findsOneWidget);
    expect(find.text('15'), findsNothing);

    expect(find.text('合计金额(美元): '), findsOneWidget);
    expect(find.textContaining('¥'), findsNothing);
    final theme = Theme.of(tester.element(find.byType(UtenTotalsSummaryBar)));
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(UtenTotalsSummaryBar),
              matching: find.text('2400.00'),
            ),
          )
          .style
          ?.color,
      theme.colorScheme.error,
    );
    // 订单阶段本币事实按设计不落，合计条不出本币项。
    expect(find.text('合计(本币): '), findsNothing);
  });

  testWidgets('价格脱敏时合计条只剩数量项', (tester) async {
    await _pumpDetail(tester, priceMasked: true);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('3 箱 · 12 个'), findsOneWidget);
    expect(find.textContaining('合计金额'), findsNothing);
  });
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  required bool priceMasked,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final detail = <String, dynamic>{
    'id': 'order-1',
    'billNo': 'SO-001',
    'billDate': '2026-09-01',
    'status': 0,
    'currencyId': 'currency-usd',
    'totalOriginal': priceMasked ? null : 2400,
    'priceMasked': priceMasked,
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'line-1',
        'unitId': 'unit-pcs',
        'qty': 12,
        'price': priceMasked ? null : 200,
        'amountOriginal': priceMasked ? null : 2400,
      },
      <String, dynamic>{
        'id': 'line-2',
        'unitId': 'unit-box',
        'qty': 3,
        'price': priceMasked ? null : 0,
        'amountOriginal': priceMasked ? null : 0,
      },
    ],
  };
  final api = _DetailApi(detail);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(
        home: SalesDocDetailPage(docType: SalesDocType.order, id: 'order-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _DetailApi extends ApiClient {
  _DetailApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => detail;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/currencies/dict') {
      return const [
        {'id': 'currency-usd', 'name': '美元'},
      ];
    }
    if (path == '/master/units/dict') {
      return const [
        {'id': 'unit-pcs', 'name': '个'},
        {'id': 'unit-box', 'name': '箱'},
      ];
    }
    return const [];
  }
}
