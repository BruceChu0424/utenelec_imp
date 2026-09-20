import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/repositories/finance_payables_repository.dart';
import 'package:uten_imp/features/finance/payables/widgets/supplier_credit_apply_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'later target pages remain reachable and preserve exact selected input',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _PagedOffsetApi();
      SupplierCreditApplyDraft? draft;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            financePayablesRepositoryProvider.overrideWithValue(
              FinancePayablesRepository(api),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () async {
                    draft = await showSupplierCreditApplyPanel(
                      context: context,
                      source: FinancePayableItem.fromJson(_creditItem),
                    );
                  },
                  child: const Text('打开贷项'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开贷项'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前页暂无符合条件'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('supplier-offset-load-more')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('supplier-offset-target-payable-1')),
      );
      await tester.pump();
      const exact = '1.000000000000000000000001';
      final amount = find.byKey(
        const ValueKey('supplier-offset-amount-payable-1'),
      );
      await tester.enterText(amount, exact);
      await tester.tap(find.byKey(const ValueKey('supplier-offset-load-more')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(amount).controller!.text, exact);
      expect(api.pages, [1, 2, 3]);
      expect(api.currencies, everyElement('currency-usd'));
      await tester.enterText(
        find.widgetWithText(TextField, '应用原因(必填)'),
        '新贷项冲抵已核验余额',
      );
      await tester.tap(find.text('确认应用 (1)'));
      await tester.pumpAndSettle();
      expect(draft!.targets.single.payableId, 'payable-1');
      expect(draft!.targets.single.amountOriginal, exact);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'proved positive historical target keeps exact amounts without becoming a funding source',
    () {
      final source = FinancePayableItem.fromJson(_creditItem);
      final historical = {
        ..._payableItem,
        'legacyImported': true,
        'openItemKind': 'LEGACY_UNVERIFIED',
        'sourceDocType': 'LEGACY_OPENING',
        'outstandingOriginal': '0.000000000000000000000001',
        'bookingRate': '7.200000000',
      };
      expect(
        supplierOffsetTargetCompatible(
          source,
          FinancePayableItem.fromJson(historical),
        ),
        isTrue,
      );
      for (final value in ['0', '-0.0001', null]) {
        expect(
          supplierOffsetTargetCompatible(
            source,
            FinancePayableItem.fromJson({
              ...historical,
              'outstandingOriginal': value,
            }),
          ),
          isFalse,
        );
      }
      expect(
        supplierOffsetTargetCompatible(
          source,
          FinancePayableItem.fromJson({...historical, 'currencyId': null}),
        ),
        isFalse,
      );
      expect(
        supplierOffsetTargetCompatible(
          source,
          FinancePayableItem.fromJson({
            ...historical,
            'openItemKind': 'PAYABLE',
          }),
        ),
        isFalse,
        reason: 'old unproved PAYABLE is not a proved opening',
      );
      final oldCredit = FinancePayableItem.fromJson({
        ..._creditItem,
        'legacyImported': true,
      });
      expect(oldCredit.canApplyCredit, isFalse);
      expect(
        supplierOffsetTargetCompatible(
          oldCredit,
          FinancePayableItem.fromJson(_payableItem),
        ),
        isFalse,
      );
    },
  );

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
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _PageApi();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financePayablesRepositoryProvider.overrideWithValue(
            FinancePayablesRepository(api),
          ),
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          settlementMethodOptionsProvider.overrideWith((_) async => const []),
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
    table.onSelectedIdsChanged?.call({'legacy-credit-1'});
    await tester.pump();
    expect(
      find.byKey(const ValueKey('finance-payables-apply-credit')),
      findsNothing,
    );
    expect(find.textContaining('历史资金不能作为贷项'), findsOneWidget);
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

class _PagedOffsetApi extends ApiClient {
  _PagedOffsetApi() : super(Dio());
  final pages = <int>[];
  final currencies = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final page = query!['page'] as int;
    pages.add(page);
    currencies.add(query['currencyId'] as String);
    return {
      'summary': <String, dynamic>{},
      'page': page,
      'size': 200,
      'total': 401,
      'totalPages': 3,
      'items': [
        if (page == 1)
          {..._payableItem, 'status': 'SETTLED', 'outstandingOriginal': '0'},
        if (page == 2)
          {
            ..._payableItem,
            'legacyImported': true,
            'openItemKind': 'LEGACY_UNVERIFIED',
            'sourceDocType': 'LEGACY_OPENING',
          },
        if (page == 3) {..._payableItem, 'id': 'payable-2'},
      ],
    };
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
      {..._creditItem, 'id': 'legacy-credit-1', 'legacyImported': true},
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
    'total': 4,
    'totalPages': 1,
  };
}
