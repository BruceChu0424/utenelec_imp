import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/repositories/finance_payables_repository.dart';
import 'package:uten_imp/features/finance/payables/widgets/supplier_credit_apply_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'offset target requires same supplier currency rate and positive AP',
    () {
      final source = FinancePayableItem.fromJson(_creditItem);
      expect(
        supplierOffsetTargetCompatible(
          source,
          FinancePayableItem.fromJson(_payableItem),
        ),
        isTrue,
      );
      expect(
        supplierOffsetTargetCompatible(
          source,
          FinancePayableItem.fromJson({
            ..._payableItem,
            'bookingRate': '7.100000',
          }),
        ),
        isFalse,
      );
      expect(
        supplierOffsetTargetCompatible(
          source,
          FinancePayableItem.fromJson({
            ..._payableItem,
            'currencyId': 'currency-eur',
          }),
        ),
        isFalse,
      );
      expect(
        supplierOffsetTargetCompatible(
          source,
          FinancePayableItem.fromJson({
            ..._payableItem,
            'supplierId': 'supplier-2',
          }),
        ),
        isFalse,
      );
    },
  );

  test('repository posts payable offset and returns batch id', () async {
    final api = _OffsetApi();
    final batchId = await FinancePayablesRepository(api).applyOffset(
      sourceLedgerId: 'credit-1',
      effectiveDate: '2026-08-22',
      reason: ' 采购退货贷项 ',
      targets: const [
        FinancePayableOffsetTarget(
          payableId: 'payable-1',
          amountOriginal: '80.0000',
        ),
      ],
    );

    expect(api.path, '/finance/payable-offsets');
    expect(api.body, {
      'sourceLedgerId': 'credit-1',
      'effectiveDate': '2026-08-22',
      'reason': '采购退货贷项',
      'targets': [
        {'payableId': 'payable-1', 'amountOriginal': '80.0000'},
      ],
    });
    expect(batchId, 'batch-1');
  });

  testWidgets('credit shows apply action while prepayment shows hard block', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financePayablesRepositoryProvider.overrideWithValue(
            FinancePayablesRepository(_PageApi()),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.arApLedgerView,
            Perm.financeViewAll,
            Perm.supplierOpenItemOffsetApply,
          }),
        ],
        child: const MaterialApp(home: FinancePayablesPage()),
      ),
    );
    await tester.pumpAndSettle();

    var table = tester.widget<MasterDataTableView<FinancePayableItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinancePayableItem>,
      ),
    );
    table.onSelectedIdsChanged?.call({'credit-1'});
    await tester.pump();
    expect(
      find.byKey(const ValueKey('finance-payables-apply-credit')),
      findsOneWidget,
    );

    table = tester.widget<MasterDataTableView<FinancePayableItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinancePayableItem>,
      ),
    );
    table.onSelectedIdsChanged?.call({'prepayment-1'});
    await tester.pump();
    expect(find.textContaining('需专用预付款资产/总账链'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('finance-payables-apply-credit')),
      findsNothing,
    );
  });
}

const _creditItem = <String, dynamic>{
  'id': 'credit-1',
  'businessType': 'PURCHASE',
  'openItemKind': 'CREDIT',
  'sourceDocType': 'PURCHASE_RETURN',
  'sourceDocNo': 'PR-001',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'currencyId': 'currency-usd',
  'currencyCode': 'USD',
  'bookingRate': '7.200000',
  'grossOriginal': '-100.0000',
  'grossLocal': '-720.0000',
  'outstandingOriginal': '-100.0000',
  'outstandingLocal': '-720.0000',
  'status': 'CREDIT',
};

const _payableItem = <String, dynamic>{
  'id': 'payable-1',
  'businessType': 'PURCHASE',
  'openItemKind': 'PAYABLE',
  'sourceDocType': 'PURCHASE_RECEIPT',
  'sourceDocNo': 'PI-001',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'currencyId': 'currency-usd',
  'currencyCode': 'USD',
  'bookingRate': '7.200000',
  'grossOriginal': '200.0000',
  'grossLocal': '1440.0000',
  'outstandingOriginal': '200.0000',
  'outstandingLocal': '1440.0000',
  'status': 'OPEN',
};

class _OffsetApi extends ApiClient {
  _OffsetApi() : super(Dio());

  String? path;
  Map<String, dynamic>? body;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = (body as Map).cast<String, dynamic>();
    return {'offsetBatchId': 'batch-1'};
  }
}

class _PageApi extends ApiClient {
  _PageApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'summary': {
      'payableLocal': '1440.0000',
      'paidLocal': '0.0000',
      'settledBookLocal': '0.0000',
      'exchangeDifferenceLocal': '0.0000',
      'offsetLocal': '0.0000',
      'outstandingLocal': '720.0000',
      'overdueLocal': '0.0000',
      'dueThisMonthLocal': '720.0000',
      'creditLocal': '720.0000',
      'prepaymentLocal': '360.0000',
      'pendingLossCases': 0,
    },
    'items': [
      _creditItem,
      {
        ..._creditItem,
        'id': 'prepayment-1',
        'openItemKind': 'PREPAYMENT',
        'sourceDocType': 'DIRECT_PAYMENT',
      },
      _payableItem,
    ],
    'page': 1,
    'size': 30,
    'total': 3,
    'totalPages': 1,
  };
}
