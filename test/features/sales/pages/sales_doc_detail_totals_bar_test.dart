// 销售单据详情页明细合计条（UtenTotalsSummaryBar）契约：
//  - 明细表下渲染合计条；「合计数量」按 unitId 分组，不同单位绝不相加；
//  - 「合计金额(币种)」标红，币种取表头币种名（不硬编码 ¥）；
//  - priceMasked（无 sales_order:price:view）时金额项整体不渲染，只剩数量；
//  - 表宽超出卡片时合计条钉在表格**可视框**右缘(横滚到哪都看得见，不必拖到最右)。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
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

  // 2026-09-15 用户口径：合计条竖向跟着最后一行走，横向永远贴表格可视框右缘——
  // 表比卡片宽时不必把表格拖到最右才看得到「合计数量/合计金额」。
  testWidgets('表宽超出卡片：合计条钉在可视框右缘，横滚后仍在', (tester) async {
    // 窄视口(600)远小于明细表列宽合计(货品名称 200 + 编号 130 + …)。
    await _pumpDetail(
      tester,
      priceMasked: false,
      surface: const Size(600, 900),
    );

    final table = find.byType(MasterDataTableView<SalesDocItem>);
    expect(table, findsOneWidget);
    // 合计条右边缘 = 可视框右缘 - 表内 4px 内边距(不是表格最右端)。
    double gapToViewportRight() =>
        tester.getRect(table).right -
        tester.getRect(find.byType(UtenTotalsSummaryBar)).right;
    expect(gapToViewportRight(), closeTo(4, 1));

    // 横滚后仍贴可视框右缘：先确认表格真的滚动了(表头首列左移)。
    final headerBefore = tester.getRect(find.text('货品名称')).left;
    await tester.drag(table, const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('货品名称')).left,
      lessThan(headerBefore - 100),
    );
    expect(gapToViewportRight(), closeTo(4, 1));
  });
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  required bool priceMasked,
  Size surface = const Size(1500, 1400),
}) async {
  await tester.binding.setSurfaceSize(surface);
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
