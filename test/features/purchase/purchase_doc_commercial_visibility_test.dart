import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  testWidgets(
    'warehouse viewer keeps quantity but receives no commercial columns',
    (tester) async {
      await _pumpDetail(tester, permissions: const {}, priceMasked: false);

      final keys = _detailColumnKeys(tester);
      expect(keys, contains('qty'));
      expect(keys, isNot(contains('price')));
      expect(keys, isNot(contains('amount')));
      expect(find.text('币种'), findsNothing);
      expect(find.text('汇率'), findsNothing);
      expect(find.text('合计(本币)'), findsNothing);
    },
  );

  testWidgets('commercial permission retains purchase amounts', (tester) async {
    await _pumpDetail(
      tester,
      permissions: const {Perm.purchaseReceiptPriceView},
      priceMasked: false,
    );

    final keys = _detailColumnKeys(tester);
    expect(keys, containsAll(<String>{'qty', 'price', 'amount'}));
    expect(find.text('币种'), findsOneWidget);
    expect(find.text('汇率'), findsOneWidget);
    expect(find.text('合计(本币)'), findsOneWidget);
  });

  testWidgets('server price mask wins over commercial permission', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      permissions: const {Perm.purchaseReceiptPriceView},
      priceMasked: true,
    );

    final keys = _detailColumnKeys(tester);
    expect(keys, contains('qty'));
    expect(keys, isNot(contains('price')));
    expect(keys, isNot(contains('amount')));
    expect(find.text('币种'), findsNothing);
    expect(find.text('汇率'), findsNothing);
    expect(find.text('合计(本币)'), findsNothing);
  });
}

Set<String> _detailColumnKeys(WidgetTester tester) {
  final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
    find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<PurchaseDocItem>,
    ),
  );
  return {for (final column in table.columns) column.key};
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  required Set<String> permissions,
  required bool priceMasked,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final api = _TestApi(priceMasked: priceMasked);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        writeAllDocumentScope(DocumentDataScope.purchase),
        currentPermissionsProvider.overrideWithValue(permissions),
        purchaseRepositoryProvider(
          PurchaseDocType.receipt,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.receipt)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: const MaterialApp(
        home: PurchaseDocDetailPage(
          docType: PurchaseDocType.receipt,
          id: 'receipt-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _TestApi extends ApiClient {
  _TestApi({required this.priceMasked}) : super(Dio());

  final bool priceMasked;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/purchase/receipts/receipt-1')) {
      return <String, dynamic>{
        'id': 'receipt-1',
        'makerId': 'maker-1',
        'billNo': 'PR-001',
        'billDate': '2026-08-27',
        'makerName': '仓管员',
        'createdAt': '2026-08-27T10:00:00+08:00',
        'supplierId': 'supplier-1',
        'warehouseId': 'warehouse-1',
        'currencyId': 'cny',
        'exchangeRate': 1,
        'status': 0,
        'totalLocal': 50,
        'priceMasked': priceMasked,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'item-1',
            'goodsId': 'goods-1',
            'colorId': 'color-1',
            'unitId': 'unit-1',
            'qty': 10,
            'price': 5,
            'amountLocal': 50,
          },
        ],
      };
    }
    return <String, dynamic>{'items': <Object?>[]};
  }
}
