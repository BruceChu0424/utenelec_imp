import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/quality/pages/quality_batch_approval_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'confirmation cannot adopt a newer same-account authentication intent',
    (tester) async {
      final session = _IntentSession();
      final iqc = _Iqc();
      await _pump(tester, iqc, 2, session: session);
      await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
      await tester.pumpAndSettle();
      session.epoch++;
      await tester.tap(
        find.byKey(const Key('inspection-report-confirm-submit')),
      );
      await tester.pumpAndSettle();
      expect(iqc.sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing an in-flight batch stops after the single report command', (
    tester,
  ) async {
    final reply = Completer<void>();
    final iqc = _Iqc(decide: () => reply.future);
    await _pump(tester, iqc, 2);
    await _confirm(tester);
    await tester.pump();
    expect(iqc.sent, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    reply.complete();
    await tester.pumpAndSettle();
    expect(iqc.sent, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing server and returning does not revive the old batch', (
    tester,
  ) async {
    final reply = Completer<void>();
    final iqc = _Iqc(decide: () => reply.future);
    await _pump(tester, iqc, 2);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QualityBatchApprovalPage)),
    );
    await _confirm(tester);
    await tester.pump();
    expect(iqc.sent, hasLength(1));
    container.read(_serverForTest.notifier).state =
        'https://changed.example.test/api';
    await tester.pump();
    container.read(_serverForTest.notifier).state =
        'https://original.example.test/api';
    await tester.pump();
    reply.complete();
    await tester.pumpAndSettle();
    expect(iqc.sent, hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'compact grouped tables preserve edits and clear selection from floating controls',
    (tester) async {
      final iqc = _Iqc();
      await _pump(tester, iqc, 1, size: const Size(375, 812));
      // 2026-10-02 用户口径：批量审批合一张表（类型/单号成列），不再按单分组。
      expect(
        find.byKey(const Key('batch-approval-unified-table')),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      final action = find.byKey(const Key('batch-approval-submit-report'));
      expect(tester.widget<UtenButton>(action).type, UtenButtonType.danger);
      expect(
        find.ancestor(
          of: action,
          matching: find.byType(UtenFloatingActionGroup),
        ),
        findsOneWidget,
      );
      expect(tester.getRect(action).bottom, lessThanOrEqualTo(812));
      await tester.tap(find.byKey(const Key('batch-approval-clear-selection')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-1')),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(iqc.sent, isEmpty);
      expect(
        find.byKey(const Key('inspection-report-confirm-submit')),
        findsNothing,
      );
      // 组头复选已随合表退役：勾选走表格行多选通道（idOf 前缀 iqc:）。
      MasterDataTableView<dynamic> table() =>
          tester.widget(find.byKey(const Key('batch-approval-unified-table')));
      table().onSelectedIdsChanged!({'iqc:receipt-1'});
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-1')),
            )
            .enabled,
        isTrue,
      );
      table().onSelectedIdsChanged!(const <String>{});
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-1')),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-1')),
            )
            .controller!
            .text,
        '5',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('editing pass auto-fills fail until fail is hand-edited', (
    tester,
  ) async {
    final iqc = _Iqc();
    await _pump(tester, iqc, 1);
    UtenAutofillTextController controller(Key key) =>
        tester.widget<TextField>(find.byKey(key)).controller!
            as UtenAutofillTextController;
    const pass = Key('batch-approval-pass-receipt-1');
    const fail = Key('batch-approval-fail-receipt-1');
    expect(controller(pass).text, '5');
    expect(controller(fail).text, '0');
    // 2026-10-10 用户口径「改合格自动算不合格」：互补回写「剩余待检 − 合格」，
    // 程序值带黄框待核对标记（autofilled），用户击键的列没有标记。
    await tester.enterText(find.byKey(pass), '2');
    await tester.pump();
    expect(controller(fail).text, '3');
    expect(controller(fail).autofilled, isTrue);
    expect(controller(pass).autofilled, isFalse);
    // 互补不低于 0（合格超过剩余时按 0 兜底，越界由行校验另行报错）。
    await tester.enterText(find.byKey(pass), '9');
    await tester.pump();
    expect(controller(fail).text, '0');
    // 手填过不合格后，合格是用户值不再被抢（避免两列互相踢皮球）。
    await tester.enterText(find.byKey(fail), '1');
    await tester.pump();
    expect(controller(pass).text, '9');
    expect(controller(fail).text, '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pure IQC batch drops the plan and unit columns and inlines the unit',
    (tester) async {
      final iqc = _Iqc();
      await _pump(tester, iqc, 1);
      // 2026-10-10 T9「数量+单位」内联：独立单位列与实际成品仓列撤除，
      // 待检列直接显示「5 件」、输入列单位进后缀；生产计划只对 FQC 行有意义，
      // 本批全是 IQC 行时整列不渲染。
      expect(find.text('单位'), findsNothing);
      expect(find.text('实际成品仓'), findsNothing);
      expect(find.text('生产计划'), findsNothing);
      expect(find.text('5 件'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-1')),
            )
            .decoration!
            .suffixText,
        '件',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pre-stocked lines show their storage location per row in the batch table',
    (tester) async {
      final iqc = _Iqc(
        load: (_) async => [
          _row(
            'shelf-line',
            preStocked: const WarehousePreStockedLocation(
              warehouseId: 'wh-1',
              warehouseName: '五金仓',
              place: 'B-12',
            ),
          ),
          _row('plain-line'),
        ],
      );
      await _pump(tester, iqc, 1);
      // 2026-09-18 用户口径：先入库后检的行在批量页逐行可见储放位置，
      // 与检验处置页同文案（红字「已入库 · 仓 / 库位」），未上架行显示待检区。
      expect(find.text('储放位置'), findsOneWidget);
      expect(find.text('已入库 · 五金仓 / B-12'), findsOneWidget);
      expect(find.text('待检区'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
    'more than twenty receipts is rejected before freezing its report',
    (tester) async {
      // 与 decide-report 服务端契约同上限：整份报告一次请求最多 20 张收货单
      // (40s 服务端命令截止的实测余量：全预入库 20 单 ~30s，再大会整批回滚)，提前给出可操作的
      // 提示而不是等服务端 422。
      final iqc = _Iqc();
      await _pump(tester, iqc, 21);
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
      expect(notifications.single.message, contains('最多提交 20 张收货单'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'report timeout keeps the whole report retryable with the exact frozen body',
    (tester) async {
      // 2026-10-10 整份检验报告一次提交：响应丢失后没有任何单被确认（服务端原子），
      // 重试发同一个报告体；成功后一并办结返回。
      var attempts = 0;
      final iqc = _Iqc(
        decide: () async {
          if (attempts++ == 0) throw NetworkTimeoutException();
        },
      );
      await _pump(tester, iqc, 2);
      await _confirm(tester);
      await tester.pumpAndSettle();
      expect(iqc.sent.map((request) => request.$1), ['receipt-1+receipt-2']);
      // 整批未确认：没有行进入「已确认提交」，报告体被冻结等待重试。
      expect(find.text('本次报告已确认提交'), findsNothing);
      expect(find.text('重试原报告'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-approval-pass-receipt-2')),
            )
            .enabled,
        isFalse,
      );
      final frozen = iqc.sent.last.$2;
      await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('inspection-report-confirm-submit')),
        findsNothing,
      );
      expect(iqc.sent.map((request) => request.$1), [
        'receipt-1+receipt-2',
        'receipt-1+receipt-2',
      ]);
      expect(iqc.sent.last.$2, frozen,
          reason: '重试发同一个整份报告体，服务端静默重放');
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
      final iqc = _Iqc(decide: () => gate.future);
      await _pump(tester, iqc, 1);
      await _confirm(tester);
      await tester.pump(const Duration(milliseconds: 200));
      expect(iqc.sent.length, 1);
      // The busy overlay deliberately intercepts this location. Exercise the
      // user's tap there without claiming that the covered button receives it.
      await tester.tapAt(tester.getCenter(find.byType(UtenBackButton)));
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
  Size size = const Size(1400, 1000),
  _IntentSession? session,
}) async {
  await tester.binding.setSurfaceSize(size);
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
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_serverForTest)),
        sessionProvider.overrideWith(() => session ?? _IntentSession()),
        procurementInspectionRepositoryProvider.overrideWithValue(iqc),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-approval')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

final _serverForTest = StateProvider<String>(
  (ref) => 'https://original.example.test/api',
);

class _IntentSession extends SessionNotifier {
  int epoch = 0;
  @override
  int get requestIntentEpoch => epoch;
  @override
  SessionState build() => const SessionState();
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('batch-approval-submit-report')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
  await tester.pump();
}

ProcurementInspectionItem _row(
  String id, {
  WarehousePreStockedLocation? preStocked,
}) => ProcurementInspectionItem(
  id: id,
  goodsName: '物料$id',
  remainingBaseQty: 5,
  receivedBaseQty: 5,
  passedBaseQty: 0,
  failedBaseQty: 0,
  baseUnitName: '件',
  status: 'PENDING',
  preStocked: preStocked,
);

class _Iqc extends Fake implements ProcurementInspectionRepository {
  _Iqc({this.load, this.decide});
  final Future<List<ProcurementInspectionItem>> Function(String)? load;
  final Future<void> Function()? decide;
  final sent = <(String, Map<String, dynamic>)>[];

  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async => load == null ? [_row(receiptId)] : load!(receiptId);

  @override
  Future<void> decideReport({
    required List<ProcurementInspectionReportReceipt> receipts,
    String? reason,
  }) async {
    sent.add((
      receipts.map((receipt) => receipt.receiptId).join('+'),
      (jsonDecode(
                jsonEncode({
                  'receipts': [for (final receipt in receipts) receipt.toJson()],
                  'reason': reason,
                }),
              )
              as Map)
          .cast<String, dynamic>(),
    ));
    await decide?.call();
  }
}
