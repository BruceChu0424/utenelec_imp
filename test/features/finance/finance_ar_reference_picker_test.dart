import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/components/layout/uten_load_more_boundary.dart';
import 'package:uten_imp/features/finance/models/finance_decimal.dart';
import 'package:uten_imp/features/finance/widgets/ar_ap_picker_dialog.dart';

void main() {
  for (final scenario in [
    (
      name: 'positive legacy direct receipt is an ordinary settlement target',
      kind: 'LEGACY_UNVERIFIED',
      balance: 12,
      currency: 'currency-usd',
      allowed: true,
    ),
    (
      name: 'negative legacy balance is not a credit',
      kind: 'LEGACY_UNVERIFIED',
      balance: -12,
      currency: 'currency-usd',
      allowed: false,
    ),
    (
      name: 'zero legacy balance cannot be referenced',
      kind: 'LEGACY_UNVERIFIED',
      balance: 0,
      currency: 'currency-usd',
      allowed: false,
    ),
    (
      name: 'unknown original legacy balance stays unavailable',
      kind: 'LEGACY_UNVERIFIED',
      balance: null,
      currency: 'currency-usd',
      allowed: false,
    ),
    (
      name: 'unknown legacy currency stays unavailable',
      kind: 'LEGACY_UNVERIFIED',
      balance: 12,
      currency: null,
      allowed: false,
    ),
    (
      name: 'native prepayment still requires apply prepayment',
      kind: 'CUSTOMER_PREPAYMENT',
      balance: 12,
      currency: 'currency-usd',
      allowed: false,
    ),
  ]) {
    testWidgets(scenario.name, (tester) async {
      final api = _ArReferenceApi(
        overrides: {
          'openItemKind': scenario.kind,
          'sourceDocType': 'DIRECT_RECEIPT',
          'amountBalanceOriginal': scenario.balance,
          'currencyId': scenario.currency,
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(api)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: FilledButton(
                  onPressed: () => showArApPickerDialog(
                    context,
                    ref,
                    direction: 'AR',
                    partyId: 'client-1',
                  ),
                  child: const Text('打开引用'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开引用'));
      await tester.pumpAndSettle();
      final checkbox = tester.widget<Checkbox>(
        find.byKey(const ValueKey('ar-ap-select-ledger-1')),
      );
      expect(checkbox.onChanged != null, scenario.allowed);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 ${scenario.allowed ? 1 : 0} 行'), findsOneWidget);
      expect(
        tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('ar-ap-confirm')),
                )
                .onPressed !=
            null,
        scenario.allowed,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'AR reference drawer loads the next page by wheel and keeps the original exact amount',
    (tester) async {
      final api = _PagedArReferenceApi();
      List<AppliedArAp>? applied;
      await _openPagedPicker(tester, api, (result) => applied = result);
      await _selectAndFillFirst(tester, '12.3456');

      await _wheelAtLedgerBottom(tester, api);
      expect(api.pages, [1, 2]);
      expect(
        find.byKey(const ValueKey('ar-ap-select-ledger-51')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('ar-ap-select-ledger-1')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('ar-ap-amount-ledger-1')),
            )
            .controller!
            .text,
        '12.3456',
      );
      expect(find.text('已选 1 行'), findsOneWidget);

      _ledgerVerticalPosition(tester).jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
      await tester.pumpAndSettle();
      expect(applied, hasLength(1));
      expect(applied!.single.ledgerId, 'ledger-1');
      expect(applied!.single.receiptAmountText, '12.3456');
      expect(applied!.single.currencyId, 'currency-usd');
      expect(api.pages, [1, 2]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AR next-page failure retains the editable first page and retries only that page',
    (tester) async {
      final api = _PagedArReferenceApi(failPageTwoOnce: true);
      List<AppliedArAp>? applied;
      await _openPagedPicker(tester, api, (result) => applied = result);
      await _selectAndFillFirst(tester, '7.0001');

      await _wheelAtLedgerBottom(tester, api);
      expect(api.pages, [1, 2]);
      expect(
        find.byKey(const ValueKey('ar-ap-select-ledger-51')),
        findsNothing,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('ar-ap-select-ledger-1')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('ar-ap-amount-ledger-1')),
            )
            .controller!
            .text,
        '7.0001',
      );
      expect(find.text('重试'), findsOneWidget);

      // A further wheel while an error is displayed must not retry in a loop.
      await _wheelAtLedgerBottom(tester, api);
      expect(api.pages, [1, 2]);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(api.pages, [1, 2, 2]);
      expect(
        find.byKey(const ValueKey('ar-ap-select-ledger-51')),
        findsOneWidget,
      );
      _ledgerVerticalPosition(tester).jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ar-ap-confirm')));
      await tester.pumpAndSettle();
      expect(applied, hasLength(1));
      expect(applied!.single.ledgerId, 'ledger-1');
      expect(applied!.single.receiptAmountText, '7.0001');
      expect(tester.takeException(), isNull);
    },
  );

  test('exact finance decimal keeps four-place money without double math', () {
    expect(financeExactDecimal('100.1200'), '100.1200');
    expect(financeExactDecimalUnits('100.1200'), BigInt.from(1001200));
    expect(financeExactDecimalFromUnits(BigInt.from(1001200)), '100.1200');
    expect(financeExactMoneyDisplay('100.1200'), '100.12');
    expect(financeExactMoneyDisplay('100.1234'), '100.1234');
    expect(financeExactDecimalUnits('1.00001'), isNull);
  });

  testWidgets('375px AR picker exposes source and complete settlement facts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _ArReferenceApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Consumer(
                builder: (context, ref, _) => FilledButton(
                  onPressed: () => showArApPickerDialog(
                    context,
                    ref,
                    direction: 'AR',
                    partyId: 'client-1',
                  ),
                  child: const Text('打开引用'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开引用'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('引用应收'), findsWidgets);
    expect(find.text('来源类型 / 单号'), findsOneWidget);
    expect(find.text('销售发运 · XSCK-001'), findsOneWidget);
    expect(find.text('应收总额'), findsOneWidget);
    expect(find.text('累计已收'), findsOneWidget);
    expect(find.text('累计冲销'), findsOneWidget);
    expect(find.text('预收已抵'), findsOneWidget);
    expect(find.text('本次可收'), findsOneWidget);
    expect(find.text('销售订单号'), findsOneWidget);
    expect(find.text('XD-001'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, '搜索应收单号、发运单号、销售订单号或客户'),
      findsOneWidget,
    );
  });
}

Future<void> _openPagedPicker(
  WidgetTester tester,
  _PagedArReferenceApi api,
  ValueChanged<List<AppliedArAp>?> onApplied,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: FilledButton(
              onPressed: () async => onApplied(
                await showArApPickerDialog(
                  context,
                  ref,
                  direction: 'AR',
                  partyId: 'client-1',
                ),
              ),
              child: const Text('打开引用'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开引用'));
  await tester.pumpAndSettle();
  expect(api.pages, [1]);
}

Future<void> _selectAndFillFirst(
  WidgetTester tester,
  String exactAmount,
) async {
  await tester.tap(find.byKey(const ValueKey('ar-ap-select-ledger-1')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('ar-ap-amount-ledger-1')),
    exactAmount,
  );
  await tester.pumpAndSettle();
}

ScrollPosition _ledgerVerticalPosition(WidgetTester tester) {
  // Cell editors own additional scrollables; select the outer list viewport.
  final viewport = find
      .descendant(
        of: find.byType(UtenLoadMoreBoundary),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.vertical,
        ),
      )
      .first;
  return tester
      .state<ScrollableState>(
        find.descendant(of: viewport, matching: find.byType(Scrollable)).first,
      )
      .position;
}

Future<void> _wheelAtLedgerBottom(
  WidgetTester tester,
  _PagedArReferenceApi api,
) async {
  final beforeWheel = List<int>.of(api.pages);
  final position = _ledgerVerticalPosition(tester);
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
  expect(
    api.pages,
    beforeWheel,
    reason: 'Only continued user scrolling loads the next page',
  );
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(find.byType(UtenLoadMoreBoundary)),
      scrollDelta: const Offset(0, 96),
    ),
  );
  await tester.pumpAndSettle();
}

class _PagedArReferenceApi extends _ArReferenceApi {
  _PagedArReferenceApi({this.failPageTwoOnce = false})
    : super(
        overrides: const {
          'amountBalanceOriginal': 65.4321,
          'amountBalanceOriginalExact': '65.4321',
        },
      );
  final bool failPageTwoOnce;
  bool _failed = false;
  final pages = <int>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/finance/ar-ap') return super.get(path, query: query);
    final page = (query?['page'] as num?)?.toInt() ?? 1;
    pages.add(page);
    if (page == 2 && failPageTwoOnce && !_failed) {
      _failed = true;
      throw NetworkException();
    }
    final template = await super.get(path, query: query);
    final first = Map<String, dynamic>.from(
      (template['items'] as List).single as Map,
    );
    return {
      'items': [
        for (
          var index = page == 1 ? 1 : 51;
          index <= (page == 1 ? 50 : 52);
          index++
        )
          {
            ...first,
            'id': 'ledger-$index',
            'billNo': 'AR-$index',
            'sourceDocId': 'shipment-$index',
            'sourceDocNo': 'XSCK-$index',
          },
      ],
      'page': page,
      'size': 50,
      'total': 52,
      'totalPages': 2,
    };
  }
}

class _ArReferenceApi extends ApiClient {
  _ArReferenceApi({this.overrides = const {}}) : super(Dio());

  final Map<String, dynamic> overrides;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/ar-ap') {
      return {
        'items': [
          {
            'id': 'ledger-1',
            'direction': 'AR',
            'openItemKind': 'RECEIVABLE',
            'sourceDocType': 'SALES_SHIPMENT',
            'sourceDocId': 'shipment-1',
            'sourceDocNo': 'XSCK-001',
            'billNo': 'AR-001',
            'billDate': '2026-08-22',
            'clientId': 'client-1',
            'currencyId': 'currency-usd',
            'currencyCode': 'USD',
            'amountOriginal': 100,
            'amountReceivedOriginal': 20,
            'amountWriteOffOriginal': 5,
            'prepaymentAppliedOriginal': '10.0000',
            'amountBalanceOriginal': 65,
            'salesOrderIds': ['order-1'],
            'salesOrderNos': ['XD-001'],
            'settled': false,
            ...overrides,
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{};
  }
}
