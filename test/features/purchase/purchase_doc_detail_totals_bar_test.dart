import '../../support/native_detail_reader_overrides.dart';
// 采购单据详情页明细合计条（UtenTotalsSummaryBar）契约：
//  - 明细表下渲染合计条；「合计数量」按 unitId 分组，不同单位绝不相加；
//  - 「合计金额(币种)」标红，币种取表头币种名（不硬编码 ¥）；
//  - 无商务金额权限 / 服务端脱敏时只剩数量项，金额项不渲染。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

void main() {
  testWidgets('按总金额计价显示完整参考单价及服务端真实总金额', (tester) async {
    await _pumpDetail(
      tester,
      permissions: const {Perm.purchaseOrderPriceView},
      priceMasked: false,
      totalPricing: true,
    );
    final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
      find.byType(MasterDataTableView<PurchaseDocItem>),
    );
    final row = table.items.first;
    final price = table.columns.singleWhere((column) => column.key == 'price');
    final amount = table.columns.singleWhere(
      (column) => column.key == 'amount',
    );
    // 金额「数值 币种」后缀（2026-10-10 口径）：表头币种随金额显示。
    expect(price.value(row), '0.0333333333 美元（参考）');
    expect(price.info, contains('结算按单据记录的总金额'));
    expect(amount.label, '总金额');
    expect(amount.value(row), '100.000000000000000001 美元');
  });

  testWidgets('订货详情：合计数量按单位分组、合计金额标红且币种取表头', (tester) async {
    await _pumpDetail(
      tester,
      permissions: const {Perm.purchaseOrderPriceView},
      priceMasked: false,
    );

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('合计数量: '), findsOneWidget);
    // 10 公斤 + 4 箱 绝不合并成 14。
    expect(find.text('4 箱 · 10 公斤'), findsOneWidget);
    expect(find.text('14'), findsNothing);

    expect(find.text('合计金额(美元): '), findsOneWidget);
    expect(find.textContaining('¥'), findsNothing);
    final theme = Theme.of(tester.element(find.byType(UtenTotalsSummaryBar)));
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(UtenTotalsSummaryBar),
              matching: find.text('50.00'),
            ),
          )
          .style
          ?.color,
      theme.colorScheme.error,
    );
    expect(find.text('合计(本币): '), findsOneWidget);
  });

  testWidgets('服务端脱敏时合计条只剩数量项', (tester) async {
    await _pumpDetail(tester, permissions: const {}, priceMasked: true);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('合计数量: '), findsOneWidget);
    expect(find.text('4 箱 · 10 公斤'), findsOneWidget);
    expect(find.textContaining('合计金额'), findsNothing);
    expect(find.text('合计(本币): '), findsNothing);
  });
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  required Set<String> permissions,
  required bool priceMasked,
  bool totalPricing = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  const docType = PurchaseDocType.order;
  const id = 'order-1';
  final api = _TestApi(priceMasked: priceMasked, totalPricing: totalPricing);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        writeAllDocumentScope(DocumentDataScope.purchase),
        currentPermissionsProvider.overrideWithValue(permissions),
        purchaseRepositoryProvider(
          docType,
        ).overrideWithValue(PurchaseRepository(api, docType)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: const MaterialApp(
        home: PurchaseDocDetailPage(docType: docType, id: id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _TestApi extends ApiClient {
  _TestApi({required this.priceMasked, this.totalPricing = false})
    : super(Dio());

  final bool priceMasked;
  final bool totalPricing;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('units')) {
      return [
        {'id': 'unit-kg', 'name': '公斤'},
        {'id': 'unit-box', 'name': '箱'},
      ];
    }
    if (path.contains('currencies')) {
      return [
        {'id': 'usd', 'name': '美元'},
      ];
    }
    return <Map<String, dynamic>>[];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/purchase/orders/order-1')) {
      return <String, dynamic>{
        'id': 'order-1',
        'makerId': 'maker-1',
        'billNo': 'PO-001',
        'billDate': '2026-09-01',
        'makerName': '采购员',
        'createdAt': '2026-09-01T10:00:00+08:00',
        'supplierId': 'supplier-1',
        'currencyId': 'usd',
        'exchangeRate': 7,
        'status': 0,
        'totalOriginal': 50,
        'totalLocal': 350,
        'priceMasked': priceMasked,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'item-1',
            'goodsId': 'goods-1',
            'unitId': 'unit-kg',
            'qty': 10,
            'price': 5,
            'amountOriginal': 50,
            'amountLocal': 350,
            if (totalPricing) ...{
              'qty': 3000,
              'priceExact': '0.0333333333',
              'totalAmountInputExact': '100.000000000000000001',
              'amountOriginalExact': '100.000000000000000001',
            },
          },
          <String, dynamic>{
            'id': 'item-2',
            'goodsId': 'goods-2',
            'unitId': 'unit-box',
            'qty': 4,
            'price': 0,
            'amountOriginal': 0,
            'amountLocal': 0,
          },
        ],
      };
    }
    return <String, dynamic>{'items': <Object?>[]};
  }
}
