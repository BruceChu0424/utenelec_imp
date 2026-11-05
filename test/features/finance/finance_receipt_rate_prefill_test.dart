import '../../support/finance_document_command_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:shared_preferences/shared_preferences.dart';
// V632 销售收款单可用性：本批汇率报价按币种预填(本位币锁 1)、收款方式字典为空不拦保存、
// 「引用应收」空列表一键切到登记订单预收。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'referencing a USD receivable prefills the master reference rate',
    (tester) async {
      final api = await _pumpDraft(tester, ledgerCurrency: 'currency-usd');
      final rate = find.byKey(const ValueKey('finance-receipt-exchange-rate'));
      expect(tester.widget<TextField>(rate).controller!.text, '1');

      await _importFirstLedger(tester);

      expect(tester.widget<TextField>(rate).controller!.text, '7.3');
      expect(tester.widget<TextField>(rate).readOnly, isFalse);
      expect(_receiptRow(tester).currencyId, 'currency-usd');
      expect(_receiptRow(tester).exchangeRate.text, '7.3');
      expect(api.sourceQueries.single['clientId'], 'client-1');
      expect(api.lastPutBody, isNull);
    },
  );

  testWidgets('referencing a base-currency receivable locks the rate to one', (
    tester,
  ) async {
    final api = await _pumpDraft(tester, ledgerCurrency: 'currency-cny');
    final rate = find.byKey(const ValueKey('finance-receipt-exchange-rate'));
    final before = tester.widget<TextField>(rate);
    before.controller!.text = '7.3';

    await _importFirstLedger(tester);

    final after = tester.widget<TextField>(rate);
    expect(after.controller!.text, '1');
    expect(after.readOnly, isTrue);
    expect(_receiptRow(tester).currencyId, 'currency-cny');
    expect(_receiptRow(tester).exchangeRate.text, '1');
    expect(api.lastPutBody, isNull);
  });

  testWidgets('empty payment-method dictionary does not block saving', (
    tester,
  ) async {
    final api = await _pumpDraft(
      tester,
      ledgerCurrency: 'currency-usd',
      financeMethods: const [],
    );
    final method = tester.widget<UtenDropdownField>(
      find.byWidgetPredicate(
        (widget) => widget is UtenDropdownField && widget.label == '收款方式',
      ),
    );
    expect(method.required, isFalse);
    expect(method.info, contains('暂无可选的收付款方式'));

    await tester.tap(find.text('保存').hitTestable());
    await tester.pump();

    expect(api.lastPutBody, isNull);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.map((n) => n.message), isNot(contains('请选择收款方式')));
    expect(notifications.single.message, '请至少引用一条应收明细');
  });

  testWidgets('empty receivable list offers switching to order prepayment', (
    tester,
  ) async {
    await _pumpDraft(tester, ledgerCurrency: null);
    expect(find.text('登记订单预收'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('receipt-import-ar')));
    await tester.pumpAndSettle();
    expect(find.textContaining('客户尚未发货时这里没有内容'), findsOneWidget);
    final switchButton = find.byKey(
      const ValueKey('ar-picker-switch-to-prepayment'),
    );
    expect(switchButton, findsOneWidget);

    await tester.tap(switchButton);
    await tester.pumpAndSettle();

    // 收款类型已切到预收(标题随之变)，并直接打开了销售订单选择器。
    expect(find.text('登记订单预收'), findsWidgets);
    expect(find.text('暂无已审销售订单'), findsOneWidget);
  });
}

Future<void> _importFirstLedger(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('receipt-import-ar')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('ar-ap-select-ledger-1')), findsOneWidget);
  await tester.tap(find.text('全选'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
  await tester.pumpAndSettle();
  expect(_receiptRow(tester).appliedLedgerId, 'ledger-1');
  expect(tester.takeException(), isNull);
}

FinanceGridRow _receiptRow(WidgetTester tester) => tester
    .widget<UtenEditableGrid<FinanceGridRow>>(
      find.byType(UtenEditableGrid<FinanceGridRow>),
    )
    .controller
    .rows
    .single;

Future<_DraftReceiptApi> _pumpDraft(
  WidgetTester tester, {
  required String? ledgerCurrency,
  List<Map<String, dynamic>> financeMethods = const [
    {
      'id': 'receipt-method-1',
      'code': 'REC-BANK',
      'name': '银行转账',
      'legacyNameConfirmed': true,
    },
  ],
}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _DraftReceiptApi(
    ledgerCurrency: ledgerCurrency,
    financeMethods: financeMethods,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        financeWriteAllDocumentScope(),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeViewAll,
          Perm.financeReceiptCreate,
          Perm.financeReceiptView,
          Perm.financeReceiptEdit,
          Perm.customerPrepaymentView,
        }),
      ],
      child: const MaterialApp(
        home: FinanceDocEditPage(
          docType: FinanceDocType.receipt,
          id: 'receipt-draft',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return api;
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'native-detail-reader', code: 'F', name: '测试财务'),
  );
}

class _DraftReceiptApi extends ApiClient {
  _DraftReceiptApi({required this.ledgerCurrency, required this.financeMethods})
    : super(Dio());

  /// null = 该客户没有任何未清应收(订单还没出货)。
  final String? ledgerCurrency;
  final List<Map<String, dynamic>> financeMethods;
  Map<String, dynamic>? lastPutBody;
  final sourceQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/receipts/shipment-sources') {
      sourceQueries.add(Map<String, dynamic>.from(query ?? {}));
      final currency = ledgerCurrency;
      return {
        'items': [
          if (currency != null)
            {
              'id': 'ledger-1',
              'direction': 'AR',
              'openItemKind': 'RECEIVABLE',
              'sourceDocType': 'SALES_SHIPMENT',
              'sourceDocId': 'shipment-1',
              'sourceDocNo': 'XSCK-001',
              'billNo': 'AR-001',
              'billDate': '2026-09-20',
              'clientId': 'client-1',
              'currencyId': currency,
              'currencyCode': currency == 'currency-usd' ? 'USD' : 'CNY',
              'amountOriginal': 100,
              'amountReceivedOriginal': 0,
              'amountWriteOffOriginal': 0,
              'prepaymentAppliedOriginal': '0.0000',
              'amountBalanceOriginal': 100,
              'salesOrderIds': ['order-1'],
              'salesOrderNos': ['XD-001'],
              'settled': false,
            },
        ],
        'page': 1,
        'size': 50,
        'total': currency == null ? 0 : 1,
        'totalPages': 1,
      };
    }
    if (path == '/finance/ar-ap') {
      throw StateError(
        'Receipt sources must use their scoped shipment endpoint.',
      );
    }
    if (path == '/sales/orders') {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 0,
      };
    }
    return financeReviewedDetailFixture(_draftDetail, FinanceDocType.receipt);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/clients/dict') {
      return const [
        {'id': 'client-1', 'name': '迈顿智能'},
      ];
    }
    if (path == '/master/accounts/dict' ||
        path == '/business-references/accounts') {
      return const [
        {
          'id': 'account-1',
          'code': 'ZH000001',
          'name': '人民币账户',
          'currencyId': 'currency-cny',
          'currencyCode': 'CNY',
          'currencyName': '人民币',
          'baseCurrency': true,
          'status': '使用',
        },
      ];
    }
    if (path == '/master/currencies/dict') {
      return const [
        {
          'id': 'currency-cny',
          'code': '001',
          'name': '人民币',
          'exchangeRate': 1,
          'baseCurrency': true,
        },
        {
          'id': 'currency-usd',
          'code': '002',
          'name': '美金',
          'exchangeRate': 7.3,
          'baseCurrency': false,
        },
      ];
    }
    if (path == '/master/reference-methods/finance') return financeMethods;
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    final command = Map<String, dynamic>.from(body! as Map);
    lastPutBody = Map<String, dynamic>.from(command['document'] as Map);
    return financeReviewReceiptFixture(
      path: path,
      command: command,
      result: _draftDetail,
    );
  }
}

/// 只选了客户、还没引用任何应收的货款收款草稿(汇率框此时是默认 1)。
const _draftDetail = <String, dynamic>{
  'id': 'receipt-draft',
  'version': 1,
  'makerId': 'maker-1',
  'billNo': 'XS-DRAFT-001',
  'billDate': '2026-09-21',
  'receiptKind': 'AR_SETTLEMENT',
  'clientId': 'client-1',
  'accountId': 'account-1',
  'settlementAuthorityVersion': 2,
  'settlementChannel': 'DIRECT_ACCOUNT',
  'exchangeRateSource': 'BANK_STATEMENT',
  'accountCurrencyId': 'currency-cny',
  'feeSettlementMode': 'NONE',
  'feeBearer': 'NONE',
  'status': 0,
  'items': <Object>[],
};
