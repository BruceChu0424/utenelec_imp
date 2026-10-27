import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_collapsible_section.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/widgets/customer_prepayment_receipt_fields.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';

import '../../support/document_scope_capability_overrides.dart';
import '../../support/native_detail_reader_overrides.dart';

void main() {
  testWidgets('桌面预收订单选择按钮位于后缀槽，与金额汇率输入框同为44高', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rate = TextEditingController(text: '7.123456');
    final amount = TextEditingController(text: '88.1234');
    addTearDown(rate.dispose);
    addTearDown(amount.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const <String>{}),
        ],
        child: MaterialApp(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: UtenControlTheme(
              child: CustomerPrepaymentReceiptFields(
                salesOrderId: 'order-1',
                salesOrderBillNo: 'XD-001',
                clientLabel: '甲客户',
                currencyLabel: '美元',
                exchangeRateController: rate,
                amountController: amount,
                enabled: true,
                onOrderSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final order = find.byKey(
      const ValueKey('customer-prepayment-receipt-order'),
    );
    final orderHeight = tester.getSize(order).height;
    expect(orderHeight, 44);
    for (final key in [
      'customer-prepayment-receipt-rate',
      'customer-prepayment-receipt-amount',
    ]) {
      expect(tester.getSize(find.byKey(ValueKey(key))).height, orderHeight);
    }
    expect(
      find.descendant(of: order, matching: find.text('更换')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('receipt models expose explicit kind and bound sales order', () {
    final list = FinanceDocListItem.fromJson(const {
      'id': 'receipt-1',
      'receiptKind': 'CUSTOMER_PREPAYMENT',
      'salesOrderId': 'order-1',
    });
    final detail = FinanceDocDetail.fromJson(_prepaymentDetail);

    expect(list.receiptKind, 'CUSTOMER_PREPAYMENT');
    expect(list.salesOrderId, 'order-1');
    expect(detail.receiptKind, 'CUSTOMER_PREPAYMENT');
    expect(detail.salesOrderId, 'order-1');
    expect(financeReceiptKindLabel(detail.receiptKind), '客户订单预收');
  });

  testWidgets('空预收订单字段在框内显示业务名称，金额和汇率仍保留空值', (tester) async {
    final rate = TextEditingController();
    final amount = TextEditingController();
    addTearDown(rate.dispose);
    addTearDown(amount.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CustomerPrepaymentReceiptFields(
              salesOrderId: null,
              salesOrderBillNo: null,
              clientLabel: '',
              currencyLabel: '',
              exchangeRateController: rate,
              amountController: amount,
              enabled: false,
              onOrderSelected: (_) => fail('disabled order cannot change'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final order = tester.widget<InputDecorator>(
      find.byKey(const ValueKey('customer-prepayment-receipt-order')),
    );
    expect(order.isEmpty, isTrue);
    expect(order.decoration.hintText, '销售订单');
    expect(find.text('尚未选择'), findsNothing);
    expect(rate.text, isEmpty);
    expect(amount.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('375px order prepayment locks identity and submits no lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _PrepaymentReceiptApi();
    final router = _receiptRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...nativeDetailReaderOverrides(includeSession: false),
          financeWriteAllDocumentScope(),
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeViewAll,
            Perm.financeReceiptCreate,
            Perm.financeReceiptEdit,
            Perm.customerPrepaymentView,
          }),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('登记订单预收'), findsWidgets);
    final orderField = tester.widget<InputDecorator>(
      find.byKey(const ValueKey('customer-prepayment-receipt-order')),
    );
    expect((orderField.decoration as UtenInputDecoration).info, contains('预收'));
    expect(find.text('XD-001'), findsWidgets);
    expect(find.textContaining('客户：甲客户'), findsOneWidget);
    expect(find.textContaining('币种：美元'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('finance-receipt-exchange-rate')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('customer-prepayment-receipt-amount')),
      findsOneWidget,
    );
    expect(find.byType(UtenEditableGrid<FinanceGridRow>), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('finance-receipt-bank-reference')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('finance-receipt-bank-reference')),
      findsOneWidget,
    );
    expect(find.text('本批预收 美元 88.1234 · 汇率 7.123456'), findsOneWidget);
    expect(find.text('真实账户实际入账 人民币 624.7432'), findsOneWidget);
    await _openArrivalDetails(tester);
    final arrivalField = find.byKey(
      const ValueKey('finance-receipt-account-amount'),
    );
    expect(
      find.ancestor(
        of: arrivalField,
        matching: find.byType(UtenCollapsibleSection),
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(arrivalField).controller!.text, '624.7432');
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('finance-receipt-bank-reference')),
        matching: find.byType(UtenCollapsibleSection),
      ),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      _textField('银行手续费(人民币)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(_textField('银行手续费(人民币)'), findsOneWidget);
    expect(_textField('其它费用(人民币)'), findsOneWidget);
    expect(find.text('保存').hitTestable(), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final body = api.lastPutBody;
    expect(body, isNotNull);
    expect(body?['receiptKind'], 'CUSTOMER_PREPAYMENT');
    expect(body?['salesOrderId'], 'order-1');
    expect(body?['clientId'], 'client-1');
    expect(body?['currencyId'], 'currency-usd');
    expect(body?['exchangeRate'], '7.123456');
    expect(body?['amountOriginal'], '88.1234');
    expect(body?['settlementAuthorityVersion'], 2);
    expect(body?['settlementChannel'], 'TRADE_AGENT_CONVERSION');
    expect(body?['settlementAgentSupplierId'], 'agent-1');
    expect(body?['accountCurrencyId'], 'currency-cny');
    expect(body?['accountAmount'], '624.7432');
    expect(body?['bankFeeAccountAmount'], '2.0000');
    expect(body?['otherFeeAccountAmount'], '1.0000');
    expect(body?['feeSettlementMode'], 'DEDUCTED_FROM_PROCEEDS');
    expect(body?['feeBearer'], 'COMPANY');
    expect(body?['items'], isEmpty);
    expect(body?.containsKey('bankFee'), isFalse);
    expect(body?.containsKey('otherFee'), isFalse);
    _expectSaved(tester, router);
  });
  testWidgets('无费用时只保留必要决策，选择扣费后展开，再选无费用清空并正常保存', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _PrepaymentReceiptApi(noFees: true);
    final router = _receiptRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...nativeDetailReaderOverrides(includeSession: false),
          financeWriteAllDocumentScope(),
          apiClientProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.financeViewAll,
            Perm.financeReceiptCreate,
            Perm.financeReceiptEdit,
            Perm.customerPrepaymentView,
          }),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openArrivalDetails(tester);
    expect(
      find.byKey(const ValueKey('finance-receipt-bank-fee-account-amount')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('finance-receipt-other-fee-account-amount')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('finance-receipt-bank-reference')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('finance-receipt-agent-statement-no')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('finance-receipt-account-amount')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '汇率来源',
      ),
      findsNothing,
    );
    final mode = find.byWidgetPredicate(
      (w) => w is UtenDropdownField && w.label == '费用结算方式',
    );
    await Scrollable.ensureVisible(tester.element(mode), alignment: 0.3);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: mode, matching: find.text('无费用')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从本批到账中扣除').last);
    await tester.pumpAndSettle();
    final bankFee = find.byKey(
      const ValueKey('finance-receipt-bank-fee-account-amount'),
    );
    expect(bankFee, findsOneWidget);
    await tester.enterText(bankFee, '2');
    await tester.tap(
      find.descendant(of: mode, matching: find.text('从本批到账中扣除')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('无费用').last);
    await tester.pumpAndSettle();
    expect(bankFee, findsNothing);
    await tester.tap(find.text('保存').hitTestable());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(api.lastPutBody?['feeSettlementMode'], 'NONE');
    expect(api.lastPutBody?['bankFeeAccountAmount'], '0.0000');
    expect(api.lastPutBody?['otherFeeAccountAmount'], '0.0000');
    expect(api.lastPutBody?['bankReference'], 'BANK-PREPAY-001');
    expect(api.lastPutBody?['agentStatementNo'], 'AGENT-PREPAY-001');
    expect(api.lastPutBody?['exchangeRateSource'], 'TRADE_AGENT_STATEMENT');
    expect(api.lastPutBody?['amountOriginal'], '88.1234');
    expect(api.lastPutBody?['accountAmount'], '627.7432');
    _expectSaved(tester, router);
  });
}

GoRouter _receiptRouter() => GoRouter(
  initialLocation: '/finance/receipts/receipt-1/edit',
  routes: [
    GoRoute(
      path: '/finance/receipts/:id/edit',
      builder: (_, state) => FinanceDocEditPage(
        docType: FinanceDocType.receipt,
        id: state.pathParameters['id'],
      ),
    ),
    GoRoute(
      path: '/finance/receipts/:id',
      builder: (_, state) => FinanceDocDetailPage(
        docType: FinanceDocType.receipt,
        id: state.pathParameters['id']!,
      ),
    ),
  ],
);

void _expectSaved(WidgetTester tester, GoRouter router) {
  expect(
    router.routeInformationProvider.value.uri.path,
    '/finance/receipts/receipt-1',
  );
  expect(find.byType(FinanceDocDetailPage), findsOneWidget);
  expect(find.byType(FinanceDocEditPage), findsNothing);
  expect(find.text('保存失败，请稍后重试'), findsNothing);
  expect(tester.takeException(), isNull);
}

Future<void> _openArrivalDetails(WidgetTester tester) async {
  final sectionFinder = find.byKey(
    const ValueKey('finance-receipt-settlement-fees'),
  );
  await tester.scrollUntilVisible(
    sectionFinder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  final section = tester.widget<UtenCollapsibleSection>(sectionFinder);
  if (!(section.expanded ?? section.initiallyExpanded)) {
    await tester.tap(
      find.descendant(of: sectionFinder, matching: find.text(section.title)),
    );
    await tester.pumpAndSettle();
  }
}

Finder _textField(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'native-detail-reader', code: 'reader', name: '测试读者'),
  );
}

class _PrepaymentReceiptApi extends ApiClient {
  _PrepaymentReceiptApi({this.noFees = false}) : super(Dio());
  final bool noFees;

  Map<String, dynamic>? lastPutBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/summary')) return _moneySummary;
    return noFees
        ? {
            ..._prepaymentDetail,
            'feeSettlementMode': 'NONE',
            'bankFeeAccountAmount': 0,
            'otherFeeAccountAmount': 0,
            'otherFeeStyleId': null,
            'accountAmount': 627.7432,
            'bankFee': 0,
            'otherFee': 0,
          }
        : _prepaymentDetail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/clients/lookup') {
      return [
        if (query?['ids'].toString().split(',').contains('client-1') ?? false)
          const {'id': 'client-1', 'name': '甲客户'},
      ];
    }
    if (path == '/master/accounts/dict') {
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
    if (path == '/master/suppliers/lookup') {
      return [
        if (query?['ids'].toString().split(',').contains('agent-1') ?? false)
          const {'id': 'agent-1', 'name': '测试外贸代理'},
      ];
    }
    if (path == '/master/currencies/dict') {
      return const [
        {'id': 'currency-usd', 'name': '美元'},
      ];
    }
    if (path == '/master/reference-methods/finance') {
      return const [
        {
          'id': 'receipt-method-1',
          'code': 'BANK',
          'name': '银行转账',
          'legacyNameConfirmed': true,
        },
      ];
    }
    if (path == '/master/payment-styles/tree' &&
        query?['category'] == 'EXPENSE') {
      return const [
        {
          'id': 'expense-1',
          'code': 'AGENT_FEE',
          'name': '外贸代理费',
          'category': 'EXPENSE',
          'children': <Map<String, dynamic>>[],
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return noFees
        ? {
            ..._prepaymentDetail,
            'feeSettlementMode': 'NONE',
            'bankFeeAccountAmount': 0,
            'otherFeeAccountAmount': 0,
            'otherFeeStyleId': null,
            'accountAmount': 627.7432,
            'bankFee': 0,
            'otherFee': 0,
          }
        : _prepaymentDetail;
  }
}

const _prepaymentDetail = <String, dynamic>{
  'id': 'receipt-1',
  'version': 2,
  'makerId': 'maker-1',
  'billNo': 'YS-001',
  'billDate': '2026-08-23',
  'receiptKind': 'CUSTOMER_PREPAYMENT',
  'salesOrderId': 'order-1',
  'clientId': 'client-1',
  'accountId': 'account-1',
  'currencyId': 'currency-usd',
  'exchangeRate': 7.123456,
  'amountOriginal': 88.1234,
  'amountLocal': 627.7432,
  'settlementAuthorityVersion': 1,
  'settlementChannel': 'TRADE_AGENT_CONVERSION',
  'settlementAgentSupplierId': 'agent-1',
  'exchangeRateSource': 'TRADE_AGENT_STATEMENT',
  'exchangeRateEffectiveAt': '2026-08-23T01:00:00Z',
  'bankBookedAt': '2026-08-23T02:00:00Z',
  'bankReference': 'BANK-PREPAY-001',
  'agentStatementNo': 'AGENT-PREPAY-001',
  'accountCurrencyId': 'currency-cny',
  'accountExchangeRate': 1,
  'accountAmount': 624.7432,
  'accountAmountLocal': 624.7432,
  'bankFeeAccountAmount': 2,
  'otherFeeAccountAmount': 1,
  'feeSettlementMode': 'DEDUCTED_FROM_PROCEEDS',
  'feeBearer': 'COMPANY',
  'feeAccountCurrencyId': 'currency-cny',
  'feeAccountExchangeRate': 1,
  'settlementGrossLocal': 627.7432,
  'bankFee': 2,
  'otherFee': 1,
  'otherFeeStyleId': 'expense-1',
  'receiptMethodId': 'receipt-method-1',
  'status': 0,
  'items': <Object>[],
};

const _moneySummary = <String, dynamic>{
  'salesOrderId': 'order-1',
  'orderBillNo': 'XD-001',
  'clientId': 'client-1',
  'currencyId': 'currency-usd',
  'currencyCode': 'USD',
  'orderTotalOriginal': '500.0000',
  'orderTotalLocal': '3561.7280',
  'formalArOriginal': '0.0000',
  'formalArLocal': '0.0000',
  'cashReceivedOriginal': '0.0000',
  'cashReceivedLocal': '0.0000',
  'writeOffOriginal': '0.0000',
  'writeOffLocal': '0.0000',
  'prepaymentReceivedOriginal': '0.0000',
  'prepaymentReceivedLocal': '0.0000',
  'prepaymentAppliedOriginal': '0.0000',
  'prepaymentAppliedSourceBookLocal': '0.0000',
  'prepaymentAppliedTargetBookLocal': '0.0000',
  'prepaymentExchangeDifferenceLocal': '0.0000',
  'prepaymentAvailableOriginal': '0.0000',
  'prepaymentAvailableLocal': '0.0000',
  'arOutstandingOriginal': '0.0000',
  'arOutstandingLocal': '0.0000',
  'unrecognizedOrderOriginal': '0.0000',
  'unrecognizedOrderLocal': '0.0000',
  'plannedRemainingOriginal': '500.0000',
  'overpaidOriginal': '0.0000',
  'hasUnallocated': false,
  'unallocatedReceiptLines': <Object>[],
  'warnings': <Object>[],
};
