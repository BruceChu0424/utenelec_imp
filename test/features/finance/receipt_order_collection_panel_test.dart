import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/widgets/receipt_order_collection_panel.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/widgets/sales_order_money_position_view.dart';
import '../../support/audit_screenshot_support.dart';

void main() {
  testWidgets(
    'retired panel never restarts an old order summary under a new finance owner',
    (tester) async {
      final api = _PreviewApi();
      final epoch = _Epoch();
      await _open(tester, api, epoch, (_) {}, fullMoney: true);
      expect(api.summaryReads, 1);
      epoch.advance();
      await tester.pumpAndSettle();
      expect(api.summaryReads, 1);
      expect(
        find.byKey(const ValueKey('sales-order-money-summary')),
        findsNothing,
      );
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('order-collection-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('order-collection-amount')),
            )
            .controller
            ?.text,
        '10',
      );
    },
  );
  testWidgets(
    'cancel old preview then repeat keeps the second overlay until its own result',
    (tester) async {
      final api = _PreviewApi();
      final epoch = _Epoch();
      ReceiptOrderCollection? result;
      await _open(tester, api, epoch, (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('order-collection-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(api.pending, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      await tester.tap(find.text('取消核对'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('order-collection-amount')),
        '20',
      );
      await tester.tap(find.byKey(const ValueKey('order-collection-confirm')));
      await tester.pump();
      expect(api.pending, hasLength(2));
      api.pending[0].complete(_preview('10'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(result, isNull);
      api.pending[1].complete(_preview('20'));
      await tester.pumpAndSettle();
      expect(result?.amount, '20');
      expect(result?.items.single.requestedSalesOrderId, 'order-b');
      expect(
        api.bodies.map((body) => body['salesOrderId']),
        everyElement('order-b'),
      );
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'owner retirement blocks old order confirmation and old result while preserving input',
    (tester) async {
      final api = _PreviewApi();
      final epoch = _Epoch();
      ReceiptOrderCollection? result;
      await _open(tester, api, epoch, (value) => result = value);
      await tester.tap(find.byKey(const ValueKey('order-collection-confirm')));
      await tester.pump();
      expect(api.pending, hasLength(1));
      epoch.advance();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('order-collection-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('order-collection-amount')),
            )
            .controller
            ?.text,
        '10',
      );
      epoch.advance();
      api.pending.single.complete(_preview('10'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(api.pending, hasLength(1));
      expect(
        (tester
                    .widget<TextField>(
                      find.byKey(const ValueKey('order-collection-amount')),
                    )
                    .decoration
                as UtenInputDecoration)
            .base
            .errorText,
        contains('登录身份、权限或连接已变化'),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '375px order funding keeps draft, bank and return meanings separate without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(375, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final captureEnabled =
          Platform.environment['UTEN_CAPTURE_FINANCE_ORDER_FEEDBACK'] == 'true';
      if (captureEnabled) {
        await loadAuditScreenshotFonts(tester);
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: auditScreenshotTheme(buildLightTheme()),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: SalesOrderMoneyPositionView(
                  frozen: true,
                  value: SalesOrderMoneyPosition(
                    orderBillNo: 'XD000000000002',
                    currencyName: '人民币',
                    cashReceivedOriginal: '1000',
                    plannedRemainingOriginal: '500',
                    pendingReceiptOriginal: '20',
                    prepaymentAvailableOriginal: '100',
                    prepaymentAppliedOriginal: '200',
                    returnCreditOriginal: '100',
                    customerPendingBalanceOriginal: '50',
                    positionComplete: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('本单已确认收款'), findsOneWidget);
      expect(find.text('待确认收款'), findsOneWidget);
      expect(find.text('退货金额'), findsOneWidget);
      expect(find.text('客户待处理余额'), findsOneWidget);
      expect(find.text('审核时订单资金 · XD000000000002'), findsOneWidget);
      if (captureEnabled) {
        await saveAuditScreenshot(
          tester,
          capture,
          'receipt-order-money-frozen-375',
        );
      }
    },
  );
}

Future<void> _open(
  WidgetTester tester,
  _PreviewApi api,
  _Epoch epoch,
  ValueChanged<ReceiptOrderCollection?> result, {
  bool fullMoney = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(
          fullMoney
              ? const {Perm.financeViewAll, Perm.customerPrepaymentView}
              : const <String>{},
        ),
        exportContextEpochProvider.overrideWith(() => epoch),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result(
                  await showReceiptOrderCollectionPanel(
                    context,
                    initialOrder: const SalesDocListItem(
                      id: 'order-b',
                      billNo: 'XD-B',
                      clientId: 'client',
                      currencyId: 'currency',
                      status: 1,
                    ),
                    initialAmount: '10',
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _preview(String amount) => {
  'salesOrderId': 'order-b',
  'orderBillNo': 'XD-B',
  'clientId': 'client',
  'currencyId': 'currency',
  'receiptKind': 'AR_SETTLEMENT',
  'amountOriginal': amount,
  'items': [
    {
      'ledgerId': 'ledger-shared',
      'billNo': 'AR-SHARED',
      'amountOriginal': amount,
      'balanceOriginal': '100',
    },
  ],
};

class _PreviewApi extends ApiClient {
  _PreviewApi() : super(Dio());
  final pending = <Completer<Map<String, dynamic>>>[];
  final bodies = <Map<String, dynamic>>[];
  int summaryReads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, endsWith('/summary'));
    summaryReads++;
    return {
      'salesOrderId': 'order-b',
      'orderBillNo': 'XD-B',
      'cashReceivedOriginal': '0',
      'plannedRemainingOriginal': '100',
      'orderTotalOriginal': '100',
      'currencyName': '人民币',
      'positionComplete': true,
    };
  }

  @override
  Future<Map<String, dynamic>> postCancellable(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) {
    expect(path, '/finance/receipts/order-collection-preview');
    bodies.add(Map<String, dynamic>.from(body as Map? ?? const {}));
    final result = Completer<Map<String, dynamic>>();
    pending.add(result);
    return result.future;
  }
}

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}
