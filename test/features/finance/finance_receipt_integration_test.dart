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

void main() {
  test('receipt line requires a positive rate and auto-converts to RMB', () {
    final row = FinanceGridRow(mode: ItemMode.settle);
    addTearDown(row.dispose);

    row.amount.text = '50';
    row.exchangeRate.text = '7.2';

    expect(row.localAmountNotifier.value, 360);
    expect(row.amountNotifier.value, 50);
  });

  testWidgets(
    'receipt editor uses referenced AR lines and submits line currency facts',
    (tester) async {
      final api = await _pumpEditor(tester, detail: _receiptDetail());

      final importAction = find.text('引用应收');
      final historyAction = find.text('查看历史');
      expect(importAction, findsOneWidget);
      expect(historyAction, findsOneWidget);
      expect(
        tester.getCenter(importAction).dx,
        lessThan(tester.getCenter(historyAction).dx),
      );
      expect(find.byType(ClientPickerField), findsOneWidget);
      expect(_dropdownWithLabel('币种'), findsNothing);
      expect(_textFieldWithLabel('汇率'), findsNothing);
      expect(_dropdownWithLabel('其它费用项目'), findsOneWidget);

      final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
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
      expect(grid.controller.rows.single.writeOff.text, '5');
      expect(grid.controller.rows.single.remark.text, '行备注');
      final currencyColumn = grid.columns.singleWhere(
        (column) => column.key == 'currency',
      );
      final rateColumn = grid.columns.singleWhere(
        (column) => column.key == 'exchangeRate',
      );
      expect(currencyColumn.label, '应收币别');
      expect(currencyColumn.required, isTrue);
      expect(rateColumn.label, '到账汇率');
      expect(rateColumn.required, isTrue);
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

      expect(find.text('本次收到金额（人民币） ¥360.00'), findsOneWidget);
      expect(find.text('冲销费用（人民币） ¥36.00'), findsOneWidget);
      expect(find.text('本次总收到金额（人民币） ¥396.00'), findsOneWidget);

      grid.controller.rows.single.amount.text = '50.1234';
      grid.controller.rows.single.exchangeRate.text = '7.200000';
      grid.controller.rows.single.writeOff.text = '5.0000';

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final body = api.lastPutBody;
      expect(body, isNotNull);
      expect(body!['clientId'], 'client-1');
      expect(body['accountId'], 'account-1');
      expect(body['receiptKind'], 'AR_SETTLEMENT');
      expect(body.containsKey('salesOrderId'), isFalse);
      expect(body['receiptMethodId'], 'receipt-method-1');
      expect(body['otherFeeStyleId'], 'expense-1');
      expect(body.containsKey('currencyId'), isFalse);
      expect(body.containsKey('exchangeRate'), isFalse);

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
      expect(item['writeOffAmount'], '5.0000');
      expect(item['remark'], '行备注');
      expect(item.containsKey('amountLocal'), isFalse);
    },
  );

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

  testWidgets('receipt save identifies an invalid rate as the arrival rate', (
    tester,
  ) async {
    final api = await _pumpEditor(tester, detail: _receiptDetail());
    final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
      find.byWidgetPredicate(
        (widget) => widget is UtenEditableGrid<FinanceGridRow>,
      ),
    );
    grid.controller.rows.single.exchangeRate.clear();

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(api.lastPutBody, isNull);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.single.message, '请填写大于 0 的到账汇率');
  });

  testWidgets('compact receipt keeps primary actions and summaries reachable', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      detail: _receiptDetail(),
      size: const Size(375, 900),
    );

    expect(find.byTooltip('资金引用').hitTestable(), findsOneWidget);
    expect(find.byTooltip('查看历史').hitTestable(), findsOneWidget);
    expect(find.text('保存').hitTestable(), findsOneWidget);
    expect(find.textContaining('本次收到金额（人民币）'), findsOneWidget);
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
      expect(find.text('本次收到金额（人民币）'), findsOneWidget);
      expect(find.text('360.00'), findsWidgets);
      expect(find.text('冲销费用（人民币）'), findsOneWidget);
      expect(find.text('36.00'), findsWidgets);
      expect(find.text('本次总收到金额（人民币）'), findsOneWidget);
      expect(find.text('冲减应收账面金额（人民币）'), findsOneWidget);
      expect(find.text('396.00'), findsOneWidget);

      for (final column in const [
        '应收单号',
        '币别',
        '本次收款金额',
        '汇率',
        '换算人民币',
        '冲销金额（原币）',
        '冲销人民币',
        '收款前未收',
        '收款后未收',
        '备注',
      ]) {
        expect(find.text(column), findsOneWidget);
      }
      expect(find.text('美元'), findsOneWidget);
      expect(find.text('50.00'), findsOneWidget);
      expect(find.text('7.2000'), findsOneWidget);
      expect(find.text('5.00'), findsOneWidget);
      expect(find.text('100.00'), findsOneWidget);
      expect(find.text('45.00'), findsOneWidget);
      expect(find.text('行备注'), findsOneWidget);
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final api = _ReceiptApi(detail);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
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
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _ReceiptApi(detail);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
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
  'billNo': 'XS202608080001',
  'billDate': '2026-08-08',
  'receiptKind': 'AR_SETTLEMENT',
  'clientId': 'client-1',
  'accountId': 'account-1',
  'receiptMethodId': 'receipt-method-1',
  'currencyId': 'currency-usd',
  'exchangeRate': 7.2,
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
      'writeOffAmount': 5,
      'writeOffLocal': 36,
      'balanceBeforeOriginal': 100,
      'balanceAfterOriginal': 45,
      'remark': '行备注',
    },
  ],
};

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _ReceiptApi extends ApiClient {
  _ReceiptApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;
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
    if (path == '/master/accounts/dict') {
      return const [
        {'id': 'account-1', 'name': '人民币账户'},
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
