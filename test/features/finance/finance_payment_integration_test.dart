import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

void main() {
  test(
    'payment editor sends command idempotency and optimistic version facts',
    () {
      final source = File(
        'lib/features/finance/pages/finance_doc_edit_page.dart',
      ).readAsStringSync();
      expect(
        source,
        contains(
          'if (_cfg.type == FinanceDocType.payment && widget.id == null)',
        ),
      );
      expect(source, contains("'createIdempotencyKey': _createIdempotencyKey"));
      expect(source, contains("'expectedVersion': _expectedVersion"));
    },
  );

  testWidgets(
    'payment without AP fails closed until supplier prepayment chain exists',
    (tester) async {
      final api = await _pumpEditor(tester, detail: _directPaymentDetail());

      final currency = tester.widget<UtenDropdownField>(
        _dropdownWithLabel('币种'),
      );
      expect(currency.required, isTrue);

      final rate = tester.widget<TextField>(
        find.byKey(const ValueKey('finance-payment-exchange-rate')),
      );
      expect(rate.controller?.text, '7.2');
      expect(
        find.byKey(const ValueKey('finance-payment-amount-original')),
        findsNothing,
      );
      expect(find.text('请先引用已入账应付；供应商预付链尚未开放'), findsOneWidget);
      expect(find.textContaining('预计本币 ¥720.00'), findsOneWidget);

      final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
        _financeGrid(),
      );
      expect(grid.showAddRow, isFalse);
      expect(grid.controller, isEmpty);
      expect(find.text('暂无应付核销明细，请点击顶部“引用应付”添加'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(api.lastPutBody, isNull);
      final notifications = ProviderScope.containerOf(
        tester.element(find.byType(FinanceDocEditPage)),
      ).read(appNotificationProvider);
      expect(notifications.single.message, contains('供应商预付资产'));
    },
  );

  testWidgets(
    'payment rate has no silent default and rejects non-positive input',
    (tester) async {
      final detail = _directPaymentDetail()..remove('exchangeRate');
      final api = await _pumpEditor(tester, detail: detail);

      final rate = tester.widget<TextField>(
        find.byKey(const ValueKey('finance-payment-exchange-rate')),
      );
      expect(rate.controller?.text, isEmpty);

      await tester.tap(find.text('保存'));
      await tester.pump();

      expect(api.lastPutBody, isNull);
      final notifications = ProviderScope.containerOf(
        tester.element(find.byType(FinanceDocEditPage)),
      ).read(appNotificationProvider);
      expect(notifications.single.message, '请填写大于 0 的付款汇率');
      expect(find.text('请填写大于 0 的付款汇率'), findsOneWidget);
    },
  );

  testWidgets('legacy direct payment amount cannot bypass AP requirement', (
    tester,
  ) async {
    final detail = _directPaymentDetail()..remove('amountOriginal');
    final api = await _pumpEditor(tester, detail: detail);

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(api.lastPutBody, isNull);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.single.message, contains('供应商预付资产'));
    expect(find.text('请先引用已入账应付；供应商预付链尚未开放'), findsOneWidget);
  });

  testWidgets(
    'compact direct payment keeps required facts and save reachable',
    (tester) async {
      await _pumpEditor(
        tester,
        detail: _directPaymentDetail(),
        size: const Size(375, 900),
      );

      expect(
        find.byKey(const ValueKey('finance-payment-exchange-rate')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('finance-payment-amount-original')),
        findsNothing,
      );
      expect(find.textContaining('供应商预付链尚未开放'), findsOneWidget);
      expect(find.text('保存').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('AP payment submits only requested original amount facts', (
    tester,
  ) async {
    final api = await _pumpEditor(tester, detail: _appliedPaymentDetail());

    expect(
      find.byKey(const ValueKey('finance-payment-amount-original')),
      findsNothing,
    );
    expect(find.text('由服务端按应付核销明细汇总'), findsOneWidget);

    final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
      _financeGrid(),
    );
    expect(grid.showAddRow, isFalse);
    expect(grid.controller.length, 1);
    expect(grid.controller.rows.single.appliedLedgerId, 'ledger-1');
    grid.controller.rows.single.amount.text = '50.1234';

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final body = api.lastPutBody;
    expect(body, isNotNull);
    expect(body!.containsKey('amountOriginal'), isFalse);
    expect(body['expectedVersion'], 3);
    expect(body['currencyId'], 'currency-usd');
    expect(body['exchangeRate'], '7.200000');
    final item = Map<String, dynamic>.from(
      (body['items'] as List<dynamic>).single as Map,
    );
    expect(item['appliedLedgerId'], 'ledger-1');
    expect(item['appliedBillNo'], 'AP-001');
    expect(item['amountOriginal'], '50.1234');
    expect(item.containsKey('amountLocal'), isFalse);
    expect(item.containsKey('appliedAmountLocal'), isFalse);
    expect(item.containsKey('exchangeDiff'), isFalse);
  });

  testWidgets(
    'AP picker blocks incomplete and mixed currencies then locks payment currency',
    (tester) async {
      final detail = _directPaymentDetail()..remove('currencyId');
      final api = await _pumpEditor(
        tester,
        detail: detail,
        ledgerItems: _apPickerItems(),
      );

      expect(
        tester.widget<UtenDropdownField>(_dropdownWithLabel('币种')).enabled,
        isTrue,
      );
      await tester.tap(find.text('引用应付'));
      await tester.pumpAndSettle();

      for (final label in const [
        '应付单号',
        '关联单号',
        '应付金额',
        '已付金额',
        '未付金额',
        '本次付款金额',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('搜索应付单号、关联单号或供应商'), findsOneWidget);

      Checkbox checkbox(String id) =>
          tester.widget<Checkbox>(find.byKey(ValueKey('ar-ap-select-$id')));

      expect(checkbox('ap-usd').onChanged, isNotNull);
      expect(checkbox('ap-eur').onChanged, isNotNull);
      expect(checkbox('ap-incomplete').onChanged, isNull);
      expect(find.text('待财务核验'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ar-ap-select-ap-usd')));
      await tester.pump();

      expect(checkbox('ap-usd').value, isTrue);
      expect(checkbox('ap-eur').onChanged, isNull);
      expect(checkbox('ap-incomplete').onChanged, isNull);
      expect(find.text('本次币种：USD'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
      await tester.pumpAndSettle();

      final lockedCurrency = tester.widget<UtenDropdownField>(
        _dropdownWithLabel('币种'),
      );
      expect(lockedCurrency.value, 'currency-usd');
      expect(lockedCurrency.enabled, isFalse);
      final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
        _financeGrid(),
      );
      expect(grid.controller.length, 1);
      expect(grid.controller.rows.single.currencyId, 'currency-usd');

      await tester.tap(find.text('引用应付'));
      await tester.pumpAndSettle();
      expect(checkbox('ap-usd').onChanged, isNotNull);
      expect(checkbox('ap-eur').onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('ar-ap-close')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final body = api.lastPutBody;
      expect(body, isNotNull);
      expect(body!['currencyId'], 'currency-usd');
      final item = Map<String, dynamic>.from(
        (body['items'] as List<dynamic>).single as Map,
      );
      expect(item['appliedLedgerId'], 'ap-usd');
      expect(item['amountOriginal'], '80.0000');
    },
  );

  testWidgets('AP payment rejects amount or rate beyond fixed precision', (
    tester,
  ) async {
    final api = await _pumpEditor(tester, detail: _appliedPaymentDetail());
    final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
      _financeGrid(),
    );
    grid.controller.rows.single.amount.text = '50.12345';

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(api.lastPutBody, isNull);
    var notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.single.message, contains('最多 4 位小数'));

    grid.controller.rows.single.amount.text = '50.1234';
    await tester.enterText(
      find.byKey(const ValueKey('finance-payment-exchange-rate')),
      '7.1234567',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(api.lastPutBody, isNull);
    notifications = ProviderScope.containerOf(
      tester.element(find.byType(FinanceDocEditPage)),
    ).read(appNotificationProvider);
    expect(notifications.last.message, contains('付款汇率'));
  });

  testWidgets('payment detail shows server-calculated settlement amounts', (
    tester,
  ) async {
    await _pumpDetail(tester, detail: _appliedPaymentDetail());

    expect(find.text('付款原币金额'), findsOneWidget);
    expect(find.text('付款本币合计'), findsOneWidget);

    final table = tester.widget<MasterDataTableView<FinanceDocItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinanceDocItem>,
      ),
    );
    final columns = {for (final column in table.columns) column.key: column};
    final item = table.items.single;
    expect(columns['amountOriginal']?.label, '本次付款(原币)');
    expect(columns['amountOriginal']?.value(item), '50.00');
    expect(columns['amountLocal']?.label, '付款本币');
    expect(columns['amountLocal']?.value(item), '360.00');
    expect(columns['appliedAmountLocal']?.label, '核销账面本币');
    expect(columns['appliedAmountLocal']?.value(item), '350.00');
    expect(columns['exchangeDiff']?.label, '汇兑差额');
    expect(columns['exchangeDiff']?.value(item), '10.00');
  });
}

Finder _dropdownWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == label,
);

Finder _financeGrid() => find.byWidgetPredicate(
  (widget) => widget is UtenEditableGrid<FinanceGridRow>,
);

Future<_PaymentApi> _pumpEditor(
  WidgetTester tester, {
  required Map<String, dynamic> detail,
  List<Map<String, dynamic>> ledgerItems = const [],
  Size size = const Size(1600, 1200),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _PaymentApi(detail, ledgerItems: ledgerItems);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        financeWriteAllDocumentScope(),
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
      ],
      child: MaterialApp(
        home: FinanceDocEditPage(
          docType: FinanceDocType.payment,
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

  final api = _PaymentApi(detail);
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
          docType: FinanceDocType.payment,
          id: detail['id'] as String,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _directPaymentDetail() => <String, dynamic>{
  'id': 'payment-1',
  'version': 3,
  'makerId': 'maker-1',
  'billNo': 'CF202608090001',
  'billDate': '2026-08-09',
  'supplierId': 'supplier-1',
  'accountId': 'account-1',
  'paymentMethodId': 'payment-method-1',
  'currencyId': 'currency-usd',
  'exchangeRate': 7.2,
  'amountOriginal': 100,
  'amountLocal': 720,
  'status': 0,
  'items': <Map<String, dynamic>>[],
};

Map<String, dynamic> _appliedPaymentDetail() => <String, dynamic>{
  'id': 'payment-1',
  'version': 3,
  'makerId': 'maker-1',
  'billNo': 'CF202608090002',
  'billDate': '2026-08-09',
  'supplierId': 'supplier-1',
  'accountId': 'account-1',
  'paymentMethodId': 'payment-method-1',
  'currencyId': 'currency-usd',
  'exchangeRate': 7.2,
  'amountOriginal': 50,
  'amountLocal': 360,
  'status': 0,
  'items': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'payment-line-1',
      'appliedLedgerId': 'ledger-1',
      'appliedBillNo': 'AP-001',
      'supplierId': 'supplier-1',
      'amountOriginal': 50,
      'amountLocal': 360,
      'appliedAmountLocal': 350,
      'exchangeDiff': 10,
      'remark': '核销备注',
    },
  ],
};

List<Map<String, dynamic>> _apPickerItems() => <Map<String, dynamic>>[
  <String, dynamic>{
    'id': 'ap-usd',
    'direction': 'AP',
    'billNo': 'AP-USD-001',
    'billDate': '2026-08-01',
    'supplierId': 'supplier-1',
    'currencyId': 'currency-usd',
    'currencyCode': 'USD',
    'amountOriginal': 100,
    'amountSettled': 20,
    'amountBalanceOriginal': 80,
    'salesOrderNos': <String>['PO-001'],
  },
  <String, dynamic>{
    'id': 'ap-eur',
    'direction': 'AP',
    'billNo': 'AP-EUR-001',
    'billDate': '2026-08-02',
    'supplierId': 'supplier-1',
    'currencyId': 'currency-eur',
    'currencyCode': 'EUR',
    'amountOriginal': 200,
    'amountSettled': 50,
    'amountBalanceOriginal': 150,
    'salesOrderNos': <String>['PO-002'],
  },
  <String, dynamic>{
    'id': 'ap-incomplete',
    'direction': 'AP',
    'billNo': 'AP-OLD-001',
    'billDate': '2020-01-01',
    'supplierId': 'supplier-1',
    'currencyId': 'currency-usd',
    'currencyCode': 'USD',
    'amountOriginal': 90,
    'amountSettled': 10,
    'amountBalance': 80,
  },
];

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _PaymentApi extends ApiClient {
  _PaymentApi(this.detail, {this.ledgerItems = const []}) : super(Dio());

  final Map<String, dynamic> detail;
  final List<Map<String, dynamic>> ledgerItems;
  Map<String, dynamic>? lastPutBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/ar-ap') {
      return <String, dynamic>{
        'items': ledgerItems,
        'page': 1,
        'size': 50,
        'total': ledgerItems.length,
        'totalPages': 1,
      };
    }
    return detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/suppliers/dict') {
      return const [
        {'id': 'supplier-1', 'name': '甲供应商'},
      ];
    }
    if (path == '/master/accounts/dict') {
      return const [
        {'id': 'account-1', 'name': '付款账户'},
      ];
    }
    if (path == '/master/currencies/dict') {
      return const [
        {'id': 'currency-usd', 'name': '美元'},
        {'id': 'currency-eur', 'name': '欧元'},
      ];
    }
    if (path == '/master/reference-methods/finance') {
      return const [
        {
          'id': 'payment-method-1',
          'code': 'BANK',
          'name': '银行转账',
          'legacyNameConfirmed': true,
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
