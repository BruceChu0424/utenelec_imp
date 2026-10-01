import '../support/native_detail_reader_overrides.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../support/document_scope_capability_overrides.dart';

const _remark = '按原包装分批交货\n不能混色';

class _DetailApi extends ApiClient {
  _DetailApi({this.priceMasked = false}) : super(Dio());

  final bool priceMasked;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.endsWith('/detail-fixture')
      ? {
          'id': 'detail-fixture',
          'makerId': 'maker-1',
          'billNo': 'DOC-001',
          'billDate': '2026-09-30',
          'makerName': '经办员',
          'createdAt': '2026-09-30T10:00:00+08:00',
          'supplierId': 'supplier-1',
          'warehouseId': 'warehouse-1',
          'status': 0,
          'priceMasked': priceMasked,
          'items': [
            {
              'id': 'line-1',
              'goodsId': 'goods-1',
              'unitId': 'unit-1',
              'qty': 3000,
              'priceExact': '0.0333333333',
              'totalAmountInputExact': '100.000000000000000001',
              'amountOriginalExact': '100.000000000000000001',
              'girthQty': 12.75,
              'boxQty': 8.5,
              'remark': _remark,
            },
            {'id': 'line-empty', 'goodsId': 'goods-2', 'unitId': 'unit-1'},
          ],
        }
      : {'items': <Object?>[]};
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  PurchaseDocType? purchase,
  SubcontractDocType? subcontract,
  bool commercial = false,
  bool priceMasked = false,
}) async {
  tester.view.physicalSize = const Size(1600, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _DetailApi(priceMasked: priceMasked);
  final purchaseConfig = purchase == null
      ? null
      : PurchaseDocConfig.by(purchase);
  final subcontractConfig = subcontract == null
      ? null
      : SubcontractDocConfig.by(subcontract);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        writeAllDocumentScope(
          purchase == null
              ? DocumentDataScope.subcontract
              : DocumentDataScope.purchase,
        ),
        currentPermissionsProvider.overrideWithValue({
          if (purchaseConfig != null) purchaseConfig.listPerm,
          if (subcontractConfig != null) subcontractConfig.listPerm,
          if (commercial && purchaseConfig?.commercialViewPerm != null)
            purchaseConfig!.commercialViewPerm!,
          if (commercial && subcontractConfig?.commercialViewPerm != null)
            subcontractConfig!.commercialViewPerm!,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        if (purchase != null)
          purchaseRepositoryProvider(
            purchase,
          ).overrideWithValue(PurchaseRepository(api, purchase)),
        if (subcontract != null)
          subcontractRepositoryProvider(
            subcontract,
          ).overrideWithValue(SubcontractRepository(api, subcontract)),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: purchase != null
            ? PurchaseDocDetailPage(docType: purchase, id: 'detail-fixture')
            : SubcontractDocDetailPage(
                docType: subcontract!,
                id: 'detail-fixture',
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final type in [
    PurchaseDocType.request,
    PurchaseDocType.order,
    PurchaseDocType.receipt,
  ]) {
    testWidgets(
      'purchase ${type.name} detail exposes persisted line remark without commercial permission',
      (tester) async {
        await _pumpDetail(tester, purchase: type);
        final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
          find.byType(MasterDataTableView<PurchaseDocItem>),
        );
        final column = table.columns.singleWhere(
          (column) => column.key == 'remark',
        );
        expect(column.value(table.items.first), _remark);
        expect(column.value(table.items.last), isNull);
        expect(table.columns.any((column) => column.key == 'price'), isFalse);
        expect(table.columns.any((column) => column.key == 'amount'), isFalse);
        if (type == PurchaseDocType.order) {
          expect(
            table.columns.where((column) => column.key == 'sourceRequests'),
            hasLength(1),
          );
        }
      },
    );
  }

  for (final type in [
    SubcontractDocType.order,
    SubcontractDocType.receipt,
    SubcontractDocType.returnDoc,
    SubcontractDocType.materialReturn,
    SubcontractDocType.materialIssue,
    SubcontractDocType.waste,
  ]) {
    testWidgets(
      'subcontract ${type.name} detail exposes persisted fields under its original config',
      (tester) async {
        await _pumpDetail(tester, subcontract: type);
        final table = tester.widget<MasterDataTableView<SubcontractDocItem>>(
          find.byType(MasterDataTableView<SubcontractDocItem>),
        );
        final config = SubcontractDocConfig.by(type);
        final girth = table.columns
            .where((column) => column.key == 'girth')
            .toList();
        final boxes = table.columns
            .where((column) => column.key == 'boxQty')
            .toList();
        expect(girth, hasLength(config.itemHasGirth ? 1 : 0));
        expect(boxes, hasLength(config.itemHasBoxQty ? 1 : 0));
        if (config.itemHasGirth) {
          expect(girth.single.value(table.items.first), '12.75');
          expect(girth.single.value(table.items.last), isNull);
        }
        if (config.itemHasBoxQty) {
          expect(boxes.single.value(table.items.first), '8.5');
          expect(boxes.single.value(table.items.last), isNull);
        }
        final remark = table.columns.singleWhere(
          (column) => column.key == 'remark',
        );
        expect(remark.value(table.items.first), _remark);
        expect(remark.value(table.items.last), isNull);
        expect(table.columns.any((column) => column.key == 'price'), isFalse);
        expect(table.columns.any((column) => column.key == 'amount'), isFalse);
        if (type == SubcontractDocType.order) {
          expect(
            table.columns.where((column) => column.key == 'sourceApplications'),
            hasLength(1),
          );
        }
      },
    );
  }

  for (final purchase in [true, false]) {
    for (final masked in [false, true]) {
      testWidgets(
        '${purchase ? 'purchase' : 'subcontract'} restored columns preserve exact pricing and masking=$masked',
        (tester) async {
          await _pumpDetail(
            tester,
            purchase: purchase ? PurchaseDocType.order : null,
            subcontract: purchase ? null : SubcontractDocType.order,
            commercial: true,
            priceMasked: masked,
          );
          if (purchase) {
            final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
              find.byType(MasterDataTableView<PurchaseDocItem>),
            );
            final row = table.items.first;
            expect(
              table.columns
                  .singleWhere((column) => column.key == 'remark')
                  .value(row),
              _remark,
            );
            if (masked) {
              expect(
                table.columns.any(
                  (column) => column.key == 'price' || column.key == 'amount',
                ),
                isFalse,
              );
            } else {
              expect(
                table.columns
                    .singleWhere((column) => column.key == 'price')
                    .value(row),
                '0.0333333333（参考）',
              );
              expect(
                table.columns
                    .singleWhere((column) => column.key == 'amount')
                    .value(row),
                '100.000000000000000001',
              );
            }
          } else {
            final table = tester
                .widget<MasterDataTableView<SubcontractDocItem>>(
                  find.byType(MasterDataTableView<SubcontractDocItem>),
                );
            final row = table.items.first;
            expect(
              table.columns
                  .singleWhere((column) => column.key == 'remark')
                  .value(row),
              _remark,
            );
            if (masked) {
              expect(
                table.columns.any(
                  (column) => column.key == 'price' || column.key == 'amount',
                ),
                isFalse,
              );
            } else {
              expect(
                table.columns
                    .singleWhere((column) => column.key == 'price')
                    .value(row),
                '0.0333333333（参考）',
              );
              expect(
                table.columns
                    .singleWhere((column) => column.key == 'amount')
                    .value(row),
                '100.000000000000000001',
              );
            }
          }
        },
      );
    }
  }
}
