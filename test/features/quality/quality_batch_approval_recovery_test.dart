import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/quality/pages/quality_batch_approval_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    'canceling report confirmation leaves an editable draft and sends nothing',
    (tester) async {
      final iqc = _Iqc();
      await _pump(tester, iqc, 1);
      await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('inspection-report-confirm-cancel')),
      );
      await tester.pumpAndSettle();
      expect(iqc.sent, isEmpty);
      expect(
        find.byKey(const Key('inspection-report-confirm-submit')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-1')),
            )
            .enabled,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an oversized single receipt is rejected before freezing its report',
    (tester) async {
      final iqc = _Iqc(
        load: (_) async => [for (var i = 0; i < 101; i++) _row('line-$i')],
      );
      await _pump(tester, iqc, 1);
      await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(iqc.sent, isEmpty);
      expect(
        find.byKey(const Key('inspection-report-confirm-submit')),
        findsNothing,
      );
      final notifications = ProviderScope.containerOf(
        tester.element(find.byType(QualityBatchApprovalPage)),
        listen: false,
      ).read(appNotificationProvider);
      expect(notifications.single.message, contains('每单报告最多100行'));
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-line-0')),
            )
            .enabled,
        isTrue,
      );
    },
  );

  testWidgets(
    'partial success stays visible and exact retry skips acknowledged receipt',
    (tester) async {
      var secondAttempts = 0;
      final iqc = _Iqc(
        decide: (id) async {
          if (id == 'receipt-2' && secondAttempts++ == 0) {
            throw NetworkTimeoutException();
          }
        },
      );
      await _pump(tester, iqc, 2);
      await tester.tap(find.byKey(const Key('batch-approval-pass-receipt-2')));
      await _confirm(tester);
      await tester.pumpAndSettle();
      expect(iqc.sent.map((request) => request.$1), ['receipt-1', 'receipt-2']);
      expect(find.text('本次报告已确认提交'), findsOneWidget);
      expect(find.text('重试原报告'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-2')),
            )
            .enabled,
        isFalse,
      );
      final editable = find.descendant(
        of: find.byKey(const Key('batch-approval-pass-receipt-2')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isFalse);
      final unknown = iqc.sent.last.$2;
      await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('inspection-report-confirm-submit')),
        findsNothing,
      );
      expect(iqc.sent.map((request) => request.$1), [
        'receipt-1',
        'receipt-2',
        'receipt-2',
      ]);
      expect(iqc.sent.last.$2, unknown);
      expect(
        find.byKey(const Key('open-approval')),
        findsOneWidget,
        reason: 'Successful retry returns to its caller',
      );
    },
  );

  testWidgets(
    'in-flight report blocks toolbar and system back but permits return after failure',
    (tester) async {
      final gate = Completer<void>();
      final iqc = _Iqc(decide: (_) => gate.future);
      await _pump(tester, iqc, 1);
      await _confirm(tester);
      await tester.pump(const Duration(milliseconds: 200));
      expect(iqc.sent.length, 1);
      await tester.tap(find.byType(UtenBackButton));
      await tester.pump();
      expect(
        find.byKey(const Key('batch-approval-submit-report')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(
        find.byKey(const Key('batch-approval-submit-report')),
        findsOneWidget,
      );
      gate.completeError(NetworkTimeoutException());
      await tester.pumpAndSettle();
      expect(find.text('重试原报告'), findsOneWidget);
      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-approval')), findsOneWidget);
      expect(iqc.sent.length, 1);
    },
  );

  testWidgets(
    'receipt reads have four workers and late responses do not revive a disposed page',
    (tester) async {
      final gates = <String, Completer<List<ProcurementInspectionItem>>>{};
      var active = 0;
      var peak = 0;
      final iqc = _Iqc(
        load: (id) async {
          active++;
          if (active > peak) peak = active;
          final gate = gates.putIfAbsent(
            id,
            Completer<List<ProcurementInspectionItem>>.new,
          );
          try {
            return await gate.future;
          } finally {
            active--;
          }
        },
      );
      await _pump(tester, iqc, 9, settle: false);
      await tester.pump(const Duration(milliseconds: 200));
      expect(gates.length, 4);
      expect(peak, 4);
      gates['receipt-1']!.complete([_row('receipt-1')]);
      await tester.pump();
      expect(gates.length, 5);
      expect(active, 4);
      await tester.tap(find.byType(UtenBackButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('open-approval')), findsOneWidget);
      for (final entry in gates.entries) {
        if (!entry.value.isCompleted) entry.value.complete([_row(entry.key)]);
      }
      await tester.pumpAndSettle();
      expect(
        gates.length,
        5,
        reason: 'Disposed pages do not start queued network reads',
      );
      expect(active, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retry failed loading keeps other receipt edits and selection', (
    tester,
  ) async {
    final loads = <String, int>{};
    final iqc = _Iqc(
      load: (id) async {
        loads[id] = (loads[id] ?? 0) + 1;
        if (id == 'receipt-2' && loads[id] == 1) throw NetworkException();
        return [_row(id)];
      },
    );
    await _pump(tester, iqc, 2);
    await tester.enterText(
      find.byKey(const Key('batch-approval-pass-receipt-1')),
      '4.25',
    );
    await tester.tap(find.byKey(const Key('batch-approval-reload-failed')));
    await tester.pumpAndSettle();
    expect(loads, {'receipt-1': 1, 'receipt-2': 2});
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('batch-approval-pass-receipt-1')),
          )
          .controller!
          .text,
      '4.25',
    );
    expect(
      find.byKey(const Key('batch-approval-pass-receipt-2')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('batch-approval-reload-failed')), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Iqc iqc,
  int count, {
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: TextButton(
            key: const Key('open-approval'),
            onPressed: () => context.push('/approve'),
            child: const Text('打开审批'),
          ),
        ),
      ),
      GoRoute(
        path: '/approve',
        builder: (context, state) => QualityBatchApprovalPage(
          selection: QualityBatchApprovalSelection(
            receipts: [
              for (var i = 1; i <= count; i++)
                PendingInspectionReceipt(
                  receiptType: 'PURCHASE',
                  receiptId: 'receipt-$i',
                  billNo: 'R$i',
                ),
            ],
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        procurementInspectionRepositoryProvider.overrideWithValue(iqc),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.tap(find.byKey(const Key('open-approval')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
  await tester.pump();
}

ProcurementInspectionItem _row(String id) => ProcurementInspectionItem(
  id: id,
  goodsName: '物料$id',
  remainingBaseQty: 5,
  receivedBaseQty: 5,
  passedBaseQty: 0,
  failedBaseQty: 0,
  baseUnitName: '件',
  status: 'PENDING',
);

class _Iqc extends Fake implements ProcurementInspectionRepository {
  _Iqc({this.load, this.decide});
  final Future<List<ProcurementInspectionItem>> Function(String)? load;
  final Future<void> Function(String)? decide;
  final sent = <(String, Map<String, dynamic>)>[];

  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async => load == null ? [_row(receiptId)] : load!(receiptId);

  @override
  Future<int> pendingCount() async => 0;

  @override
  Future<void> decideBatch({
    required String receiptType,
    required String receiptId,
    required List<ProcurementInspectionDecideItem> items,
    String? reason,
  }) async {
    sent.add((
      receiptId,
      (jsonDecode(
                jsonEncode({
                  'items': [for (final item in items) item.toJson()],
                  'reason': reason,
                }),
              )
              as Map)
          .cast<String, dynamic>(),
    ));
    await decide?.call(receiptId);
  }
}
