import '../../support/native_detail_reader_overrides.dart';
import '../../support/detail_summary_tap.dart';
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
      await setDetailSummaryExpanded(tester);
      expect(find.text('币种'), findsNothing);
      expect(detailSummaryField('单据币种'), findsNothing);
      expect(find.text('汇率'), findsNothing);
      expect(find.text('合计(本币)'), findsNothing);
    },
  );

  testWidgets('commercial permission retains purchase amounts', (tester) async {
    final api = await _pumpDetail(
      tester,
      permissions: const {Perm.purchaseReceiptPriceView},
      priceMasked: false,
    );

    final keys = _detailColumnKeys(tester);
    expect(keys, containsAll(<String>{'qty', 'price', 'amount'}));
    await setDetailSummaryExpanded(tester);
    await expectVisibleDetailSummaryField(tester, '单据币种', '人民币');
    await expectVisibleDetailSummaryField(tester, '汇率', '1.0');
    await expectVisibleDetailSummaryField(tester, '合计(本币)', '50.00 人民币');
    expect(api.writeCalls, 0);
    expect(tester.takeException(), isNull);
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
    await setDetailSummaryExpanded(tester);
    expect(find.text('币种'), findsNothing);
    expect(detailSummaryField('单据币种'), findsNothing);
    expect(find.text('汇率'), findsNothing);
    expect(find.text('合计(本币)'), findsNothing);
  });

  testWidgets('receipt price permission cannot unlock purchase order amounts', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      permissions: const {Perm.purchaseReceiptPriceView},
      priceMasked: false,
      docType: PurchaseDocType.order,
    );

    final keys = _detailColumnKeys(tester);
    expect(keys, contains('qty'));
    expect(keys, isNot(contains('price')));
    expect(keys, isNot(contains('amount')));
    await setDetailSummaryExpanded(tester);
    expect(detailSummaryField('单据币种'), findsNothing);
    expect(detailSummaryField('汇率'), findsNothing);
    expect(find.text('合计(本币)'), findsNothing);
  });

  testWidgets('order price permission unlocks only purchase order amounts', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      permissions: const {Perm.purchaseOrderPriceView},
      priceMasked: false,
      docType: PurchaseDocType.order,
    );

    final keys = _detailColumnKeys(tester);
    expect(keys, containsAll(<String>{'qty', 'price', 'amount'}));
    expect(find.text('合计(本币)'), findsOneWidget);
  });

  testWidgets('finance-wide permission can render unmasked purchase amounts', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      permissions: const {Perm.financeViewAll},
      priceMasked: false,
      docType: PurchaseDocType.order,
    );

    expect(
      _detailColumnKeys(tester),
      containsAll(<String>{'qty', 'price', 'amount'}),
    );
  });

  testWidgets('ADR-144 订货详情的允许超收列不随价格遮蔽，未设显示「未设」', (tester) async {
    await _pumpDetail(
      tester,
      permissions: const {},
      priceMasked: true,
      docType: PurchaseDocType.order,
    );
    final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<PurchaseDocItem>,
      ),
    );
    final column = table.columns.singleWhere(
      (column) => column.key == 'allowedOverReceiptPct',
    );
    expect(column.label, '允许超收%');
    expect(column.value(table.items.single), '未设');
    expect(_detailColumnKeys(tester), isNot(contains('price')));
  });

  testWidgets('ADR-144 收货详情没有允许超收列', (tester) async {
    await _pumpDetail(tester, permissions: const {}, priceMasked: false);
    expect(_detailColumnKeys(tester), isNot(contains('allowedOverReceiptPct')));
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

Future<_TestApi> _pumpDetail(
  WidgetTester tester, {
  required Set<String> permissions,
  required bool priceMasked,
  PurchaseDocType docType = PurchaseDocType.receipt,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final id = '${docType.name}-1';
  final api = _TestApi(priceMasked: priceMasked, docType: docType, id: id);
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
      child: MaterialApp(
        home: PurchaseDocDetailPage(docType: docType, id: id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return api;
}

class _TestApi extends ApiClient {
  _TestApi({required this.priceMasked, required this.docType, required this.id})
    : super(Dio());

  final bool priceMasked;
  final PurchaseDocType docType;
  final String id;
  int writeCalls = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    writeCalls++;
    throw StateError('采购只读详情不能POST：$path');
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writeCalls++;
    throw StateError('采购只读详情不能PUT：$path');
  }

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    writeCalls++;
    throw StateError('采购只读详情不能DELETE：$path');
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/master/currencies/dict'
      ? [
          {'id': 'cny', 'name': '人民币'},
        ]
      : <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/purchase/${docType.pathSegment}/$id')) {
      return <String, dynamic>{
        'id': id,
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
