import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/features/dashboard/widgets/module_badge_sum.dart';
import 'package:uten_imp/features/quality/pages/quality_task_center_page.dart';
import 'package:uten_imp/features/quality/pages/quality_pending_disposal_page.dart';
import 'package:uten_imp/features/warehouse/providers/procurement_inbound_count_providers.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/production_fqc_pending_count_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('workbench quality badge shows a positive pending count', (
    tester,
  ) async {
    await _pumpWorkbenchBadge(tester, count: 4);

    expect(
      find.descendant(
        of: find.byType(WorkbenchCardBadge),
        matching: find.text('4'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('workbench quality badge is hidden when pending count is zero', (
    tester,
  ) async {
    await _pumpWorkbenchBadge(tester, count: 0);

    expect(
      find.descendant(
        of: find.byType(WorkbenchCardBadge),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
    expect(find.text('0'), findsNothing);
  });

  for (final iqcResolvesFirst in [true, false]) {
    testWidgets(
      'quality total waits for ${iqcResolvesFirst ? 'FQC' : 'IQC'} before showing a number',
      (tester) async {
        final pending = Completer<int>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              procurementInspectionPendingCountProvider.overrideWith(
                (ref) async => iqcResolvesFirst ? 4 : pending.future,
              ),
              productionFqcPendingCountProvider.overrideWith(
                (ref) async => iqcResolvesFirst ? pending.future : 2,
              ),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: WorkbenchCardBadge(
                  kind: WorkbenchBadgeKind.qualityInspection,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('4'), findsNothing);
        expect(find.text('2'), findsNothing);
        pending.complete(iqcResolvesFirst ? 2 : 4);
        await tester.pumpAndSettle();
        expect(find.text('6'), findsOneWidget);
      },
    );
  }

  testWidgets('quality count failure is not presented as a real zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          procurementInspectionPendingCountProvider.overrideWith(
            (ref) => Future<int>.error(StateError('offline')),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: WorkbenchCardBadge(
              kind: WorkbenchBadgeKind.qualityInspection,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('procurement-inspection-badge-error')),
      findsOneWidget,
    );
    expect(find.text('0'), findsNothing);
  });

  test(
    'quality pending provider does not request without view permission',
    () async {
      final repository = _FakeInspectionRepository(pendingCountValue: 5);
      final container = ProviderContainer(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          isSuperAdminProvider.overrideWithValue(false),
          procurementInspectionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container.read(procurementInspectionPendingCountProvider.future),
        0,
      );
      expect(repository.pendingCountCalls, 0);
    },
  );

  testWidgets('quality task entry carries its return path to inspection', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: RouteName.qualityTaskCenter,
      routes: [
        GoRoute(
          path: RouteName.qualityTaskCenter,
          builder: (_, _) => const QualityTaskCenterPage(),
        ),
        GoRoute(
          path: RouteName.warehouseInspections,
          builder: (_, _) => const Scaffold(body: Text('待检处置任务中心已打开')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.procurementInspectionView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          procurementInspectionPendingCountProvider.overrideWith(
            (ref) async => 0,
          ),
        ],
        child: _routerApp(router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('待检处置'));
    await tester.pumpAndSettle();

    final uri = router.routeInformationProvider.value.uri;
    expect(uri.path, RouteName.warehouseInspections);
    expect(uri.queryParameters['returnTo'], RouteName.qualityTaskCenter);
  });

  testWidgets('deep-linked inspection returns to quality task center', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = _FakeInspectionRepository();
    final router = GoRouter(
      initialLocation: RouteName.warehouseInspections,
      routes: [
        GoRoute(
          path: RouteName.warehouseInspections,
          builder: (_, _) => const QualityPendingDisposalPage(),
        ),
        GoRoute(
          path: RouteName.qualityTaskCenter,
          builder: (_, _) => const Scaffold(body: Text('已返回品质任务中心')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          procurementInspectionRepositoryProvider.overrideWithValue(repository),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: _routerApp(router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.path,
      RouteName.qualityTaskCenter,
    );
    expect(find.text('已返回品质任务中心'), findsOneWidget);
  });

  testWidgets('returning to quality task center refreshes its pending badge', (
    tester,
  ) async {
    final repository = _FakeInspectionRepository(pendingCountValue: 1);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.procurementInspectionView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          procurementInspectionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: QualityTaskCenterPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.pendingCountCalls, 1);
    expect(find.text('1'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(QualityTaskCenterPage)),
    );
    container.read(pageResumeProvider.notifier).state = (
      location: RouteName.warehouseInspections,
      tick: 1,
    );
    await tester.pump();

    repository.pendingCountValue = 2;
    container.read(pageResumeProvider.notifier).state = (
      location: RouteName.qualityTaskCenter,
      tick: 2,
    );
    await tester.pumpAndSettle();

    expect(repository.pendingCountCalls, 2);
    expect(find.text('2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('task center lists pending receipts as table rows', (
    tester,
  ) async {
    await _pumpTaskCenter(tester, _twoTypeDispositionRepository());

    expect(find.byKey(const ValueKey('row:receipt-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('row:receipt-2')), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsOneWidget);
    expect(find.text('WT20260823000002'), findsOneWidget);
  });

  testWidgets('type segments filter the queue by receipt type', (tester) async {
    await _pumpTaskCenter(tester, _twoTypeDispositionRepository());

    // 分段文本与表头筛选桶同名（如「委外回厂」），点击须限定在分段导航内。
    Finder segmentText(String text) => find.descendant(
      of: find.byType(SegmentedButton<String>),
      matching: find.text(text),
    );

    await tester.tap(segmentText('委外回厂'));
    await tester.pumpAndSettle();

    expect(find.text('CJ20260822000001'), findsNothing);
    expect(find.text('WT20260823000002'), findsOneWidget);

    // 点「全部待检单」回到全部。
    await tester.tap(segmentText('全部待检单'));
    await tester.pumpAndSettle();

    expect(find.text('CJ20260822000001'), findsOneWidget);
    expect(find.text('WT20260823000002'), findsOneWidget);
  });

  testWidgets('search narrows the queue by bill number', (tester) async {
    await _pumpTaskCenter(tester, _twoTypeDispositionRepository());

    await tester.enterText(find.byType(TextField), 'WT2026');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('CJ20260822000001'), findsNothing);
    expect(find.text('WT20260823000002'), findsOneWidget);
  });

  testWidgets('double-tap opens the inspection detail page and back returns', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = _twoItemDispositionRepository();
    final router = GoRouter(
      initialLocation: RouteName.warehouseInspections,
      routes: [
        GoRoute(
          path: RouteName.warehouseInspections,
          builder: (_, _) => const QualityPendingDisposalPage(),
        ),
        GoRoute(
          path: '${RouteName.warehouseInspections}/:receiptType/:receiptId',
          builder: (_, s) => ProcurementInspectionDetailPage(
            receiptType: s.pathParameters['receiptType']!,
            receiptId: s.pathParameters['receiptId']!,
            extra: s.extra,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._taskCenterOverrides(repository),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: _routerApp(router),
      ),
    );
    await tester.pumpAndSettle();

    // 任务中心表格：双击行进入本单处置页。
    await _doubleTapRow(tester, find.text('CJ20260822000001'));
    await tester.pumpAndSettle();

    // go_router 的 push 在测试环境不同步 routeInformationProvider，
    // 以页面内容断言导航结果：明细表打开、任务表格退场。
    expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsOneWidget);
    expect(find.text('测试物料A(G0001)'), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsOneWidget);
    expect(find.byKey(const ValueKey('row:receipt-1')), findsNothing);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    // 返回任务中心后队列重载，表格行重新可见。
    expect(find.byKey(const ValueKey('row:receipt-1')), findsOneWidget);
    expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsNothing);
  });

  testWidgets('原单按箱而IQC按个：提示换算，24合格24不合格只提交一次原验收量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _FakeInspectionRepository(
      inspectionItems: [
        ProcurementInspectionItem.fromJson(const {
          'id': 'inspection-item-1',
          'goodsCode': 'G0001',
          'goodsName': '盒装零件',
          'unitId': 'unit-box',
          'sourceUnitName': '箱',
          'unitRate': 24,
          'baseUnitId': 'unit-piece',
          'baseUnitName': '个',
          'receivedBaseQty': 48,
          'remainingBaseQty': 48,
          'status': 'PENDING',
        }),
      ],
    );
    await _pumpInspectionDetailPage(tester, repository);
    expect(find.textContaining('待检量 48 个'), findsOneWidget);
    expect(find.textContaining('48 箱'), findsNothing);
    final pass = find.byKey(const Key('iqc-report-pass-inspection-item-1'));
    await tester.tap(
      find.descendant(of: pass, matching: find.byType(UtenFieldHintIcon)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('原单1箱 = 24个'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _selectRow(tester, '盒装零件(G0001)');
    await tester.enterText(pass, '24');
    await tester.enterText(
      find.byKey(const Key('iqc-report-fail-inspection-item-1')),
      '24',
    );
    await _submitReport(tester);
    expect(find.textContaining('合格 24 个、不合格 24 个'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '结论原因(必填)'), '外观不良');
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pumpAndSettle();
    final line = repository.decideBatchCalls.single.items.single;
    expect(line.expectedRemainingBaseQty, 48);
    expect(line.passBaseQty, 24);
    expect(line.failBaseQty, 24);
  });

  testWidgets('提交报告默认全合格：责任提示 + 空结论原因可提交', (tester) async {
    final repository = _dispositionRepository();
    await _pumpInspectionDetailPage(tester, repository);

    await _selectRow(tester, '测试物料(G0001)');
    // 行内默认：合格=剩余 5、不合格=0。
    expect(
      find.byKey(const Key('iqc-report-pass-inspection-item-1')),
      findsOneWidget,
    );
    expect(find.widgetWithText(UtenButton, '提交报告'), findsOneWidget);
    await _submitReport(tester);

    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('inspection-report-confirm-total')),
      findsOneWidget,
    );
    expect(find.textContaining('合格 5 个、不合格 0 个'), findsOneWidget);
    expect(find.text('结论原因(选填)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pumpAndSettle();

    expect(repository.decideBatchCalls, hasLength(1));
    final call = repository.decideBatchCalls.single;
    expect(call.items, hasLength(1));
    expect(call.items.single.inspectionItemId, 'inspection-item-1');
    expect(call.items.single.passBaseQty, 5);
    expect(call.items.single.failBaseQty, 0);
    expect(call.reason, isNull);
    expect(repository.disposeCalls, isEmpty);
  });

  testWidgets('填不合格数量时结论原因必填，填好后才提交', (tester) async {
    final repository = _dispositionRepository();
    await _pumpInspectionDetailPage(tester, repository);

    await _selectRow(tester, '测试物料(G0001)');
    await tester.enterText(
      find.byKey(const Key('iqc-report-pass-inspection-item-1')),
      '0',
    );
    await tester.enterText(
      find.byKey(const Key('iqc-report-fail-inspection-item-1')),
      '5',
    );
    await tester.pump();
    await _submitReport(tester);

    expect(find.text('结论原因(必填)'), findsOneWidget);
    expect(find.textContaining('合格 0 个、不合格 5 个'), findsOneWidget);

    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pump();

    // 错误经 ⓘ 字段说明披露（全站约定）：弹窗不关、未提交即可判定校验生效，
    // ⓘ 内容展示由组件测试（disabled_field_hint_test）覆盖。
    expect(find.text('确认提交检验报告'), findsOneWidget);
    expect(repository.decideBatchCalls, isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, '结论原因(必填)'),
      '外观不良退供应商',
    );
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pumpAndSettle();

    expect(repository.decideBatchCalls, hasLength(1));
    final call = repository.decideBatchCalls.single;
    expect(call.items.single.passBaseQty, 0);
    expect(call.items.single.failBaseQty, 5);
    expect(call.reason, '外观不良退供应商');
  });

  testWidgets('多行一次提交报告：单事务 decide-batch 带全部所选行', (tester) async {
    final repository = _twoItemDispositionRepository();
    await _pumpInspectionDetailPage(tester, repository);

    await tester.tap(find.text('测试物料A(G0001)'));
    await tester.pump();
    await tester.tap(find.text('测试物料B(G0002)'));
    await tester.pumpAndSettle();
    expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
    expect(find.text('已选 2 项'), findsWidgets);
    await _submitReport(tester);

    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('共 2 行明细'), findsOneWidget);
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pumpAndSettle();

    expect(repository.decideBatchCalls, hasLength(1));
    final call = repository.decideBatchCalls.single;
    expect(call.items.map((item) => item.inspectionItemId).toSet(), {
      'inspection-item-1',
      'inspection-item-2',
    });
    expect(call.items.map((item) => item.expectedRemainingBaseQty).toSet(), {
      5,
      3,
    });
    expect(call.reason, isNull);
    expect(repository.disposeCalls, isEmpty);
  });

  testWidgets('部分行提交后本单保留，剩余行继续可办', (tester) async {
    final repository = _twoItemDispositionRepository();
    await _pumpInspectionDetailPage(tester, repository);

    await _selectRow(tester, '测试物料A(G0001)');
    await _submitReport(tester);
    await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
    await tester.pumpAndSettle();

    expect(repository.decideBatchCalls, hasLength(1));
    expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsOneWidget);
    expect(find.text('测试物料B(G0002)'), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsOneWidget);
  });

  testWidgets(
    'fully disposed receipt shows completion state on the detail page',
    (tester) async {
      final repository = _dispositionRepository();
      await _pumpInspectionDetailPage(tester, repository);

      await _selectRow(tester, '测试物料(G0001)');
      await _submitReport(tester);
      await tester.tap(
        find.byKey(const Key('inspection-report-confirm-submit')),
      );
      await tester.pumpAndSettle();

      expect(find.text('本单待检已全部处理完成'), findsOneWidget);
      expect(find.textContaining('仓库核对实物和库位后才增加库存'), findsOneWidget);
      expect(find.text('返回任务中心'), findsOneWidget);
      expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsNothing);
    },
  );

  test(
    'IQC PASS refreshes the warehouse stock-in queue and keeps truthful copy',
    () {
      final source = File(
        'lib/features/quality/pages/quality_pending_disposal_page.dart',
      ).readAsStringSync();

      // 2026-09-05 提交报告（decide-batch）后仍要刷新仓库队列角标
      //（合并页可办计数：待入库+需退回）；旧单行/批量合格双入口已收敛为单按钮。
      expect(
        RegExp(
          r'ref\.invalidate\(warehouseQualityResultPendingCountProvider\)',
        ).allMatches(source),
        hasLength(1),
      );
      expect(source, contains('已转仓库待入库，尚未增加可用库存'));
      expect(source, isNot(contains('已自动入库')));
    },
  );

  testWidgets(
    '375px keeps the inspection detail table operable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpInspectionDetailPage(tester, _twoItemDispositionRepository());

      expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsOneWidget);
      expect(find.byKey(const Key('iqc-submit-report')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('375px keeps the task center table operable without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpTaskCenter(tester, _twoItemDispositionRepository());

    expect(find.byKey(const Key('iqc-receipt-table')), findsOneWidget);
    expect(find.text('CJ20260822000001'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('global badge refresh includes the quality pending provider', () {
    // 2026-09-11：登录/返回工作台的角标刷新由待办徽章注册表统一负责
    // （工作台只剩一行 invalidateTodoBadgeCaches(ref)），契约目标随之搬家。
    final source = File(
      'lib/shared/badges/todo_badge_registry.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('ref.invalidate(procurementInspectionPendingCountProvider);'),
    );
  });
}

/// 双击指定表格行（两次点按间隔 50ms，落在 350ms 手动双击判定窗内）——
/// 任务中心表格行双击 = 进入本单处置页。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _pumpWorkbenchBadge(
  WidgetTester tester, {
  required int count,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        procurementInspectionPendingCountProvider.overrideWith(
          (ref) async => count,
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: WorkbenchCardBadge(kind: WorkbenchBadgeKind.qualityInspection),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Override> _taskCenterOverrides(_FakeInspectionRepository repository) {
  return [
    sessionProvider.overrideWith(_QualityReviewerSessionNotifier.new),
    currentPermissionsProvider.overrideWithValue({
      Perm.procurementInspectionView,
      Perm.procurementInspectionHandle,
    }),
    isSuperAdminProvider.overrideWithValue(false),
    procurementInspectionRepositoryProvider.overrideWithValue(repository),
  ];
}

Future<void> _pumpTaskCenter(
  WidgetTester tester,
  _FakeInspectionRepository repository,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ..._taskCenterOverrides(repository),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: const MaterialApp(home: QualityPendingDisposalPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpInspectionDetailPage(
  WidgetTester tester,
  _FakeInspectionRepository repository,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ..._taskCenterOverrides(repository),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        home: ProcurementInspectionDetailPage(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
          extra: repository.receipts.isNotEmpty
              ? repository.receipts.first
              : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 单击行勾选（2026-09-05 起行内编辑合格/不合格数量，底部统一「提交报告」）。
Future<void> _selectRow(WidgetTester tester, String rowText) async {
  expect(find.byKey(const Key('iqc-item-table-receipt-1')), findsOneWidget);
  final row = find.text(rowText);
  expect(row, findsOneWidget);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

Future<void> _submitReport(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('iqc-submit-report')));
  await tester.pumpAndSettle();
}

_FakeInspectionRepository _dispositionRepository() => _FakeInspectionRepository(
  receipts: const [
    PendingInspectionReceipt(
      receiptType: 'PURCHASE',
      receiptId: 'receipt-1',
      billNo: 'CJ20260822000001',
      itemCount: 1,
      pendingBaseQty: 5,
    ),
  ],
  inspectionItems: const [
    ProcurementInspectionItem(
      baseUnitId: 'unit-piece',
      baseUnitName: '个',
      sourceUnitName: '个',
      unitRate: 1,
      id: 'inspection-item-1',
      receiptItemId: 'receipt-item-1',
      goodsId: 'goods-1',
      goodsCode: 'G0001',
      goodsName: '测试物料',
      receivedBaseQty: 5,
      passedBaseQty: 0,
      failedBaseQty: 0,
      remainingBaseQty: 5,
      status: 'PENDING',
    ),
  ],
);

_FakeInspectionRepository _twoItemDispositionRepository() =>
    _FakeInspectionRepository(
      receipts: const [
        PendingInspectionReceipt(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
          billNo: 'CJ20260822000001',
          itemCount: 2,
          pendingBaseQty: 8,
        ),
      ],
      inspectionItems: const [
        ProcurementInspectionItem(
          baseUnitId: 'unit-piece',
          baseUnitName: '个',
          sourceUnitName: '个',
          unitRate: 1,
          id: 'inspection-item-1',
          receiptItemId: 'receipt-item-1',
          goodsId: 'goods-1',
          goodsCode: 'G0001',
          goodsName: '测试物料A',
          receivedBaseQty: 5,
          passedBaseQty: 0,
          failedBaseQty: 0,
          remainingBaseQty: 5,
          status: 'PENDING',
        ),
        ProcurementInspectionItem(
          baseUnitId: 'unit-piece',
          baseUnitName: '个',
          sourceUnitName: '个',
          unitRate: 1,
          id: 'inspection-item-2',
          receiptItemId: 'receipt-item-2',
          goodsId: 'goods-2',
          goodsCode: 'G0002',
          goodsName: '测试物料B',
          receivedBaseQty: 3,
          passedBaseQty: 0,
          failedBaseQty: 0,
          remainingBaseQty: 3,
          status: 'PENDING',
        ),
      ],
    );

/// 一张采购收货单 + 一张委外回厂单（任务中心筛选/搜索用）。
_FakeInspectionRepository _twoTypeDispositionRepository() =>
    _FakeInspectionRepository(
      receipts: const [
        PendingInspectionReceipt(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
          billNo: 'CJ20260822000001',
          supplierName: '采购供应商',
          itemCount: 1,
          pendingBaseQty: 5,
        ),
        PendingInspectionReceipt(
          receiptType: 'SUBCONTRACT',
          receiptId: 'receipt-2',
          billNo: 'WT20260823000002',
          supplierName: '委外加工商',
          itemCount: 1,
          pendingBaseQty: 3,
        ),
      ],
      inspectionItems: const [
        ProcurementInspectionItem(
          baseUnitId: 'unit-piece',
          baseUnitName: '个',
          sourceUnitName: '个',
          unitRate: 1,
          id: 'inspection-item-1',
          goodsCode: 'G0001',
          goodsName: '采购物料',
          receivedBaseQty: 5,
          remainingBaseQty: 5,
          status: 'PENDING',
        ),
        ProcurementInspectionItem(
          baseUnitId: 'unit-piece',
          baseUnitName: '个',
          sourceUnitName: '个',
          unitRate: 1,
          id: 'inspection-item-2',
          goodsCode: 'G0002',
          goodsName: '委外物料',
          receivedBaseQty: 3,
          remainingBaseQty: 3,
          status: 'PENDING',
        ),
      ],
    );

Widget _routerApp(GoRouter router) {
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
  );
}

class _FakeInspectionRepository implements ProcurementInspectionRepository {
  _FakeInspectionRepository({
    this.pendingCountValue = 0,
    List<PendingInspectionReceipt> receipts = const [],
    List<ProcurementInspectionItem> inspectionItems = const [],
  }) : receipts = List.of(receipts),
       inspectionItems = List.of(inspectionItems);

  int pendingCountValue;
  int pendingCountCalls = 0;
  final List<PendingInspectionReceipt> receipts;
  final List<ProcurementInspectionItem> inspectionItems;
  final List<_DispositionCall> disposeCalls = [];
  final List<_BatchPassCall> batchPassCalls = [];
  final List<_DecideBatchCall> decideBatchCalls = [];

  @override
  Future<int> pendingCount() async {
    pendingCountCalls += 1;
    return pendingCountValue;
  }

  @override
  Future<List<PendingInspectionReceipt>> pendingReceipts() async => receipts;

  @override
  Future<List<ProcurementInspectionItem>> items(
    String receiptType,
    String receiptId,
  ) async => inspectionItems;

  @override
  Future<void> dispose({
    required String receiptType,
    required String receiptId,
    required String inspectionItemId,
    required String action,
    double? baseQty,
    String? reason,
    required String idempotencyKey,
  }) async {
    disposeCalls.add(
      _DispositionCall(action: action, baseQty: baseQty, reason: reason),
    );
    inspectionItems.removeWhere((item) => item.id == inspectionItemId);
    if (inspectionItems.isEmpty) receipts.clear();
  }

  @override
  Future<void> passBatch({
    required String receiptType,
    required String receiptId,
    required List<ProcurementInspectionBatchPassItem> items,
    String? reason,
  }) async {
    batchPassCalls.add(_BatchPassCall(items: List.of(items), reason: reason));
    final ids = items.map((item) => item.inspectionItemId).toSet();
    inspectionItems.removeWhere((item) => ids.contains(item.id));
    if (inspectionItems.isEmpty) receipts.clear();
  }

  @override
  Future<void> decideBatch({
    required String receiptType,
    required String receiptId,
    required List<ProcurementInspectionDecideItem> items,
    String? reason,
  }) async {
    decideBatchCalls.add(
      _DecideBatchCall(items: List.of(items), reason: reason),
    );
    final ids = items.map((item) => item.inspectionItemId).toSet();
    inspectionItems.removeWhere((item) => ids.contains(item.id));
    if (inspectionItems.isEmpty) receipts.clear();
  }
}

class _QualityReviewerSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-qa-1',
      code: 'QA-001',
      name: '品质审核员',
      roles: [],
      employeeId: 'employee-qa-1',
    ),
  );
}

class _DispositionCall {
  const _DispositionCall({
    required this.action,
    required this.baseQty,
    required this.reason,
  });

  final String action;
  final double? baseQty;
  final String? reason;
}

class _BatchPassCall {
  const _BatchPassCall({required this.items, required this.reason});

  final List<ProcurementInspectionBatchPassItem> items;
  final String? reason;
}

class _DecideBatchCall {
  const _DecideBatchCall({required this.items, required this.reason});

  final List<ProcurementInspectionDecideItem> items;
  final String? reason;
}
