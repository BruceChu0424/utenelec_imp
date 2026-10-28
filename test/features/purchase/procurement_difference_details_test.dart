import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../support/native_detail_reader_overrides.dart';

const _values = ['-90071992547409.1234', '0.0000', '1.2500', null];

void main() {
  for (final type in PurchaseDocType.values) {
    testWidgets('purchase ${type.name} shows authoritative stage difference', (
      tester,
    ) async {
      final linked =
          type == PurchaseDocType.receipt || type == PurchaseDocType.returnDoc;
      final api = _DetailApi('/purchase/${type.pathSegment}/doc', linked);
      await _pump(
        tester,
        api,
        purchaseRepositoryProvider(
          type,
        ).overrideWithValue(PurchaseRepository(api, type)),
        PurchaseDocDetailPage(docType: type, id: 'doc'),
      );
      final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
        find.byType(MasterDataTableView<PurchaseDocItem>),
      );
      _expectDifference(
        table,
        linked: linked,
        request: type == PurchaseDocType.request,
      );
    });
  }

  for (final type in [
    SubcontractDocType.application,
    SubcontractDocType.order,
    SubcontractDocType.receipt,
    SubcontractDocType.returnDoc,
    SubcontractDocType.materialIssue,
    SubcontractDocType.materialReturn,
  ]) {
    testWidgets(
      'subcontract ${type.name} shows authoritative stage difference',
      (tester) async {
        final linked =
            type == SubcontractDocType.receipt ||
            type == SubcontractDocType.returnDoc ||
            type == SubcontractDocType.materialIssue ||
            type == SubcontractDocType.materialReturn;
        final api = _DetailApi('/subcontract/${type.pathSegment}/doc', linked);
        await _pump(
          tester,
          api,
          subcontractRepositoryProvider(
            type,
          ).overrideWithValue(SubcontractRepository(api, type)),
          SubcontractDocDetailPage(docType: type, id: 'doc'),
        );
        final table = tester.widget<MasterDataTableView<SubcontractDocItem>>(
          find.byType(MasterDataTableView<SubcontractDocItem>),
        );
        _expectDifference(
          table,
          linked: linked,
          request: type == SubcontractDocType.application,
        );
      },
    );
  }
}

void _expectDifference<T>(
  MasterDataTableView<T> table, {
  required bool linked,
  required bool request,
}) {
  final column = table.columns.singleWhere(
    (column) =>
        column.key == (linked ? 'sourceOrderDifferenceQty' : 'differenceQty'),
  );
  final unit = linked ? '箱' : '件';
  expect(column.label, linked ? '订货差异数' : '差异数');
  expect(column.info, contains(request ? '尚未下单' : '未到齐'));
  expect(column.sortable, isTrue);
  expect(column.filterFromRows, isTrue);
  expect(column.supportsKeywordSearch, isTrue);
  expect(table.items.map(column.value), [
    '-90071992547409.1234 $unit',
    '0 $unit',
    '1.25 $unit',
    '—',
  ]);
  expect(table.items.map(column.exactValueOf!), _values);
  expect(table.columns.any((column) => column.key == 'price'), isFalse);
}

Future<void> _pump(
  WidgetTester tester,
  ApiClient api,
  Override repositoryOverride,
  Widget page,
) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.purchaseRequestView,
          Perm.purchaseOrderView,
          Perm.purchaseReceiptView,
          Perm.purchaseReturnView,
          Perm.subcontractApplicationView,
          Perm.subcontractOrderView,
          Perm.subcontractReceiptView,
          Perm.subcontractReturnView,
          Perm.subcontractMaterialIssueView,
          Perm.subcontractMaterialReturnView,
        }),
        repositoryOverride,
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _DetailApi extends ApiClient {
  _DetailApi(this.detailPath, this.linked) : super(Dio());

  final String detailPath;
  final bool linked;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.contains('units')
      ? [
          {'id': 'unit-item', 'name': '件'},
          {'id': 'unit-box', 'name': '箱'},
        ]
      : [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == detailPath
      ? {
          'id': 'doc',
          'makerId': 'maker',
          'billNo': 'TEST-001',
          'billDate': '2026-10-27',
          'status': 1,
          'closed': true,
          'priceMasked': true,
          'items': [
            for (final (index, value) in _values.indexed)
              {
                'id': 'line-$index',
                'goodsId': 'goods-$index',
                'unitId': 'unit-item',
                'qty': 10,
                'orderedQty': 10,
                'receivedQty': 10,
                'returnedQty': 0,
                if (value != null) ...{
                  if (linked) ...{
                    'sourceOrderDifferenceQtyExact': value,
                    'sourceOrderDifferenceUnitId': 'unit-box',
                    // The source order unit must win over this document row.
                    'differenceQtyExact': '999',
                  } else ...{
                    'differenceQty': 999,
                    'differenceQtyExact': value,
                  },
                },
              },
          ],
        }
      : {'items': <Object?>[]};
}
