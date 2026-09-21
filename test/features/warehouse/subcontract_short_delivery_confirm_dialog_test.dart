// ADR-098 到货登记短交确认弹窗：服务端 409 逐行说明 → 弹窗 → 「继续登记并通知委外」带确认重发，
// 「返回修改」返回 null 让页面原地停下。
//
// 宿主按登记页原样搭：提交期间 AbsorbPointer + UtenBusyOverlay 全屏遮罩。遮罩挂在 root Overlay、
// 排在后推的弹窗路由之上，所以弹窗必须等遮罩撤了才点得动(2026-09-21 批量登记页实测点不动)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/widgets/subcontract_short_delivery_confirm_dialog.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

/// 登记页宿主：提交期间整页禁手 + 全屏「正在批量登记到货」遮罩。
class _RegisterHost extends StatefulWidget {
  const _RegisterHost({required this.onReady});

  final void Function(_RegisterHostState state) onReady;

  @override
  State<_RegisterHost> createState() => _RegisterHostState();
}

class _RegisterHostState extends State<_RegisterHost> {
  bool saving = false;

  void setSaving(bool value) {
    if (mounted) setState(() => saving = value);
  }

  @override
  void initState() {
    super.initState();
    widget.onReady(this);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        AbsorbPointer(absorbing: saving, child: const SizedBox.expand()),
        if (saving)
          const UtenBusyOverlay(
            title: '正在批量登记到货',
            description: '正在按实收数量整批登记送检，请勿重复提交或离开本页。',
          ),
      ],
    ),
  );
}

/// 遮罩里的转圈是无限动画：只要它在屏上 pumpAndSettle 永不收敛，只能定量推帧。
Future<void> pumpFrames(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  ApiException blocked() => ApiException(
    kSubcontractShortDeliveryUnacknowledgedCode,
    '有 1 行到货数量明显少于订货量。登记后系统会通知委外跟单员判定。',
    fieldErrors: const [
      ApiFieldError(
        field: 'item-1',
        message:
            '「委外件A FG-1」订 100 件，允许损耗 5%(最少应到 95 件)，此前已到 0 件，本次 60 件，累计 60 件，少 40 件(40%)，属严重短交',
      ),
    ],
    httpStatus: 409,
  );

  /// 挂宿主并模拟「点提交」：置 saving=true 后发起登记，返回 (宿主状态, 登记 Future)。
  Future<(_RegisterHostState, Future<WarehouseArrivalRegistration?>)> submit(
    WidgetTester tester, {
    required List<Map<String, dynamic>> calls,
    bool failFirst = true,
  }) async {
    late _RegisterHostState host;
    await tester.pumpWidget(
      MaterialApp(home: _RegisterHost(onReady: (state) => host = state)),
    );
    await tester.pumpAndSettle();
    host.setSaving(true);
    await pumpFrames(tester);
    expect(find.byType(UtenBusyOverlay), findsOneWidget);
    final context = tester.element(find.byType(Scaffold));
    final pending = registerArrivalConfirmingShortDelivery(
      context: context,
      body: const {'idempotencyKey': 'k', 'items': <Map<String, dynamic>>[]},
      setBusy: host.setSaving,
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
    return (host, pending);
  }

  testWidgets('登记中的全屏遮罩先撤下，弹窗按钮真的点得动并带确认重发', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final (host, pending) = await submit(tester, calls: calls);
    await pumpFrames(tester);

    expect(find.text('到货数量明显少于订货量'), findsOneWidget);
    expect(find.textContaining('最少应到 95 件'), findsOneWidget);
    expect(find.textContaining('属严重短交'), findsOneWidget);
    // 弹窗期间遮罩必须已撤：否则它盖在弹窗路由之上，按钮吃不到点击。
    expect(find.byType(UtenBusyOverlay), findsNothing);
    expect(host.saving, isFalse);
    expect(find.text('正在批量登记到货'), findsNothing);

    // 按坐标点，命中的是当时最上层的 widget——遮罩没撤就会被它吃掉。
    await tester.tapAt(tester.getCenter(find.text('继续登记并通知委外')));
    await pumpFrames(tester);

    expect(calls.length, 2, reason: '点中了确认才会带确认重发；点不中说明弹窗又被遮罩盖住了');
    final registration = await pending;
    expect(registration?.receiptBillNo, 'SR-1');
    expect(calls.first['shortDeliveryAcknowledged'], isNull);
    expect(calls.last['shortDeliveryAcknowledged'], isTrue);
    expect(calls.last['idempotencyKey'], 'k');
    // 确认后遮罩回来继续盖住重发过程。
    expect(host.saving, isTrue);
  });

  testWidgets('「返回修改」返回 null 且不重发，遮罩不再挡页面', (tester) async {
    final calls = <Map<String, dynamic>>[];
    final (host, pending) = await submit(tester, calls: calls);
    await pumpFrames(tester);
    await tester.tapAt(tester.getCenter(find.text('返回修改')));
    await pumpFrames(tester);
    expect(
      find.text('到货数量明显少于订货量'),
      findsNothing,
      reason: '点中了返回修改弹窗才会关；点不中说明弹窗又被遮罩盖住了',
    );
    expect(await pending, isNull);
    expect(calls.length, 1);
    expect(host.saving, isFalse);
    expect(find.byType(UtenBusyOverlay), findsNothing);
  });

  testWidgets('其它错误原样抛出，不弹短交确认也不动遮罩', (tester) async {
    late _RegisterHostState host;
    await tester.pumpWidget(
      MaterialApp(home: _RegisterHost(onReady: (state) => host = state)),
    );
    await tester.pumpAndSettle();
    host.setSaving(true);
    await pumpFrames(tester);
    final context = tester.element(find.byType(Scaffold));
    await expectLater(
      registerArrivalConfirmingShortDelivery(
        context: context,
        body: const {},
        setBusy: host.setSaving,
        register: (_) async => throw ApiException('CONFLICT', '收货来源已变化'),
      ),
      throwsA(isA<ApiException>()),
    );
    expect(host.saving, isTrue);
    host.setSaving(false);
    await tester.pumpAndSettle();
    expect(find.text('到货数量明显少于订货量'), findsNothing);
    expect(find.byType(UtenBusyOverlay), findsNothing);
  });
}
