import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_doc_link_picker_sheet.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/purchase/widgets/doc_link_picker.dart';
import 'package:uten_imp/features/sales/config/sales_doc_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/widgets/sales_doc_link_picker.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_link_picker.dart'
    as subcontract;
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _DeferredApi extends ApiClient {
  _DeferredApi() : super(Dio());

  final details = <Completer<Map<String, dynamic>>>[];
  final progress = <Completer<List<Map<String, dynamic>>>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/source-a') || path.endsWith('/source-b')) {
      final gate = Completer<Map<String, dynamic>>();
      details.add(gate);
      return gate.future;
    }
    return {
      'items': [
        for (final suffix in ['a', 'b'])
          {
            'id': 'source-$suffix',
            'billNo': 'SOURCE-$suffix',
            'billDate': '2026-10-26',
            'status': 1,
          },
      ],
      'page': 1,
      'size': 20,
      'total': 2,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final gate = Completer<List<Map<String, dynamic>>>();
    progress.add(gate);
    return gate.future;
  }
}

class _PurchaseNames extends MasterNameService {
  _PurchaseNames(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsNames(Iterable<String> ids) async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  Map<String, String> get supplierEntries => {};
  @override
  String supplier(String? id) => '供应商';
  @override
  String goods(String? id) => '采购来源货品';
  @override
  String unit(String? id) => '件';
}

class _SalesNames extends SalesMasterNameService {
  _SalesNames(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsNames(Iterable<String> ids) async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  Map<String, String> get clientEntries => {};
  @override
  String goods(String? id) => '销售来源货品';
  @override
  String unit(String? id) => '件';
}

class _OpenedPicker {
  Future<Object?>? result;
}

Future<_OpenedPicker> _open(
  WidgetTester tester,
  _DeferredApi api, {
  bool purchase = false,
  bool subcontractReceipt = false,
  SalesDocType salesType = SalesDocType.shipment,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final opened = _OpenedPicker();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (purchase) ...[
          purchaseRepositoryProvider(
            PurchaseDocType.request,
          ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.request)),
          masterNameServiceProvider.overrideWithValue(_PurchaseNames(api)),
        ] else if (subcontractReceipt) ...[
          subcontractRepositoryProvider(
            SubcontractDocType.order,
          ).overrideWithValue(
            SubcontractRepository(api, SubcontractDocType.order),
          ),
          masterNameServiceProvider.overrideWithValue(_PurchaseNames(api)),
        ] else ...[
          salesRepositoryProvider(
            salesType == SalesDocType.returnDoc
                ? SalesDocType.shipment
                : SalesDocType.order,
          ).overrideWithValue(
            SalesRepository(
              api,
              salesType == SalesDocType.returnDoc
                  ? SalesDocType.shipment
                  : SalesDocType.order,
            ),
          ),
          salesMasterNameServiceProvider.overrideWithValue(_SalesNames(api)),
        ],
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () {
                opened.result = purchase
                    ? showDocLinkPicker(
                        context,
                        ref,
                        PurchaseDocConfig.by(PurchaseDocType.order),
                        allowOverRemaining: true,
                      )
                    : subcontractReceipt
                    ? subcontract.showSubcontractLinkPicker(
                        context,
                        ref,
                        SubcontractDocConfig.by(SubcontractDocType.receipt),
                      )
                    : showSalesDocLinkPicker(
                        context,
                        ref,
                        SalesDocConfig.by(salesType),
                      );
              },
              child: const Text('选择来源'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('选择来源'));
  await tester.pumpAndSettle();
  return opened;
}

Map<String, dynamic> _detail(
  String suffix, {
  String? rate,
  double qty = 10,
  double received = 0,
  double returned = 0,
}) => {
  'id': 'source-$suffix',
  'billNo': 'SOURCE-$suffix',
  'status': 1,
  'writable': true,
  'financeConfirmed': true,
  'items': [
    {
      'id': 'line-$suffix',
      'goodsId': 'goods',
      'qty': qty,
      'qtyExact': qty.toString(),
      'receivedQty': received,
      'returnedQty': returned,
      'remainingQtyExact': '10',
      'orderedQty': 0,
      'orderedQtyExact': '0',
      'unitId': 'piece',
      'unitRate': 1,
      'unitRateExact': ?rate,
    },
  ],
};

List<Map<String, dynamic>> _progress(String suffix, double qty) => [
  {
    'orderItemId': 'line-$suffix',
    'goodsId': 'goods',
    'qty': 10,
    'shippableQty': qty,
  },
];

void main() {
  for (final sub in [false, true]) {
    testWidgets(
      '${sub ? 'subcontract receipt' : 'sales return'} source keeps decimal 0.3 minus 0.1 selectable and submittable',
      (tester) async {
        final api = _DeferredApi();
        final opened = await _open(
          tester,
          api,
          subcontractReceipt: sub,
          salesType: SalesDocType.returnDoc,
        );
        if (sub) {
          final table = tester
              .widget<MasterDataTableView<SubcontractDocListItem>>(
                find.byType(MasterDataTableView<SubcontractDocListItem>),
              );
          table.onRowTap!(table.items.first);
        } else {
          final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
            find.byType(MasterDataTableView<SalesDocListItem>),
          );
          table.onRowTap!(table.items.first);
        }
        api.details.single.complete(
          _detail(
            'a',
            qty: 0.3,
            received: sub ? 0.1 : 0,
            returned: sub ? 0 : 0.1,
          ),
        );
        await tester.pumpAndSettle();
        if (sub) {
          final grid = tester
              .widget<UtenEditableGrid<UtenDocLinkItemRow<SubcontractDocItem>>>(
                find.byType(
                  UtenEditableGrid<UtenDocLinkItemRow<SubcontractDocItem>>,
                ),
              );
          expect(grid.controller.rows, hasLength(1));
          expect(double.parse(grid.controller.rows.single.qty.text), 0.2);
        } else {
          final grid = tester
              .widget<UtenEditableGrid<UtenDocLinkItemRow<SalesDocItem>>>(
                find.byType(UtenEditableGrid<UtenDocLinkItemRow<SalesDocItem>>),
              );
          expect(grid.controller.rows, hasLength(1));
          expect(double.parse(grid.controller.rows.single.qty.text), 0.2);
        }
        expect(find.textContaining('来源数量不完整'), findsNothing);
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
        await tester.tap(find.text('引入'));
        await tester.pumpAndSettle();
        if (sub) {
          final result =
              (await opened.result!) as subcontract.SubcontractLinkPickResult;
          expect(result.items.single.qty, 0.2);
          expect(result.items.single.upstreamItemId, 'line-a');
        } else {
          final result = (await opened.result!) as SalesLinkPickResult;
          expect(result.items.single.qty, 0.2);
          expect(result.items.single.outItemId, 'line-a');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('late sales detail cannot clear the chosen order availability', (
    tester,
  ) async {
    final api = _DeferredApi();
    final opened = await _open(tester, api);
    final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
      find.byType(MasterDataTableView<SalesDocListItem>),
    );
    table.onRowTap!(table.items.first);
    table.onRowTap!(table.items.last);
    expect(api.details.length, 2);
    api.details[1].complete(_detail('b'));
    await tester.pump();
    expect(api.progress.length, 1);
    api.progress[0].complete(_progress('b', 2));
    await tester.pumpAndSettle();
    api.details[0].complete(_detail('a'));
    await tester.pump();
    expect(api.progress.length, 2);
    api.progress[1].complete(_progress('a', 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('2 件'), findsOneWidget);
    await tester.tap(find.text('引入'));
    await tester.pumpAndSettle();
    final result = (await opened.result!) as SalesLinkPickResult;
    expect(result.items.single.orderItemId, 'line-b');
    expect(result.items.single.qty, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late sales progress cannot replace a newer same-order cap', (
    tester,
  ) async {
    final api = _DeferredApi();
    final opened = await _open(tester, api);
    final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
      find.byType(MasterDataTableView<SalesDocListItem>),
    );
    table.onRowTap!(table.items.first);
    api.details[0].complete(_detail('a'));
    await tester.pump();
    expect(api.progress.length, 1);
    table.onRowTap!(table.items.first);
    api.details[1].complete(_detail('a'));
    await tester.pump();
    expect(api.progress.length, 2);
    api.progress[1].complete(_progress('a', 2));
    await tester.pumpAndSettle();
    api.progress[0].complete(_progress('a', 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('2 件'), findsOneWidget);
    await tester.tap(find.text('引入'));
    await tester.pumpAndSettle();
    final result = (await opened.result!) as SalesLinkPickResult;
    expect(result.items.single.orderItemId, 'line-a');
    expect(result.items.single.qty, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late purchase detail cannot overwrite the selected exact unit rate',
    (tester) async {
      final api = _DeferredApi();
      final opened = await _open(tester, api, purchase: true);
      final table = tester.widget<MasterDataTableView<PurchaseDocListItem>>(
        find.byType(MasterDataTableView<PurchaseDocListItem>),
      );
      table.onRowTap!(table.items.first);
      table.onRowTap!(table.items.first);
      expect(api.details.length, 2);
      api.details[1].complete(_detail('a', rate: '1.23456789'));
      await tester.pumpAndSettle();
      api.details[0].complete(_detail('a', rate: '0.5'));
      await tester.pumpAndSettle();
      final grid = tester
          .widget<UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>>(
            find.byType(UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>),
          );
      expect(grid.controller.rows.single.item.unitRateExactText, '1.23456789');
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.text('引入'));
      await tester.pumpAndSettle();
      final result = (await opened.result!) as PurchaseLinkPickResult;
      expect(result.items.single.upstreamItemId, 'line-a');
      expect(result.items.single.unitRateText, '1.23456789');
      expect(tester.takeException(), isNull);
    },
  );
}
