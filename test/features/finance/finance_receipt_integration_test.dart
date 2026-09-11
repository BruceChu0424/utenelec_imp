import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_client_picker.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

void main() {
  test('receipt v1 model preserves exact authority snapshots', () {
    final detail = FinanceDocDetail.fromJson(_receiptDetail());

    expect(detail.version, 3);
    expect(detail.settlementAuthorityVersion, 1);
    expect(detail.accountCurrencyId, 'currency-cny');
    expect(detail.settlementAgentNameSnapshot, '历史外贸代理快照');
    expect(detail.settlementRateQuoteDirection, 'BASE_PER_SETTLEMENT');
    expect(detail.accountExchangeRateSource, 'BASE_CURRENCY_IDENTITY');
    expect(detail.accountAmountText, '324');
    expect(detail.settlementGrossLocalText, '360');
    expect(detail.bankFeeAccountAmountText, '20');
    expect(detail.feeBearer, 'COMPANY');
    expect(detail.items.single.writeOffAmountText, '0');
  });

  test('each receipt batch uses its own positive arrival rate', () {
    final row = FinanceGridRow(mode: ItemMode.settle);
    addTearDown(row.dispose);

    row.amount.text = '50';
    row.exchangeRate.text = '7.2';

    expect(row.localAmountExactNotifier.value, '360.0');
    expect(row.amountNotifier.value, 50);
  });

  testWidgets(
    'receipt editor uses referenced AR lines and submits line currency facts',
    (tester) async {
      final api = await _pumpEditor(tester, detail: _receiptDetail());

      final importAction = find.text('引用应收');
      expect(importAction, findsOneWidget);
      // 2026-09-10 返回键契约：编辑页不再提供「查看历史」跳列表入口（列表从 hub 进入，
      // 返回键 popOrBackTo 回来源页），顶栏只剩业务动作。
      expect(find.text('查看历史'), findsNothing);
      expect(find.byType(ClientPickerField), findsOneWidget);
      expect(_dropdownWithLabel('币种'), findsNothing);
      expect(_textFieldWithLabel('汇率'), findsNothing);
      expect(_dropdownWithLabel('其它费用项目'), findsOneWidget);

      var grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
        find.byWidgetPredicate(
          (widget) => widget is UtenEditableGrid<FinanceGridRow>,
        ),
      );
      expect(grid.showAddRow, isFalse);
      expect(grid.controller.length, 1);
      expect(grid.controller.rows.single.appliedLedgerId, 'ledger-1');
      expect(grid.controller.rows.single.currencyId, 'currency-usd');
      expect(grid.controller.rows.single.exchangeRate.text, '7.2');
      expect(grid.controller.rows.single.amount.text, '50');
      expect(grid.controller.rows.single.writeOff.text, '0');
      expect(grid.controller.rows.single.remark.text, '行备注');
      expect(grid.columns.map((column) => column.key), [
        'appliedBillNo',
        'balanceOriginal',
        'amount',
        'currency',
        'balanceAfter',
        'remark',
      ]);
      final originalController = grid.controller;
      final reconciliationToggle = find.byKey(
        const ValueKey('finance-receipt-reconciliation-toggle'),
      );
      await tester.ensureVisible(reconciliationToggle);
      await tester.tap(reconciliationToggle);
      await tester.pumpAndSettle();
      grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
        find.byWidgetPredicate(
          (widget) => widget is UtenEditableGrid<FinanceGridRow>,
        ),
      );
      expect(grid.controller, same(originalController));
      expect(grid.controller.rows.single.amount.text, '50');
      final currencyColumn = grid.columns.singleWhere(
        (column) => column.key == 'currency',
      );
      final rateColumn = grid.columns.singleWhere(
        (column) => column.key == 'exchangeRate',
      );
      expect(currencyColumn.label, '应收币种');
      expect(currencyColumn.required, isTrue);
      expect(rateColumn.label, '批次汇率');
      expect(rateColumn.required, isFalse);
      final accountField = tester.widget<UtenDropdownField>(
        _dropdownWithLabel('真实收款账户'),
      );
      expect(accountField.items.single.label, 'ZH000001 · 人民币账户 · 人民币');
      expect(find.textContaining('另付费用单独记录'), findsOneWidget);
      expect(
        grid.columns.map((column) => column.label),
        containsAllInOrder(const [
          '来源类型 / 单号',
          '销售订单号',
          '应收总额',
          '累计已收',
          '累计冲销',
          '预收已抵',
          '本次可收',
        ]),
      );
      final currencyCell = currencyColumn.cellBuilder(
        tester.element(find.byType(FinanceDocEditPage)),
        grid.controller.rows.single,
      );
      expect(currencyCell, isA<Text>());
      expect((currencyCell as Text).data, '美元');

      expect(find.text('本批客户已付(人民币) ¥360.00'), findsOneWidget);
      expect(find.text('费用 人民币 36.00'), findsOneWidget);
      expect(find.text('真实账户实际入账 人民币 324.00'), findsOneWidget);

      await tester.tap(reconciliationToggle);
      await tester.pumpAndSettle();
      expect(find.text('查看对账明细'), findsOneWidget);

      grid.controller.rows.single.amount.text = '50.1234';
      final accountAmount = tester.widget<TextField>(
        find.byKey(const ValueKey('finance-receipt-account-amount')),
      );
      accountAmount.controller!.text = '324.8885';
      await tester.pump();
      expect(find.text('本批客户已付(人民币) ¥360.8885'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final body = api.lastPutBody;
      expect(body, isNotNull);
      expect(body!['clientId'], 'client-1');
      expect(body['accountId'], 'account-1');
      expect(body['receiptKind'], 'AR_SETTLEMENT');
      expect(body['settlementAuthorityVersion'], 2);
      expect(body['expectedVersion'], 3);
      expect(body['settlementChannel'], 'TRADE_AGENT_CONVERSION');
      expect(body['settlementAgentSupplierId'], 'agent-1');
      expect(body['exchangeRateSource'], 'TRADE_AGENT_STATEMENT');
      expect(body['exchangeRateEffectiveAt'], '2026-08-08T01:00:00.000Z');
      expect(body['bankBookedAt'], '2026-08-08T02:00:00.000Z');
      expect(body['bankReference'], 'BANK-20260808-001');
      expect(body['agentStatementNo'], 'AGENT-20260808-001');
      expect(body['accountCurrencyId'], 'currency-cny');
      expect(body['accountAmount'], '324.8885');
      expect(body['bankFeeAccountAmount'], '20.0000');
      expect(body['otherFeeAccountAmount'], '16.0000');
      expect(body['feeSettlementMode'], 'DEDUCTED_FROM_PROCEEDS');
      expect(body['feeBearer'], 'COMPANY');
      expect(body.containsKey('salesOrderId'), isFalse);
      expect(body['receiptMethodId'], 'receipt-method-1');
      expect(body['otherFeeStyleId'], 'expense-1');
      expect(body['currencyId'], 'currency-usd');
      expect(body['exchangeRate'], '7.200000');
      expect(body['amountOriginal'], '50.1234');

      final item = Map<String, dynamic>.from(
        (body['items'] as List<dynamic>).single as Map,
      );
      expect(item['appliedLedgerId'], 'ledger-1');
      expect(item['appliedBillNo'], 'AR-001');
      expect(item.containsKey('salesOrderId'), isFalse);
      expect(item['clientId'], 'client-1');
      expect(item['currencyId'], 'currency-usd');
      expect(item['exchangeRate'], '7.200000');
      expect(item['amountOriginal'], '50.1234');
      expect(item['writeOffAmount'], '0.0000');
      expect(item['remark'], '行备注');
      expect(item.containsKey('amountLocal'), isFalse);
    },
  );

  testWidgets('third-currency receipt account is rejected before API', (
    tester,
  ) async {
    final api = await _pumpEditor(
      tester,
      detail: _receiptDetail(),
      accountBaseCurrency: false,
      accountCurrencyId: 'currency-eur',
      accountCurrencyCode: 'EUR',
      accountCurrencyName: '欧元',
    );

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(api.lastPutBody, isNull);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.single.message, contains('暂不支持第三币种收款'));
  });

  testWidgets('real USD account accepts direct same-currency receipt', (
    tester,
  ) async {
    final detail = _receiptDetail()
      ..['settlementChannel'] = 'DIRECT_ACCOUNT'
      ..['settlementAgentSupplierId'] = null
      ..['exchangeRateSource'] = 'BANK_STATEMENT'
      ..['agentStatementNo'] = null
      ..['accountCurrencyId'] = 'currency-usd'
      ..['accountExchangeRate'] = 7.2
      ..['accountAmount'] = 50
      ..['accountAmountLocal'] = 360
      ..['bankFeeAccountAmount'] = 0
      ..['otherFeeAccountAmount'] = 0
      ..['otherFeeStyleId'] = null
      ..['feeSettlementMode'] = 'NONE'
      ..['feeBearer'] = 'NONE'
      ..['feeAccountCurrencyId'] = 'currency-usd';
    final api = await _pumpEditor(
      tester,
      detail: detail,
      accountBaseCurrency: false,
    );

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNotNull);
    expect(api.lastPutBody!['settlementChannel'], 'DIRECT_ACCOUNT');
    expect(api.lastPutBody!['accountCurrencyId'], 'currency-usd');
    expect(api.lastPutBody!['accountAmount'], '50.0000');
    expect(api.lastPutBody!['bankFeeAccountAmount'], '0.0000');
    expect(api.lastPutBody!['feeBearer'], 'NONE');
  });

  testWidgets('direct bank conversion can post to the real CNY account', (
    tester,
  ) async {
    final detail = _receiptDetail()
      ..['settlementChannel'] = 'DIRECT_ACCOUNT'
      ..['settlementAgentSupplierId'] = null
      ..['exchangeRateSource'] = 'BANK_STATEMENT'
      ..['agentStatementNo'] = null;
    final api = await _pumpEditor(tester, detail: detail);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final body = api.lastPutBody;
    expect(body, isNotNull);
    expect(body!['settlementChannel'], 'DIRECT_ACCOUNT');
    expect(body['exchangeRateSource'], 'BANK_STATEMENT');
    expect(body['settlementAgentSupplierId'], isNull);
    expect(body['agentStatementNo'], isNull);
    expect(body['accountCurrencyId'], 'currency-cny');
    expect(body['accountAmount'], '324.0000');
  });

  for (final actual in [
    '49.999999999999999999999999',
    '50.000000000000000000000001',
  ]) {
    testWidgets('same-currency actual bank amount $actual cannot become FX', (
      tester,
    ) async {
      final detail = _receiptDetail()
        ..['settlementAuthorityVersion'] = 2
        ..['settlementChannel'] = 'DIRECT_ACCOUNT'
        ..['exchangeRateSource'] = 'BANK_STATEMENT'
        ..['accountCurrencyId'] = 'currency-usd'
        ..['accountAmountExact'] = actual
        ..['bankFeeAccountAmount'] = 0
        ..['otherFeeAccountAmount'] = 0
        ..['otherFeeStyleId'] = null
        ..['feeSettlementMode'] = 'NONE';
      final api = await _pumpEditor(
        tester,
        detail: detail,
        accountBaseCurrency: false,
      );
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(api.lastPutBody, isNull);
      final notifications = ProviderScope.containerOf(
        tester.element(find.byType(FinanceDocEditPage)),
      ).read(appNotificationProvider);
      expect(notifications.single.message, contains('差额不能作为汇兑处理'));
    });
  }

  testWidgets(
    'V2 same-currency bank facts keep 24 digits and full 30-digit book preview',
    (tester) async {
      const amount = '0.000000000000000000000001';
      const local = '0.000000000000000000000007000001';
      final detail = _receiptDetail()
        ..['settlementAuthorityVersion'] = 2
        ..['settlementChannel'] = 'DIRECT_ACCOUNT'
        ..['exchangeRateSource'] = 'BANK_STATEMENT'
        ..['accountCurrencyId'] = 'currency-usd'
        ..['exchangeRateExact'] = '7.000001'
        ..['accountAmountExact'] = amount
        ..['bankFeeAccountAmount'] = 0
        ..['otherFeeAccountAmount'] = 0
        ..['otherFeeStyleId'] = null
        ..['feeSettlementMode'] = 'NONE';
      ((detail['items'] as List).single
              as Map<String, dynamic>)['amountOriginalExact'] =
          amount;
      final api = await _pumpEditor(
        tester,
        detail: detail,
        accountBaseCurrency: false,
      );
      expect(find.text('本批客户已付折合(人民币) ¥$local'), findsOneWidget);
      final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
        find.byWidgetPredicate(
          (widget) => widget is UtenEditableGrid<FinanceGridRow>,
        ),
      );
      expect(grid.controller.rows.single.amount.text, amount);
      expect(grid.controller.rows.single.localAmountExactNotifier.value, local);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.lastPutBody?['settlementAuthorityVersion'], 2);
      expect(api.lastPutBody?['amountOriginal'], amount);
      expect(api.lastPutBody?['accountAmount'], amount);
      expect(api.lastPutBody?['exchangeRate'], '7.000001');
      expect(api.lastPutBody?.containsKey('amountLocal'), isFalse);
    },
  );

  testWidgets(
    'V2 detail uses exact frozen bank facts and never labels itself legacy',
    (tester) async {
      const local = '360.000000000000000000000000000001';
      final detail = _receiptDetail()
        ..['status'] = 1
        ..['settlementAuthorityVersion'] = 2
        ..['settlementGrossLocalExact'] = local;
      await _pumpDetail(tester, detail: detail);
      expect(find.text('实际银行到账与本批结算分别记录'), findsOneWidget);
      expect(find.text('本批客户已付(人民币)'), findsOneWidget);
      expect(find.text(local), findsOneWidget);
      expect(find.text('历史口径未分层'), findsNothing);
      expect(find.text('本批汇率报价'), findsWidgets);
    },
  );

  testWidgets('separately-paid fees post from the selected real account', (
    tester,
  ) async {
    final detail = _receiptDetail()
      ..['feeSettlementMode'] = 'PAID_SEPARATELY'
      ..['feePaymentAccountId'] = 'fee-account-cny'
      ..['accountAmount'] = 360;
    final api = await _pumpEditor(
      tester,
      detail: detail,
      includeFeeAccount: true,
    );
    expect(find.text('本批客户已付(人民币) ¥360.00'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(api.lastPutBody, isNotNull);
    expect(api.lastPutBody!['feeSettlementMode'], 'PAID_SEPARATELY');
    expect(api.lastPutBody!['feeBearer'], 'COMPANY');
    expect(api.lastPutBody!['feePaymentAccountId'], 'fee-account-cny');
    expect(api.lastPutBody!['accountAmount'], '360.0000');
  });

  testWidgets('account authority load failure prevents receipt save', (
    tester,
  ) async {
    final api = await _pumpEditor(
      tester,
      detail: _receiptDetail(),
      failAccounts: true,
    );

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(api.lastPutBody, isNull);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.single.message, contains('账户币种资料未加载成功'));
  });

  testWidgets('cancelling client clear keeps customer and referenced lines', (
    tester,
  ) async {
    await _pumpEditor(tester, detail: _receiptDetail());

    await tester.tap(
      find.descendant(
        of: find.byType(ClientPickerField),
        matching: find.byTooltip('清除选择'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('更换客户'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '取消'),
      ),
    );
    await tester.pumpAndSettle();

    final clientTextField = tester.widget<TextField>(
      find.descendant(
        of: find.byType(ClientPickerField),
        matching: find.byType(TextField),
      ),
    );
    expect(clientTextField.controller?.text, '甲客户');
    final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
      find.byWidgetPredicate(
        (widget) => widget is UtenEditableGrid<FinanceGridRow>,
      ),
    );
    expect(grid.controller.length, 1);
    expect(grid.controller.rows.single.appliedBillNo, 'AR-001');
  });

  testWidgets('receipt save rejects a document without referenced AR lines', (
    tester,
  ) async {
    final detail = _receiptDetail()..['items'] = <Map<String, dynamic>>[];
    final api = await _pumpEditor(tester, detail: detail);

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(api.lastPutBody, isNull);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.single.message, '请至少引用一条应收明细');
    expect(find.text('暂无明细，请点击顶部“引用应收”添加'), findsOneWidget);
  });

  testWidgets(
    'receipt save identifies an invalid rate as this batch arrival rate',
    (tester) async {
      final api = await _pumpEditor(tester, detail: _receiptDetail());
      final rate = tester.widget<TextField>(
        find.byKey(const ValueKey('finance-receipt-exchange-rate')),
      );
      rate.controller!.clear();

      await tester.tap(find.text('保存'));
      await tester.pump();

      expect(api.lastPutBody, isNull);
      final notifications = ProviderScope.containerOf(
        tester.element(find.byType(FinanceDocEditPage)),
      ).read(appNotificationProvider);
      expect(notifications.single.message, '请填写大于 0、最多 6 位小数的本批汇率报价');
    },
  );

  testWidgets('compact receipt keeps primary actions and summaries reachable', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      detail: _receiptDetail(),
      size: const Size(375, 900),
    );

    expect(find.byTooltip('资金引用').hitTestable(), findsOneWidget);
    expect(find.byTooltip('查看历史'), findsNothing);
    expect(find.text('保存').hitTestable(), findsOneWidget);
    expect(find.text('本批客户已付(人民币) ¥360.00'), findsOneWidget);
    expect(find.text('真实账户实际入账 人民币 324.00'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('资金引用'));
    await tester.pumpAndSettle();
    expect(find.text('引用应收'), findsOneWidget);
    expect(find.text('应用预收'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact fund menu exposes prepayment only with both permissions',
    (tester) async {
      await _pumpEditor(
        tester,
        detail: _receiptDetail(),
        size: const Size(375, 900),
        permissions: const {
          Perm.financeViewAll,
          Perm.customerPrepaymentView,
          Perm.customerPrepaymentApply,
        },
      );

      await tester.tap(find.byTooltip('资金引用'));
      await tester.pumpAndSettle();

      expect(find.text('引用应收'), findsOneWidget);
      expect(find.text('应用预收'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'receipt detail shows line currency conversion and balance facts',
    (tester) async {
      await _pumpDetail(tester, detail: _receiptDetail());

      expect(find.text('其它费用项目'), findsOneWidget);
      expect(find.text('银行费用'), findsOneWidget);
      expect(find.text('V1 到账与 AR 核销分层'), findsOneWidget);
      expect(find.text('外贸代理代收结汇'), findsOneWidget);
      expect(find.text('历史外贸代理快照'), findsOneWidget);
      expect(find.text('汇率报价方向'), findsOneWidget);
      expect(find.text('本位币/结算原币（1 原币对应本位币金额）'), findsOneWidget);
      expect(find.text('账户折算汇率来源'), findsOneWidget);
      expect(find.text('本位币同值'), findsOneWidget);
      expect(find.text('本批结算毛额(人民币)'), findsOneWidget);
      expect(find.text('360.00'), findsWidgets);
      expect(find.text('真实账户实际入账(人民币)'), findsOneWidget);
      expect(find.text('324.00'), findsWidgets);
      expect(find.text('银行手续费(人民币)'), findsOneWidget);
      expect(find.text('20.00'), findsWidgets);
      expect(find.text('其它费用(人民币)'), findsOneWidget);
      expect(find.text('16.00'), findsWidgets);
      expect(find.text('费用承担方'), findsOneWidget);
      expect(find.text('本公司承担'), findsOneWidget);
      expect(find.text('冲减应收账面金额(人民币)'), findsWidgets);
      expect(find.text('汇兑差额(人民币)'), findsOneWidget);
      expect(find.text('350.00'), findsWidgets);
      expect(find.text('10.00'), findsWidgets);

      for (final column in const [
        '应收单号',
        '应收币种',
        '本次分配收款(原币)',
        '当前批次实际到账汇率',
        '分配折算毛额(人民币)',
        '冲减应收账面金额(人民币)',
        '汇兑差额(人民币)',
        '收款前未收',
        '收款后未收',
        '备注',
      ]) {
        expect(
          find.text(column),
          column == '应收币种' ||
                  column == '分配折算毛额(人民币)' ||
                  column == '冲减应收账面金额(人民币)'
              ? findsWidgets
              : findsOneWidget,
        );
      }
      expect(find.text('美元'), findsWidgets);
      expect(find.text('50.00'), findsWidgets);
      expect(find.text('7.2'), findsWidgets);
      expect(find.text('100.00'), findsOneWidget);
      expect(find.text('50.00'), findsWidgets);
      expect(find.text('行备注'), findsOneWidget);
    },
  );

  testWidgets(
    'real USD account labels local amount as book conversion, not RMB cash entry',
    (tester) async {
      final detail = _receiptDetail()
        ..['settlementChannel'] = 'DIRECT_ACCOUNT'
        ..['settlementAgentSupplierId'] = null
        ..['exchangeRateSource'] = 'BANK_STATEMENT'
        ..['agentStatementNo'] = null
        ..['accountCurrencyId'] = 'currency-usd'
        ..['accountExchangeRate'] = 7.2
        ..['accountAmount'] = 50
        ..['accountAmountLocal'] = 360
        ..['bankFeeAccountAmount'] = 0
        ..['otherFeeAccountAmount'] = 0
        ..['feeSettlementMode'] = 'NONE'
        ..['feeBearer'] = 'NONE'
        ..['feeAccountCurrencyId'] = 'currency-usd';
      await _pumpDetail(tester, detail: detail, accountBaseCurrency: false);

      expect(find.text('真实账户直接到账'), findsOneWidget);
      expect(find.text('真实账户实际入账(美元)'), findsOneWidget);
      expect(find.text('实际入账本位币(人民币)'), findsOneWidget);
      expect(find.textContaining('人民币实际入账'), findsNothing);
    },
  );
}

Finder _dropdownWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == label,
);

Finder _textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<_ReceiptApi> _pumpEditor(
  WidgetTester tester, {
  required Map<String, dynamic> detail,
  Size size = const Size(1600, 1200),
  Set<String> permissions = const {},
  bool accountBaseCurrency = true,
  String? accountCurrencyId,
  String? accountCurrencyCode,
  String? accountCurrencyName,
  bool includeFeeAccount = false,
  bool failAccounts = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final api = _ReceiptApi(
    detail,
    accountBaseCurrency: accountBaseCurrency,
    accountCurrencyId: accountCurrencyId,
    accountCurrencyCode: accountCurrencyCode,
    accountCurrencyName: accountCurrencyName,
    includeFeeAccount: includeFeeAccount,
    failAccounts: failAccounts,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        financeWriteAllDocumentScope(),
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        home: FinanceDocEditPage(
          docType: FinanceDocType.receipt,
          id: detail['id'] as String,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  required Map<String, dynamic> detail,
  bool accountBaseCurrency = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _ReceiptApi(detail, accountBaseCurrency: accountBaseCurrency);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        financeWriteAllDocumentScope(),
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        home: FinanceDocDetailPage(
          docType: FinanceDocType.receipt,
          id: detail['id'] as String,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _receiptDetail() => <String, dynamic>{
  'id': 'receipt-1',
  'version': 3,
  'makerId': 'maker-1',
  'billNo': 'XS202608080001',
  'billDate': '2026-08-08',
  'receiptKind': 'AR_SETTLEMENT',
  'clientId': 'client-1',
  'accountId': 'account-1',
  'receiptMethodId': 'receipt-method-1',
  'currencyId': 'currency-usd',
  'exchangeRate': 7.2,
  'amountOriginal': 50,
  'settlementAuthorityVersion': 1,
  'settlementChannel': 'TRADE_AGENT_CONVERSION',
  'settlementAgentSupplierId': 'agent-1',
  'settlementAgentNameSnapshot': '历史外贸代理快照',
  'settlementRateQuoteDirection': 'BASE_PER_SETTLEMENT',
  'exchangeRateSource': 'TRADE_AGENT_STATEMENT',
  'exchangeRateEffectiveAt': '2026-08-08T01:00:00Z',
  'bankBookedAt': '2026-08-08T02:00:00Z',
  'bankReference': 'BANK-20260808-001',
  'agentStatementNo': 'AGENT-20260808-001',
  'accountCurrencyId': 'currency-cny',
  'accountExchangeRate': 1,
  'accountExchangeRateSource': 'BASE_CURRENCY_IDENTITY',
  'accountAmount': 324,
  'accountAmountLocal': 324,
  'bankFeeAccountAmount': 20,
  'otherFeeAccountAmount': 16,
  'feeSettlementMode': 'DEDUCTED_FROM_PROCEEDS',
  'feeBearer': 'COMPANY',
  'feeAccountCurrencyId': 'currency-cny',
  'feeAccountExchangeRate': 1,
  'settlementGrossLocal': 360,
  'bankFee': 20,
  'otherFee': 16,
  'otherFeeStyleId': 'expense-1',
  'invoiceNo': 'INV-1',
  'status': 0,
  'items': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'receipt-item-1',
      'appliedLedgerId': 'ledger-1',
      'appliedBillNo': 'AR-001',
      'salesOrderId': 'order-1',
      'clientId': 'client-1',
      'currencyId': 'currency-usd',
      'exchangeRate': 7.2,
      'amountOriginal': 50,
      'amountLocal': 360,
      'writeOffAmount': 0,
      'writeOffLocal': 0,
      'appliedAmountLocal': 350,
      'exchangeDiff': 10,
      'balanceBeforeOriginal': 100,
      'balanceAfterOriginal': 50,
      'remark': '行备注',
    },
  ],
};

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _ReceiptApi extends ApiClient {
  _ReceiptApi(
    this.detail, {
    this.accountBaseCurrency = true,
    this.accountCurrencyId,
    this.accountCurrencyCode,
    this.accountCurrencyName,
    this.includeFeeAccount = false,
    this.failAccounts = false,
  }) : super(Dio());

  final Map<String, dynamic> detail;
  final bool accountBaseCurrency;
  final String? accountCurrencyId;
  final String? accountCurrencyCode;
  final String? accountCurrencyName;
  final bool includeFeeAccount;
  final bool failAccounts;
  Map<String, dynamic>? lastPutBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/clients/dict') {
      return const [
        {'id': 'client-1', 'name': '甲客户'},
      ];
    }
    if (path == '/master/suppliers/dict') {
      return const [
        {'id': 'agent-1', 'name': '测试外贸代理'},
      ];
    }
    if (path == '/master/accounts/dict') {
      if (failAccounts) throw StateError('offline');
      final resolvedCurrencyId =
          accountCurrencyId ??
          (accountBaseCurrency ? 'currency-cny' : 'currency-usd');
      final resolvedCurrencyCode =
          accountCurrencyCode ?? (accountBaseCurrency ? 'CNY' : 'USD');
      final resolvedCurrencyName =
          accountCurrencyName ?? (accountBaseCurrency ? '人民币' : '美元');
      return [
        {
          'id': 'account-1',
          'code': 'ZH000001',
          'name': '$resolvedCurrencyName账户',
          'currencyId': resolvedCurrencyId,
          'currencyCode': resolvedCurrencyCode,
          'currencyName': resolvedCurrencyName,
          'baseCurrency': accountBaseCurrency,
          'status': '使用',
        },
        if (includeFeeAccount)
          {
            'id': 'fee-account-cny',
            'code': 'ZH-FEE',
            'name': '费用人民币账户',
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
        {'id': 'currency-usd', 'name': '美元'},
        {'id': 'currency-cny', 'name': '人民币'},
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
          'code': 'BANK_FEE',
          'name': '银行费用',
          'category': 'EXPENSE',
          'children': <Map<String, dynamic>>[],
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail;
  }
}
