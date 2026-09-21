// ADR-098 到货登记短交确认弹窗：服务端 409 逐行说明 → 弹窗 → 「继续登记并通知委外」带确认重发，
// 「返回修改」返回 null 让页面原地停下。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_short_delivery_confirm_dialog.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

void main() {
  ApiException blocked() => ApiException(
    kSubcontractShortDeliveryUnacknowledgedCode,
    '有 1 行到货数量明显少于订货量。登记后系统会通知委外跟单员判定。',
    fieldErrors: const [
      ApiFieldError(
        field: 'item-1',
        message: '「委外件A FG-1」订 100 件，允许损耗 5%(最少应到 95 件)，此前已到 0 件，本次 60 件，累计 60 件，少 40 件(40%)，属严重短交',
      ),
    ],
    httpStatus: 409,
  );

  Future<WarehouseArrivalRegistration?> Function() pumpHost(
    WidgetTester tester, {
    required List<Map<String, dynamic>> calls,
    bool failFirst = true,
  }) {
    late Future<WarehouseArrivalRegistration?> Function() run;
    return () {
      run = () async {
        final context = tester.element(find.byType(Scaffold));
        return registerArrivalConfirmingShortDelivery(
          context: context,
          body: const {'idempotencyKey': 'k', 'items': <Map<String, dynamic>>[]},
          register: (payload) async {
            calls.add(payload);
            if (failFirst && payload['shortDeliveryAcknowledged'] != true) {
              throw blocked();
            }
            return const WarehouseArrivalRegistration(
              outcome: WarehouseArrivalRegistrationOutcome.submittedForInspection,
              receiptId: 'r-1',
              receiptBillNo: 'SR-1',
            );
          },
        );
      };
      return run();
    };
  }

  testWidgets('409 短交说明弹出，确认后带 shortDeliveryAcknowledged 原样重发', (
    tester,
  ) async {
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final run = pumpHost(tester, calls: calls);
    final pending = run();
    await tester.pumpAndSettle();
    expect(find.text('到货数量明显少于订货量'), findsOneWidget);
    expect(find.textContaining('最少应到 95 件'), findsOneWidget);
    expect(find.textContaining('属严重短交'), findsOneWidget);
    expect(find.text('继续登记并通知委外'), findsOneWidget);
    await tester.tap(find.text('继续登记并通知委外'));
    await tester.pumpAndSettle();
    final registration = await pending;
    expect(registration?.receiptBillNo, 'SR-1');
    expect(calls.length, 2);
    expect(calls.first['shortDeliveryAcknowledged'], isNull);
    expect(calls.last['shortDeliveryAcknowledged'], isTrue);
    expect(calls.last['idempotencyKey'], 'k');
  });

  testWidgets('「返回修改」返回 null 且不重发', (tester) async {
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final run = pumpHost(tester, calls: calls);
    final pending = run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    expect(await pending, isNull);
    expect(calls.length, 1);
  });

  testWidgets('其它错误原样抛出，不弹短交确认', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final context = tester.element(find.byType(Scaffold));
    await expectLater(
      registerArrivalConfirmingShortDelivery(
        context: context,
        body: const {},
        register: (_) async => throw ApiException('CONFLICT', '收货来源已变化'),
      ),
      throwsA(isA<ApiException>()),
    );
    await tester.pumpAndSettle();
    expect(find.text('到货数量明显少于订货量'), findsNothing);
  });
}
