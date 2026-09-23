import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/filter_segment_tap.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'shared headers send server sort and full-scope facet filters with true planning issue date',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = _Gateway(
        _data(capability: true, includePreparation: true),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('FG-task-1')).dy,
        lessThan(tester.getTopLeft(find.text('SC-A')).dy),
      );
      expect(find.text('计划下达日期'), findsOneWidget);
      expect(find.text('2026-09-08'), findsWidgets);
      await tester.tap(find.text('计划下达日期'));
      await tester.pumpAndSettle();
      expect(find.text('从近到远'), findsOneWidget);
      await tester.tap(find.text('从近到远'));
      await tester.pumpAndSettle();
      expect(gateway.queries.last['sort'], 'issuedAt');
      expect(gateway.queries.last['order'], 'desc');
      expect(gateway.queries.last['page'], 1);
      await tester.tap(find.text('委外目标件名称'));
      await tester.pumpAndSettle();
      expect(find.text('完整范围物料 (125)'), findsOneWidget);
      await tester.tap(find.text('完整范围物料 (125)'));
      await tester.pumpAndSettle();
      expect(gateway.queries.last['filters'], {'goods': 'goods-source-uuid'});
      expect(gateway.queries.last['status'], 'WAITING_ORDER');
      expect(gateway.queries.last['page'], 1);
      expect(find.byType(PopupMenuButton<dynamic>), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'each category and fullscreen have one table-owned selection action',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: true)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(
        const Key('subcontract-decomposition-create-order'),
      );
      // ADR-098：等待财务审核 / 财务已通过 / 财务驳回三段合并为「进行中」。
      for (final category in ['待处理', '进行中', '历史记录']) {
        await tester.tap(find.text(category));
        await tester.pumpAndSettle();
        if (category == '历史记录') {
          expect(action, findsNothing);
          expect(find.byType(UtenSelectionSummaryPill), findsNothing);
          await selectFilterSegment(tester, '全部');
          await tester.pumpAndSettle();
        }
        expect(action, findsOneWidget, reason: category);
        expect(
          find.byType(UtenSelectionSummaryPill),
          findsOneWidget,
          reason: category,
        );
        expect(
          find.ancestor(
            of: action,
            matching: find.byType(MasterDataTableView<OperationsWorkbenchTask>),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('FG-task-1'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.text('全屏'));
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const Key('master-table-clear-selection')));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(tester.widget<UtenButton>(action).onPressed, isNull);
      await tester.tap(find.text('退出全屏'));
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(find.text('已选 0 项'), findsOneWidget);
      await tester.tap(find.text('FG-task-1'));
      await tester.pumpAndSettle();
      for (final width in [900.0, 375.0, 1400.0]) {
        tester.view.physicalSize = Size(width, 1400);
        await tester.pumpAndSettle();
        expect(action, findsOneWidget, reason: 'width=$width');
        expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
        expect(find.text('已选 1 项'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(375, 1400);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenSelectionSummaryPill),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(tester.widget<UtenButton>(action).onPressed, isNull);
      // 375px 下分类栏收成「分类」下拉（2026-09-14），统一走共用助手选段。
      await selectFilterSegment(tester, '历史记录');
      await tester.pumpAndSettle();
      expect(action, findsNothing);
      expect(find.byType(UtenSelectionSummaryPill), findsNothing);
      await selectFilterSegment(tester, '全部');
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact decomposition selects issued application lines and enables one primary action',
    (tester) async {
      final gateway = _Gateway(_data(capability: true));
      tester.view.physicalSize = const Size(375, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('subcontract-decomposition-compact-list')),
        findsOneWidget,
      );
      // 进页面只拉一次 size=1 概览（阶段计数徽章），不带 status 过滤。
      expect(gateway.statuses, [null]);
      // 2026-09-03 分类范式：阶段行默认不选（引导占位，不发列表请求），
      // 原「概览卡 + 阶段/异常下拉」已删除。
      expect(find.text('在上方选择阶段后开始办理'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      // 2026-09-06 委外不再有「分解」行为用语：首段改名「待处理」。
      // 375px 分类栏放不下时收成「分类」下拉（2026-09-14）：段名在菜单里断言与点选；
      // ADR-098 三段合并后窄屏也放得下，此时段名直接是芯片。两种形态都要能过。
      final segmentMenu = find.byIcon(Icons.keyboard_arrow_down_rounded);
      if (segmentMenu.evaluate().isNotEmpty) {
        await tester.tap(segmentMenu);
        await tester.pumpAndSettle();
      }
      expect(find.text('待处理'), findsOneWidget);
      var button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNull);

      // 先 tap 阶段段「待处理」：加载任务卡后才能勾选。
      await tester.tap(find.text('待处理').last);
      await tester.pumpAndSettle();
      expect(gateway.statuses, [null, 'WAITING_ORDER']);
      expect(find.text('计划申请已下达 / 待分解'), findsNWidgets(2));

      await tester.tap(find.byType(Checkbox).at(0));
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      await tester.pumpAndSettle();

      button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.text('生成委外订货单(2)'), findsOneWidget);
      // 2026-09-06 顶部选中摘要条退役：已选计数走右下角悬浮组标准胶囊。
      expect(
        find.byKey(const Key('subcontract-decomposition-selection')),
        findsNothing,
      );
      expect(find.text('已选 2 项'), findsOneWidget);
    },
  );

  testWidgets(
    'waiting-production tasks merge into 待处理 with progress dialog on double-click',
    (tester) async {
      // 2026-09-06 计划委外申请页并入任务中心：待生产合成行进「待处理」段，
      // 阶段列显示车间进度；合成行不可勾选；双击先看「产品进度」弹窗。
      final gateway = _Gateway(
        _data(capability: true, includePreparation: true),
      );
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();

      // 合成行（IN_PROGRESS→正在生产中；NOTIFYING_WORKSHOP→正在等待安排生产）；
      // FULLY_NOTIFIED 不合成（其申请单已由服务端生成）。
      expect(find.textContaining('委外件A'), findsOneWidget);
      expect(find.textContaining('委外件B'), findsOneWidget);
      expect(find.textContaining('委外件C'), findsNothing);
      expect(find.text('正在生产中'), findsOneWidget);
      expect(find.text('正在等待安排生产'), findsOneWidget);
      final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
        find.byKey(const Key('subcontract-decomposition-table')),
      );
      final blocked = table.items.firstWhere(
        (task) => task.preparationTaskId == 'task-a',
      );
      final ready = table.items.firstWhere((task) => task.taskId == 'task-1');
      expect(table.rowColor!(blocked), isNotNull);
      expect(table.rowColor!(ready), isNull);
      expect(table.idOf!(blocked), isNull);
      expect(table.idOf!(ready), 'task-1');
      final denied = _task(
        'denied',
        'application-denied',
        'item-denied',
        canCreateOrder: false,
      );
      expect(table.idOf!(denied), isNull);
      expect(
        table.rowColor!(denied),
        isNotNull,
        reason:
            'An explicit server denial overrides otherwise complete legacy application facts.',
      );
      // 真实申请行与合成行同表。
      expect(find.text('EA-application-1'), findsWidgets);

      // 双击不可下单的合成行 → 产品进度弹窗(车间进度时间线)。
      await _doubleTapRow(tester, find.text('委外件A'));
      await tester.pumpAndSettle();
      expect(find.textContaining('产品进度 ·'), findsOneWidget);
      expect(find.text('正在生产，暂时不能下委外单'), findsOneWidget);
      expect(
        tester
            .getTopLeft(
              find.byKey(const Key('subcontract-order-production-blocked')),
            )
            .dy,
        lessThan(tester.getTopLeft(find.text('生产中（当前）')).dy),
      );
      expect(find.text('已通知委外·生成申请'), findsOneWidget);
      expect(find.text('生产中（当前）'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      // 双击申请行 → 全链路进度弹窗，可再深链只读申请。
      await _doubleTapRow(tester, find.text('FG-task-1'));
      await tester.pumpAndSettle();
      expect(find.text('待生成委外订货单（当前）'), findsOneWidget);
      expect(
        find.byKey(const Key('subcontract-order-production-blocked')),
        findsNothing,
      );
      expect(find.text('查看申请单'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ADR-103 route B: locked row is yellow, unselectable, explained; ready row shows available qty',
    (tester) async {
      // 路线 B(单一子件直发)申请行：子件没货 = WAITING_COMPONENT_STOCK(黄底、不可勾选、
      // 状态列「等子件到货」带悬浮说明、弹窗顶部横幅)；子件到货 = COMPONENT_STOCK_READY
      // (状态列带仓内可动用量、可勾选)；「待处理」段红黄两枚徽章。
      final gateway = _Gateway(
        _data(capability: true, includeComponentRoute: true),
      );
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 「待处理」段同构挂两枚：红 = WAITING_ORDER(3)、黄 = WAITING_COMPONENT_STOCK(1)。
      final stages = find.byKey(const Key('subcontract-decomposition-stages'));
      expect(
        find.descendant(of: stages, matching: find.byType(UtenInProgressBadge)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: stages,
          matching: find.byType(UtenNotificationBadge),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: stages, matching: find.text('3')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: stages, matching: find.text('1')),
        findsOneWidget,
      );

      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();

      final table = tester.widget<MasterDataTableView<OperationsWorkbenchTask>>(
        find.byKey(const Key('subcontract-decomposition-table')),
      );
      final locked = table.items.firstWhere(
        (task) => task.taskId == 'task-locked',
      );
      final ready = table.items.firstWhere(
        (task) => task.taskId == 'task-ready',
      );
      final plain = table.items.firstWhere((task) => task.taskId == 'task-1');
      // 锁行黄底(与路线 A 红底区分)、不可勾选；解锁行正常、可勾选。
      expect(
        table.rowColor!(locked),
        UtenColors.warning.withValues(alpha: 0.16),
      );
      expect(table.idOf!(locked), isNull);
      expect(table.rowColor!(ready), isNull);
      expect(table.idOf!(ready), 'task-ready');
      expect(table.rowColor!(plain), isNull);
      // 老服务端(canCreateOrder 为空)回落本地规则时，锁态一样不放行。
      final legacyLocked = _task(
        'legacy-locked',
        'application-legacy',
        'item-legacy',
        canCreateOrder: null,
        displayStage: 'WAITING_COMPONENT_STOCK',
      );
      expect(table.idOf!(legacyLocked), isNull);
      expect(
        table.rowColor!(legacyLocked),
        UtenColors.warning.withValues(alpha: 0.16),
      );
      final legacyReady = _task(
        'legacy-ready',
        'application-legacy-ready',
        'item-legacy-ready',
        canCreateOrder: null,
        displayStage: 'COMPONENT_STOCK_READY',
        componentAvailableQty: 5,
      );
      expect(table.idOf!(legacyReady), 'legacy-ready');

      // 状态列文案与悬浮说明；只读申请列对锁行说明解锁条件。
      expect(find.text('等子件到货(仓内可动用 0)'), findsOneWidget);
      expect(find.text('子件已到货·可下单(仓内可动用 5 件)'), findsOneWidget);
      expect(
        find.byTooltip('子件尚未入库，入库后自动解锁；仓库发出去的是子件，加工完回厂的是委外件'),
        findsOneWidget,
      );
      expect(
        find.byTooltip('子件已到货，可以生成委外订货单；订货数量可以超过仓内可动用量，仓库会按到货分批发料'),
        findsOneWidget,
      );
      expect(find.text('等子件到货·入库后自动解锁'), findsOneWidget);
      expect(find.text('EA-application-ready'), findsWidgets);

      // 双击锁行 → 弹窗顶部横幅 + 路线 B 步骤(等子件到货 = 当前, 无「前置生产完成」)。
      await _doubleTapRow(tester, find.text('FG-task-locked'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('subcontract-order-component-blocked')),
        findsOneWidget,
      );
      expect(find.text('子件尚未入库，暂时不能下委外单；子件入库后任务中心会自动解锁'), findsOneWidget);
      expect(find.text('等子件到货（当前）'), findsOneWidget);
      expect(find.text('待生成委外订货单'), findsOneWidget);
      expect(find.text('前置生产完成'), findsNothing);
      expect(find.text('子件出仓·委外商加工'), findsOneWidget);
      expect(find.text('回厂来料质检·入库结案'), findsOneWidget);
      expect(find.text('子件仓内可动用 0 件'), findsOneWidget);
      expect(find.textContaining('回厂 IQC'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      // 双击解锁行 → 无横幅，「等子件到货」已完成、「待生成委外订货单」当前。
      await _doubleTapRow(tester, find.text('FG-task-ready'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('subcontract-order-component-blocked')),
        findsNothing,
      );
      expect(find.text('等子件到货'), findsOneWidget);
      expect(find.text('待生成委外订货单（当前）'), findsOneWidget);
      expect(find.text('前置生产完成'), findsNothing);
      expect(find.text('子件仓内可动用 5 件'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      // 双击路线 A / 普通申请行 → 步骤不变(前置生产完成在列, 回厂改「来料质检」)。
      await _doubleTapRow(tester, find.text('FG-task-1'));
      await tester.pumpAndSettle();
      expect(find.text('前置生产完成'), findsOneWidget);
      expect(find.text('待生成委外订货单（当前）'), findsOneWidget);
      expect(find.text('目标件出仓·加工商加工'), findsOneWidget);
      expect(find.text('回厂来料质检·入库结案'), findsOneWidget);
      expect(
        find.byKey(const Key('subcontract-order-component-blocked')),
        findsNothing,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ADR-103 route B compact cards: locked card is yellow without checkbox, ready card selectable',
    (tester) async {
      final gateway = _Gateway(
        _data(capability: true, includeComponentRoute: true),
      );
      tester.view.physicalSize = const Size(375, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.subcontractApplicationView,
              Perm.subcontractOrderView,
              Perm.subcontractOrderCreate,
              Perm.subcontractOrderDecompose,
            }),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await selectFilterSegment(tester, '待处理');
      await tester.pumpAndSettle();
      // 两条普通行 + 一条解锁行可勾选；锁行没有勾选框。
      expect(find.byType(Checkbox), findsNWidgets(3));
      final lockedCard = find.ancestor(
        of: find.text('等子件到货(仓内可动用 0)'),
        matching: find.byType(Card),
      );
      expect(lockedCard, findsOneWidget);
      expect(
        tester.widget<Card>(lockedCard).color,
        UtenColors.warning.withValues(alpha: 0.16),
      );
      expect(
        find.descendant(of: lockedCard, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        find.descendant(of: lockedCard, matching: find.text('等子件到货·入库后自动解锁')),
        findsOneWidget,
      );
      final readyCard = find.ancestor(
        of: find.text('子件已到货·可下单(仓内可动用 5 件)'),
        matching: find.byType(Card),
      );
      expect(readyCard, findsOneWidget);
      expect(tester.widget<Card>(readyCard).color, isNull);
      expect(
        find.descendant(of: readyCard, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in const [
    (
      name: 'missing local decompose permission',
      permissions: <String>{},
      capability: true,
    ),
    (
      name: 'server capability denies create',
      permissions: <String>{
        Perm.subcontractApplicationView,
        Perm.subcontractOrderView,
        Perm.subcontractOrderCreate,
        Perm.subcontractOrderDecompose,
      },
      capability: false,
    ),
  ]) {
    testWidgets('${scenario.name} hides selection and keeps action disabled', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(scenario.permissions),
            apiClientProvider.overrideWithValue(_api()),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: scenario.capability)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Checkbox), findsNothing);
      final action = find.byKey(
        const Key('subcontract-decomposition-create-order'),
      );
      if (scenario.permissions.isEmpty) {
        expect(action, findsNothing);
      } else {
        expect(action, findsOneWidget);
        expect(tester.widget<UtenButton>(action).onPressed, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }
}

/// 双击指定行（两次点按间隔 50ms，落在 350ms 手动双击判定窗内）。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

/// 待生产委外任务桩（合成行数据源；其余请求回空）。
ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final dynamic data;
        if (request.path.contains('/subcontract-make-tasks/')) {
          final id = request.path.split('/').last;
          data = {
            'taskId': id,
            'analysisId': id == 'task-a' ? 'analysis-1' : 'analysis-2',
            'status': 'ACTIVE',
            'goodsCode': id == 'task-a' ? 'SC-A' : 'SC-B',
            'goodsName': id == 'task-a' ? '委外件A' : '委外件B',
            'workshopStatus': id == 'task-a'
                ? 'IN_PRODUCTION'
                : 'NOTIFYING_WORKSHOP',
          };
        } else {
          data = <dynamic>[];
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

class _Gateway implements OperationsWorkbenchGateway {
  _Gateway(this.data);
  final OperationsWorkbenchData data;
  final List<String?> statuses = <String?>[];
  final List<Map<String, Object?>> queries = [];

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async {
    statuses.add(status);
    queries.add({
      'page': page,
      'sort': sort,
      'order': order,
      'status': status,
      'filters': Map<String, String?>.from(columnFilters),
    });
    return data;
  }
}

OperationsWorkbenchData _data({
  required bool capability,
  bool includePreparation = false,
  bool includeComponentRoute = false,
}) => OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.subcontract,
  summary: OperationsWorkbenchSummary(
    totalTasks: includePreparation ? 4 : 2,
    overdueTasks: 0,
    openTasks: 2,
    openQty: 12,
    // ADR-103：服务端 WAITING_ORDER 已减去被锁的路线 B 行，锁行单独一键。
    statusCounts: {
      'WAITING_ORDER': includePreparation
          ? 4
          : includeComponentRoute
          ? 3
          : 2,
      if (includeComponentRoute) 'WAITING_COMPONENT_STOCK': 1,
    },
  ),
  items: [
    _task('task-1', 'application-1', 'application-item-1'),
    _task('task-2', 'application-2', 'application-item-2'),
    if (includePreparation) ...[
      _preparationRow('task-a', 'SC-A', '委外件A', 'IN_PRODUCTION'),
      _preparationRow('task-b', 'SC-B', '委外件B', 'NOTIFYING_WORKSHOP'),
    ],
    if (includeComponentRoute) ...[
      _task(
        'task-locked',
        'application-locked',
        'application-item-locked',
        canCreateOrder: false,
        displayStage: 'WAITING_COMPONENT_STOCK',
        componentAvailableQty: 0,
      ),
      _task(
        'task-ready',
        'application-ready',
        'application-item-ready',
        displayStage: 'COMPONENT_STOCK_READY',
        componentAvailableQty: 5,
      ),
    ],
  ],
  page: 1,
  size: 20,
  total: includePreparation ? 4 : 2,
  totalPages: 1,
  capabilities: OperationsWorkbenchCapabilities(
    canCreateSubcontractOrder: capability,
  ),
  facets: const {
    'goods': [
      MasterFacetBucket(
        value: 'goods-source-uuid',
        label: '完整范围物料',
        count: 125,
      ),
    ],
  },
);

OperationsWorkbenchTask _task(
  String taskId,
  String applicationId,
  String applicationItemId, {
  bool? canCreateOrder = true,
  String? displayStage,
  num? componentAvailableQty,
}) => OperationsWorkbenchTask(
  taskId: taskId,
  packageId: 'package-1',
  planId: 'plan-1',
  planNo: 'PP-001',
  warehouseName: '委外目标仓',
  goodsCode: 'FG-$taskId',
  goodsName: '委外目标件',
  spec: '标准',
  colorName: '本色',
  unitName: '件',
  supplyRoute: 'SUBCONTRACT',
  requiredQty: 10,
  allocatedQty: 0,
  fulfilledQty: 0,
  supplyPeggedQty: 0,
  openQty: 6,
  taskStatus: 'WAITING_ORDER',
  needDate: '2026-09-10',
  expectedDate: null,
  exceptionCode: null,
  updatedAt: '2026-08-30T10:00:00Z',
  issuedAt: '2026-09-07T18:30:00Z',
  canCreateOrder: canCreateOrder,
  displayStage: displayStage,
  componentAvailableQty: componentAvailableQty,
  actionDocument: OperationsActionDocument(
    id: applicationId,
    docType: 'SUBCONTRACT_APPLICATION',
    number: 'EA-$applicationId',
    path: '/subcontract/applications/$applicationId',
    canView: true,
    canEdit: false,
    status: '1',
  ),
  actionDocItemId: applicationItemId,
  actionDocumentRestricted: false,
);

OperationsWorkbenchTask _preparationRow(
  String id,
  String code,
  String name,
  String stage,
) => OperationsWorkbenchTask.fromJson({
  'taskId': id,
  'supplyRoute': 'SUBCONTRACT',
  'taskStatus': 'WAITING_ORDER',
  'goodsCode': code,
  'goodsName': name,
  'requiredQty': 10,
  'openQty': 10,
  'actionDocType': 'SUBCONTRACT_MAKE_TASK',
  'actionDocId': id,
  'actionDocCanView': true,
  'actionDocCanEdit': false,
  'actionDocStatus': stage,
}, OperationsWorkbenchDepartment.subcontract);
