import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/filter_segment_tap.dart';
import 'fake_subcontract_draw_gateway.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/data_display/uten_status_cell_color.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_application_kit.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_draw.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_kit_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_application_kit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/subcontract_task_source.dart';

const _decomposePermissions = {
  Perm.subcontractApplicationView,
  Perm.subcontractOrderView,
  Perm.subcontractOrderCreate,
  Perm.subcontractOrderDecompose,
};

void main() {
  testWidgets(
    'return to the task center reloads once and drops stale answers',
    (tester) async {
      _desktop(tester, const Size(1600, 1000));
      final gateway = _Gateway(_data(capability: true));
      final draw = FakeSubcontractDrawGateway(count: 3);
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: gateway,
              drawRepository: draw,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SubcontractDecompositionPage)),
      );
      final resume = container.read(pageResumeProvider.notifier);
      bumpPageResumeState(resume, RouteName.operationsSubcontractWorkbench);
      await tester.pumpAndSettle();
      // 2026-10-04 起红数「待处理」分类进页面自动选中：概览 + WAITING_ORDER 两次；
      // 领料红数单独按 /draw-tasks/count 取一次(ADR-171 起挂在待处理子分类行)。
      expect(gateway.queries, hasLength(2));
      expect(draw.countCalls, 1);
      // 再点已选中的「待处理」不重复发请求。
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      expect(gateway.queries, hasLength(2));
      expect(find.text('FG-task-2'), findsOneWidget);

      // One older refresh remains in flight while stock-in finishes elsewhere.
      final stale = Completer<OperationsWorkbenchData>();
      gateway.response = () => stale.future;
      await tester.tap(find.byTooltip('刷新委外任务'));
      await tester.pump();
      bumpPageResumeState(resume, '/warehouse/stock-in');
      // 入库是本端写操作(网络层推进写修订号, ADR-108), 返回任务中心时才按需重拉。
      container.read(dataWriteRevisionProvider.notifier).state++;
      gateway.response = null;
      gateway.data = _data(capability: true, onlyFirst: true);
      bumpPageResumeState(resume, RouteName.operationsSubcontractWorkbench);
      await tester.pumpAndSettle();
      expect(gateway.queries, hasLength(4));
      expect(gateway.queries.last['status'], 'WAITING_ORDER');
      expect(find.text('FG-task-2'), findsNothing);
      stale.complete(_data(capability: true));
      await tester.pumpAndSettle();
      expect(find.text('FG-task-2'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared headers send server sort and full-scope facet filters with true planning issue date',
    (tester) async {
      _desktop(tester, const Size(1600, 1000));
      final gateway = _Gateway(_data(capability: true));
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: gateway,
              drawRepository: FakeSubcontractDrawGateway(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 先做「进行中」的表头筛选(ADR-171 修订二拍平：领料行与申请行的列语义不同，
      // 「待处理」拍平表不做列头筛选——筛选在纯订货单表验证)——必须在任何表格
      // 滚动之前，滚动会折叠顶部阶段行。
      await tester.tap(find.text('进行中'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('委外件名称'));
      await tester.pumpAndSettle();
      expect(find.text('完整范围物料 (125)'), findsOneWidget);
      await tester.tap(find.text('完整范围物料 (125)'));
      await tester.pumpAndSettle();
      expect(gateway.queries.last['filters'], {'goods': 'goods-source-uuid'});
      expect(gateway.queries.last['status'], 'IN_PROGRESS');
      expect(gateway.queries.last['page'], 1);
      expect(find.byType(PopupMenuButton<dynamic>), findsNothing);

      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      expect(find.text('计划下达日期'), findsOneWidget);
      expect(find.text('2026-09-08'), findsWidgets);
      // 2026-10-06 状态列全站前置后，计划下达日期表头被挤出 1600 视口，先横向
      // 滚到位再点排序菜单。
      await tester.ensureVisible(find.text('计划下达日期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('计划下达日期'));
      await tester.pumpAndSettle();
      expect(find.text('从近到远'), findsOneWidget);
      await tester.tap(find.text('从近到远'));
      await tester.pumpAndSettle();
      expect(gateway.queries.last['sort'], 'issuedAt');
      expect(gateway.queries.last['order'], 'desc');
      expect(gateway.queries.last['page'], 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only the pending segment owns one table selection action across widths',
    (tester) async {
      _desktop(tester, const Size(1400, 1100));
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: true)),
              drawRepository: FakeSubcontractDrawGateway(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(
        const Key('subcontract-decomposition-create-order'),
      );
      final stageToolbar = tester.widget<UtenFilterToolbar<Object>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFilterToolbar<dynamic> &&
              widget.segmentsKey ==
                  const Key('subcontract-decomposition-stages'),
        ),
      );
      // The stage value is private to the page; preserve its exact callback
      // type instead of widening the callback's input to Object.
      // ignore: avoid_dynamic_calls
      final select = (stageToolbar as dynamic).onSelectionChanged as Function;
      void selectStage(String label) {
        final segment = stageToolbar.segments.singleWhere(
          (item) => item.label == label,
        );
        Function.apply(select, [segment.value]);
      }

      // 2026-10-08 口径：勾选列与「生成委外订货单」只属于「待处理」段——
      // 进行中/历史的行都已下单，没有可勾选的行，不摆永远灰着的批量按钮。
      for (final category in ['进行中', '历史记录']) {
        selectStage(category);
        await tester.pumpAndSettle();
        if (category == '历史记录') {
          // 2026-10-04 起历史门默认「全部」：直接进列表。
          await selectFilterSegment(tester, '全部');
          await tester.pumpAndSettle();
        }
        expect(action, findsNothing, reason: category);
        expect(
          find.byType(UtenSelectionSummaryPill),
          findsNothing,
          reason: category,
        );
        expect(find.byType(Checkbox), findsNothing, reason: category);
      }
      selectStage('待处理');
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
      // 2026-10-09 ADR-171 修订二：「待处理」是申请行 + 领料行的拍平表。
      expect(
        find.ancestor(
          of: action,
          matching: find.byKey(
            const Key('subcontract-decomposition-pending-table'),
          ),
        ),
        findsOneWidget,
      );
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
      // 2026-10-04 起历史门默认「全部」；2026-10-08 起历史段不再提供勾选与
      // 批量按钮。
      await selectFilterSegment(tester, '全部');
      await tester.pumpAndSettle();
      expect(action, findsNothing);
      expect(find.byType(UtenSelectionSummaryPill), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow-width task table selects issued application lines and enables one primary action',
    (tester) async {
      final gateway = _Gateway(_data(capability: true));
      _desktop(tester, const Size(375, 1400));
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: gateway,
              drawRepository: FakeSubcontractDrawGateway(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 2026-10-09 卡片形态退役：窄屏同一张表格（横向滚动）；
      // ADR-171 修订二：「待处理」是申请行 + 领料行的拍平表。
      expect(
        find.byKey(const Key('subcontract-decomposition-pending-table')),
        findsOneWidget,
      );
      // 进页面只拉一次 size=1 概览（阶段计数徽章），不带 status 过滤。
      // 2026-10-04 起红数「待处理」段进页面自动选中：概览 + 列表两次请求。
      expect(gateway.statuses, [null, 'WAITING_ORDER']);
      // 原「概览卡 + 阶段/异常下拉」已删除；占位态随自动选中消失。
      expect(find.text('在上方选择阶段后开始办理'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      // 2026-09-06 委外不再有「分解」行为用语：首段改名「待处理」。
      // 375px 分类栏放不下时收成「分类」下拉（2026-09-14）：段名在菜单里断言与点选；
      // ADR-098 三段合并后窄屏也放得下，此时段名直接是芯片。两种形态都要能过。
      final segmentMenu = find.byIcon(Icons.keyboard_arrow_down_rounded);
      if (segmentMenu.evaluate().isNotEmpty) {
        await tester.tap(segmentMenu);
        await tester.pumpAndSettle();
      }
      // 2026-10-04 起自动选中渲染了任务卡，卡内状态文字可能与段名同名——
      // 段存在即可，唯一定位交给下面的 .last tap。
      expect(find.text('待处理'), findsAtLeastNWidgets(1));
      var button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNull);

      // 再点已选中的「待处理」段（2026-10-04 起进页面自动选中）不重复发请求。
      await tester.tap(find.text('待处理').last);
      await tester.pumpAndSettle();
      expect(gateway.statuses, [null, 'WAITING_ORDER']);
      expect(find.text('计划申请已下达 / 待分解'), findsNWidgets(2));

      // 表头三态全选格在前：行勾选框从 at(1) 起。两击之间必须 pump——
      // 第二击的增量勾选读的是重建后的 selectedIds，连点会把第一击顶掉。
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pump();
      await tester.pumpAndSettle();

      button = tester.widget<UtenButton>(
        find.byKey(const Key('subcontract-decomposition-create-order')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.text('生成委外订货单(2)'), findsOneWidget);
      expect(find.text('已选 2 项'), findsOneWidget);
    },
  );

  testWidgets(
    'application row opens the summary dialog: big quantities, ownership and link; timeline retired',
    (tester) async {
      _desktop(tester, const Size(1600, 1200));
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: true, withSources: true)),
              drawRepository: FakeSubcontractDrawGateway(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      // 拍平表(ADR-171 修订二)：items 是申请行，领料行走 unpagedItems 渠道。
      final table = tester.widget<MasterDataTableView<SubcontractPendingRow>>(
        find.byKey(const Key('subcontract-decomposition-pending-table')),
      );
      final ready = table.items
          .whereType<SubcontractApplicationRow>()
          .firstWhere((row) => table.idOf!(row) != null);
      expect(table.idOf!(ready), 'task-1');
      // 整行底色已退役（2026-10-08 用户口径）：任何行都不再铺行底色。
      expect(table.rowColor, isNull);

      await _doubleTapRow(tester, find.text('FG-task-1'));
      await tester.pumpAndSettle();
      // 2026-10-08 改版：8 步流程时间线退役，弹窗只保留申请摘要。
      expect(find.text('生成委外订货单（当前）'), findsNothing);
      expect(find.text('计划已下达申请'), findsNothing);
      expect(find.text('结案核销'), findsNothing);
      // 可下单行没有锁定红框。
      expect(find.text('暂时不能下单'), findsNothing);
      // 关键数量与身份摘要（「待下单量」与表头同名，断言限定在弹窗内）。
      final dialog = find.byType(Dialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text('待下单量')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('这次可下单')),
        findsOneWidget,
      );
      expect(find.text('委外申请号 EA-application-1'), findsOneWidget);
      expect(find.text('需求日期 2026-09-10'), findsOneWidget);
      // 数量归属保留。
      expect(find.text('数量归属'), findsOneWidget);
      expect(find.text('ROOT-1 原产品一'), findsOneWidget);
      expect(find.text('销售订单 SO-1 · 第2行'), findsOneWidget);
      expect(find.text('公共备货'), findsOneWidget);
      expect(find.text('查看申请单'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
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
      permissions: _decomposePermissions,
      capability: false,
    ),
  ]) {
    testWidgets('${scenario.name} hides selection and keeps action disabled', (
      tester,
    ) async {
      _desktop(tester, const Size(900, 900));
      await tester.pumpWidget(
        _scope(
          permissions: scenario.permissions,
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: scenario.capability)),
              // 领料提交权单独授权(ADR-171 修订二)：这两个场景只验证下单侧的
              // 权限门，领料能力由专门的领料用例覆盖。
              drawRepository: FakeSubcontractDrawGateway(canSubmitDraw: false),
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

  group('ADR-143 缺 BOM 的委外申请行', () {
    testWidgets('red status with the R&D task number, no selection, '
        'clicking the status reminds R&D and reloads', (tester) async {
      _desktop(tester, const Size(1600, 1000));
      final gateway = _Gateway(_bomMissingData());
      final bom = _BomGapGateway();
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: gateway,
              drawRepository: FakeSubcontractDrawGateway(),
              bomGapGateway: bom,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();

      final table = tester.widget<MasterDataTableView<SubcontractPendingRow>>(
        find.byKey(const Key('subcontract-decomposition-pending-table')),
      );
      SubcontractApplicationRow applicationRow(String id) => table.items
          .whereType<SubcontractApplicationRow>()
          .firstWhere((row) => row.task.taskId == id);
      final missing = applicationRow('task-bom');
      // 不能勾选下单；锁死不能往下=深红（ADR-169「不能执行不是等待」，
      // 行底色已退役）。
      expect(table.idOf!(missing), isNull);
      expect(table.rowColor, isNull);
      final status = table.columns.firstWhere((c) => c.key == 'status');
      final context = tester.element(find.byType(SubcontractDecompositionPage));
      expect(
        status.cellColor!(context, missing),
        utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
      );
      expect(find.text('缺 BOM·已通知研发(RD0007)'), findsWidgets);
      // 勾选位锁图标悬浮说明为什么不能下单。
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(
        find.byTooltip('委外件还没有 BOM，已通知研发完善(RD0007)；研发保存 BOM 后自动恢复可下单'),
        findsOneWidget,
      );
      // 普通申请行不受影响。
      expect(table.idOf!(applicationRow('task-1')), 'task-1');

      final queries = gateway.queries.length;
      await tester.ensureVisible(find.byTooltip('点击通知研发完善 BOM'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('点击通知研发完善 BOM'));
      await tester.pumpAndSettle();
      expect(bom.forwarded, ['application-item-bom']);
      expect(gateway.queries.length, greaterThan(queries));
      expect(tester.takeException(), isNull);
    });

    testWidgets('server-named missing items are the only ones forwarded', (
      tester,
    ) async {
      _desktop(tester, const Size(1600, 1000));
      final grouped = OperationsWorkbenchTask.fromJson({
        'taskId': 'task-grouped',
        'planNo': 'PP-9',
        'supplyRoute': 'SUBCONTRACT',
        'taskStatus': 'WAITING_ORDER',
        'displayStage': 'BOM_MISSING',
        'canCreateOrder': false,
        'goodsCount': 2,
        'openLineCount': 2,
        'actionItemIds': ['item-a', 'item-b'],
        'bomMissingItemIds': ['item-b'],
        'actionDocType': 'SUBCONTRACT_APPLICATION',
        'actionDocId': 'application-9',
        'actionDocNo': 'EA-9',
        'actionDocCanView': true,
        'actionDocStatus': '1',
      }, OperationsWorkbenchDepartment.subcontract);
      expect(grouped.isBomMissing, isTrue);
      expect(grouped.rdTaskNo, isNull);
      final data = _bomMissingData();
      final bom = _BomGapGateway();
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(
                OperationsWorkbenchData(
                  department: data.department,
                  summary: data.summary,
                  items: [grouped],
                  page: 1,
                  size: 20,
                  total: 1,
                  totalPages: 1,
                  capabilities: data.capabilities,
                ),
              ),
              drawRepository: FakeSubcontractDrawGateway(),
              bomGapGateway: bom,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      // 没有未完成的研发任务时只显示「缺 BOM·已通知研发」。
      expect(find.text('缺 BOM·已通知研发'), findsWidgets);
      await tester.ensureVisible(find.byTooltip('点击通知研发完善 BOM'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('点击通知研发完善 BOM'));
      await tester.pumpAndSettle();
      expect(bom.forwarded, ['item-b']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('accounts that cannot decompose get no remind action', (
      tester,
    ) async {
      _desktop(tester, const Size(1600, 1000));
      final bom = _BomGapGateway();
      await tester.pumpWidget(
        _scope(
          permissions: const {Perm.subcontractApplicationView},
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_bomMissingData()),
              drawRepository: FakeSubcontractDrawGateway(),
              bomGapGateway: bom,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      expect(find.text('缺 BOM·已通知研发(RD0007)'), findsWidgets);
      expect(find.byTooltip('点击通知研发完善 BOM'), findsNothing);
      expect(bom.forwarded, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('ADR-156 直属物料齐套才解锁下单', () {
    const lockedHint = '直属物料还没齐，委外价格每天不同，物料齐了才解锁下单';

    testWidgets(
      'locked rows stay in pending (red count) but cannot be selected; '
      'partial rows show the orderable quantity',
      (tester) async {
        _desktop(tester, const Size(1700, 1000));
        final gateway = _Gateway(_kitData());
        await tester.pumpWidget(
          _scope(
            child: MaterialApp(
              home: SubcontractDecompositionPage(
                repository: gateway,
                drawRepository: FakeSubcontractDrawGateway(),
                kitGateway: _KitGateway(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 锁行照样留在「待处理」计红数：红数 3 = 三行全数，自动选中「待处理」。
        expect(gateway.queries.last['status'], 'WAITING_ORDER');
        final stages = find.byKey(
          const Key('subcontract-decomposition-stages'),
        );
        expect(
          find.descendant(of: stages, matching: find.text('3')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: stages,
            matching: find.byType(UtenInProgressBadge),
          ),
          findsNothing,
        );

        final table = tester.widget<MasterDataTableView<SubcontractPendingRow>>(
          find.byKey(const Key('subcontract-decomposition-pending-table')),
        );
        SubcontractApplicationRow applicationRow(String id) => table.items
            .whereType<SubcontractApplicationRow>()
            .firstWhere((row) => row.task.taskId == id);
        final locked = applicationRow('task-locked');
        final partial = applicationRow('task-partial');
        final ready = applicationRow('task-ready');
        // 锁行：不能勾选，深红状态格（锁死不能下单=红，ADR-169；
        // 整行红底已退役）；可下单=绿（就绪可动手）；可部分下单=紫。
        expect(table.idOf!(locked), isNull);
        expect(table.rowColor, isNull);
        expect(table.idOf!(partial), 'task-partial');
        expect(table.idOf!(ready), 'task-ready');
        final status = table.columns.firstWhere((c) => c.key == 'status');
        final context = tester.element(
          find.byType(SubcontractDecompositionPage),
        );
        expect(
          status.cellColor!(context, locked),
          utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
        );
        expect(
          status.cellColor!(context, partial),
          utenStatusBadgeCellColor(UtenStatusBadgeType.violet),
        );
        expect(
          status.cellColor!(context, ready),
          utenStatusBadgeCellColor(UtenStatusBadgeType.success),
        );
        expect(find.text('等物料齐套'), findsOneWidget);
        expect(find.text('可部分下单'), findsOneWidget);
        // 「可下单」列：服务端算好的数量；可部分下单带上剩余。
        final orderable = table.columns.firstWhere(
          (c) => c.key == 'orderableQty',
        );
        expect(orderable.label, '可下单');
        expect(orderable.value(partial), '4 / 剩余 6 件');
        expect(orderable.value(ready), '6 件');
        expect(orderable.value(locked), '0 件');
        expect(find.text('4 / 剩余 6 件'), findsOneWidget);
        // 锁行状态格悬浮说明为什么锁、点它看齐套情况。
        expect(find.byTooltip('$lockedHint；点击看齐套情况'), findsOneWidget);
        expect(find.byTooltip('点击看齐套情况'), findsNWidgets(2));
        // 拍平表(ADR-171 修订二)不做列头筛选：两类行的状态/单据语义不同，
        // 筛选交给阶段搜索框与领料定位芯片。

        // 可下单的两行能一起生成订货单。
        final action = find.byKey(
          const Key('subcontract-decomposition-create-order'),
        );
        expect(tester.widget<UtenButton>(action).onPressed, isNull);
        await tester.tap(find.text('FG-task-partial'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('FG-task-ready'));
        await tester.pumpAndSettle();
        expect(find.text('生成委外订货单(2)'), findsOneWidget);
        expect(tester.widget<UtenButton>(action).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'locked rows show a lock in the leading cell and the dialog explains why in red',
      (tester) async {
        _desktop(tester, const Size(1700, 1000));
        await tester.pumpWidget(
          _scope(
            child: MaterialApp(
              home: SubcontractDecompositionPage(
                repository: _Gateway(_kitData()),
                drawRepository: FakeSubcontractDrawGateway(),
                kitGateway: _KitGateway(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 勾选位：锁行换成锁图标(悬浮说明原因)，可下单两行仍是勾选框
        // (2 个行勾选 + 1 个表头全选)。
        expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
        expect(find.byTooltip(lockedHint), findsOneWidget);
        expect(find.byType(Checkbox), findsNWidgets(3));

        await _doubleTapRow(tester, find.text('FG-task-locked'));
        await tester.pumpAndSettle();
        // 锁行弹窗：顶部红框写明为什么锁住；流程时间线已退役。
        expect(find.text('暂时不能下单'), findsOneWidget);
        expect(find.text(lockedHint), findsOneWidget);
        expect(find.text('生成委外订货单（当前）'), findsNothing);
        final dialog = find.byType(Dialog);
        expect(
          find.descendant(
            of: dialog,
            matching: find.byIcon(Icons.lock_outline_rounded),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('clicking a status opens the kit dialog with every material', (
      tester,
    ) async {
      _desktop(tester, const Size(1700, 1000));
      final kit = _KitGateway();
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_kitData()),
              drawRepository: FakeSubcontractDrawGateway(),
              kitGateway: kit,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final lockedStatus = find.byTooltip('$lockedHint；点击看齐套情况');
      // 2026-10-06 状态列前置后状态格就在表左上角、天然可见——不要 ensureVisible：
      // 它会被 Tooltip 的 OverlayPortal 代理几何带偏，把横向滚动错误挪动、激活
      // 行首冻结勾选框副本盖住状态格，点击就落到勾选框上。
      await tester.tap(lockedStatus);
      await tester.pumpAndSettle();

      expect(kit.calls, ['application-item-locked']);
      expect(find.byKey(const Key('subcontract-kit-dialog')), findsOneWidget);
      expect(find.text('齐套情况 · EA-application-locked'), findsOneWidget);
      expect(find.text('委外件 FG-locked 委外件L 本色'), findsOneWidget);
      expect(find.text('可下单 0(等物料齐套)', findRichText: true), findsOneWidget);
      final materials = tester
          .widget<MasterDataTableView<SubcontractKitMaterial>>(
            find.byKey(
              const ValueKey(
                'subcontract-kit-materials-application-item-locked',
              ),
            ),
          );
      expect(materials.columns.map((column) => column.label).toList(), [
        '物料名称',
        '编号',
        '颜色',
        '单位',
        '每套用量',
        '需要',
        '专属库存',
        '已被占用',
        '现在能用',
        '还缺',
        '够做套数',
      ]);
      String cell(String key, SubcontractKitMaterial row) =>
          materials.columns.firstWhere((c) => c.key == key).value(row)!;
      final shell = materials.items.first;
      expect(cell('goodsName', shell), '外壳');
      expect(cell('bomUnitQty', shell), '2');
      expect(cell('neededQty', shell), '12');
      expect(cell('exactQty', shell), '3');
      // 已被占用 = 专属被本申请已有委外单占用 + 公共被别的委外单占用。
      expect(cell('claimedQty', shell), '2.5');
      expect(cell('freeQty', shell), '1.5');
      expect(cell('shortQty', shell), '10.5');
      expect(cell('kitQty', shell), '0');
      expect(find.text('外壳'), findsOneWidget);
      expect(find.text('螺丝'), findsOneWidget);

      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('subcontract-kit-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('kit dialog loads every application item of a grouped row', (
      tester,
    ) async {
      _desktop(tester, const Size(1400, 1000));
      final kit = _KitGateway();
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showSubcontractApplicationKitDialog(
                    context,
                    gateway: kit,
                    applicationItemIds: const [
                      'application-item-partial',
                      'application-item-locked',
                    ],
                    title: 'EA-9',
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(kit.calls, [
        'application-item-partial',
        'application-item-locked',
      ]);
      expect(find.text('齐套情况 · EA-9'), findsOneWidget);
      expect(find.text('可下单 4 件(可部分下单)', findRichText: true), findsOneWidget);
      expect(find.text('可下单 0(等物料齐套)', findRichText: true), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('subcontract-kit-materials-application-item-partial'),
        ),
        findsOneWidget,
      );

      // 读取失败：显示服务端原话并可重试。
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      kit.error = ApiException('NOT_FOUND', '委外申请明细不存在', httpStatus: 404);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('委外申请明细不存在'), findsOneWidget);
      kit.error = null;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('可下单 4 件(可部分下单)', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('375 宽同一张表格：锁行图标与说明保留', (tester) async {
      _desktop(tester, const Size(375, 1400));
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_kitData()),
              drawRepository: FakeSubcontractDrawGateway(),
              kitGateway: _KitGateway(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '375 宽不溢出');
      // 2026-10-09 卡片形态退役：窄屏同一张表格。齐套判定改看桌面孪生用例，
      // 这里锁窄屏不丢的 affordance——表头三态全选 + 两条可下单行勾选框；
      // 锁行勾选位换锁图标，悬浮说明为什么不能下单（ADR-156）。
      expect(find.byType(Checkbox), findsNWidgets(3));
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(find.byTooltip(lockedHint), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'kit-ready notice deep link lands on pending with the keyword',
      (tester) async {
        _desktop(tester, const Size(1700, 1000));
        final gateway = _Gateway(_kitData());
        final route = ValueNotifier<(String?, String?)>((
          'pending',
          ' EA-application-partial ',
        ));
        addTearDown(route.dispose);
        await tester.pumpWidget(
          _scope(
            child: MaterialApp(
              home: ValueListenableBuilder<(String?, String?)>(
                valueListenable: route,
                builder: (_, value, _) => SubcontractDecompositionPage(
                  repository: gateway,
                  drawRepository: FakeSubcontractDrawGateway(),
                  kitGateway: _KitGateway(),
                  initialSegment: value.$1,
                  initialKeyword: value.$2,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 直落「待处理」：第一次请求就按申请号拉列表，不再先拉概览。
        expect(gateway.queries, hasLength(1));
        expect(gateway.queries.single['status'], 'WAITING_ORDER');
        expect(gateway.queries.single['keyword'], 'EA-application-partial');
        expect(gateway.queries.single['size'], 50);
        expect(
          find.widgetWithText(TextField, 'EA-application-partial'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('subcontract-decomposition-pending-table')),
          findsOneWidget,
        );

        // 已在任务中心时再点另一张通知：换申请号重拉。
        route.value = ('pending', 'EA-application-locked');
        await tester.pumpAndSettle();
        expect(gateway.queries.last['status'], 'WAITING_ORDER');
        expect(gateway.queries.last['keyword'], 'EA-application-locked');
        expect(
          find.widgetWithText(TextField, 'EA-application-locked'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    test('pending segment deep link keeps the application number', () {
      final link = RouteName.operationsSubcontractPendingSegment(
        keyword: ' EB-2026 001 ',
      );
      final uri = Uri.parse(link);
      expect(uri.path, RouteName.operationsSubcontractWorkbench);
      expect(uri.queryParameters, {
        'segment': 'pending',
        'keyword': 'EB-2026 001',
      });
      expect(
        RouteName.operationsSubcontractPendingSegment(),
        '${RouteName.operationsSubcontractWorkbench}?segment=pending',
      );
      // 服务端按 URLEncoder 编码申请号(空格 = +)，路由照样还原。
      expect(
        Uri.parse(
          '/operations/workbench/subcontract?segment=pending&keyword=EB-2026+001',
        ).queryParameters['keyword'],
        'EB-2026 001',
      );
    });

    test('workbench rows parse orderable quantity and kit stages', () {
      OperationsWorkbenchTask parse(Map<String, dynamic> extra) =>
          OperationsWorkbenchTask.fromJson({
            'taskId': 't',
            'supplyRoute': 'SUBCONTRACT',
            'taskStatus': 'WAITING_ORDER',
            ...extra,
          }, OperationsWorkbenchDepartment.subcontract);
      final locked = parse({
        'displayStage': 'WAITING_KIT',
        'orderableQty': 0,
        'canCreateOrder': false,
      });
      expect(locked.isWaitingKit, isTrue);
      expect(locked.orderableQty, 0);
      final partial = parse({
        'displayStage': 'KIT_PARTIAL',
        'orderableQty': '2.5',
      });
      expect(partial.isKitPartial, isTrue);
      expect(partial.orderableQty, 2.5);
      // 非申请行服务端下发 null。
      expect(parse({'orderableQty': null}).orderableQty, isNull);
    });
  });

  group('ADR-143/ADR-171 领料(待处理拍平表)', () {
    testWidgets(
      'red+yellow counts, status cells, gated selection and batch draw',
      (tester) async {
        _desktop(tester, const Size(1700, 1000));
        final draw = FakeSubcontractDrawGateway(
          count: 7,
          submittedCount: 1,
          statusCounts: const {
            'DRAWABLE': 2,
            'DRAW_SUBMITTED': 1,
            'WAITING_PLANNING': 1,
            'WAITING_MATERIAL': 1,
            'ALL': 5,
          },
          rows: [
            drawRow('item-full', drawableQty: 60, shortQty: 40),
            drawRow(
              'item-partial',
              status: 'DRAWABLE_PARTIAL',
              orderBillNo: 'WD-002',
              goodsName: '委外件B',
              drawableQty: 20,
              pendingQty: 10,
            ),
            drawRow(
              'item-submitted',
              status: 'DRAW_SUBMITTED',
              orderBillNo: 'WD-003',
              drawableQty: 0,
              pendingQty: 30,
              canDraw: false,
            ),
            drawRow(
              'item-planning',
              status: 'WAITING_PLANNING',
              orderBillNo: 'WD-004',
              drawableQty: 0,
              unplannedShortKindCount: 2,
              canDraw: false,
            ),
            drawRow(
              'item-waiting',
              status: 'WAITING_MATERIAL',
              orderBillNo: 'WD-005',
              drawableQty: 0,
              materialKindCount: 3,
              canDraw: false,
            ),
          ],
        );
        final opened = <List<String>>[];
        final gateway = _Gateway(_data(capability: true));
        final router = _router(
          page: SubcontractDecompositionPage(
            repository: gateway,
            drawRepository: draw,
          ),
          opened: opened,
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          _scope(child: MaterialApp.router(routerConfig: router)),
        );
        await tester.pumpAndSettle();

        // ADR-171 修订二拍平：「待处理」红 = 申请(2)+可领(7)=9，黄 = 领料中(1)；
        // 「进行中」黄 = 3。两段各自挂红黄，同一张表里红行=可动手、黄行=在跑。
        final stages = find.byKey(
          const Key('subcontract-decomposition-stages'),
        );
        expect(
          find.descendant(of: stages, matching: find.text('9')),
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
          find.descendant(
            of: stages,
            matching: find.byType(UtenInProgressBadge),
          ),
          findsNWidgets(2),
        );
        // 子分类行已退役：领料只是「待处理」拍平表里的一种状态。
        expect(
          find.byKey(const Key('subcontract-decomposition-pending-categories')),
          findsNothing,
        );

        // 进页面自动选中「待处理」：领料行随申请列表一起拉(不分页、无状态过滤)。
        expect(draw.listQueries, hasLength(1));
        expect(draw.listQueries.single['status'], isNull);

        final table = tester.widget<MasterDataTableView<SubcontractPendingRow>>(
          find.byKey(const Key('subcontract-decomposition-pending-table')),
        );
        // 领料行钉在表格顶部(unpagedItems)；服务端 canDraw 且账号 canSubmitDraw
        // 的行才可勾选，id 带领料前缀与申请行命名空间分开。
        expect(table.unpagedItems.map((row) => table.idOf!(row)).toList(), [
          'draw-item-full',
          'draw-item-partial',
          null,
          null,
          null,
        ]);
        // 不可领的三行(已提交/等计划/等物料)勾选位换锁图标，悬浮说明下一步
        // 由谁动手；状态格悬浮同句(两处都在)。
        expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(3));
        expect(find.byTooltip('已提交 30 个 的领料，等仓库发出'), findsNWidgets(2));
        // 状态列文案 + ADR-169 十档整格底色(绿 / 紫 / 青 / 红 / 红——
        // 等计划安排与等待物料都是「不能领」，同红靠文案区分)。
        expect(find.text('可领 60 个·去领料'), findsOneWidget);
        expect(find.text('可领 20 个·去领料'), findsOneWidget);
        expect(find.text('已提交领料·待仓库发料'), findsOneWidget);
        expect(find.text('等计划安排·缺 2 种'), findsOneWidget);
        expect(find.text('等待物料·已备 1/3 种'), findsOneWidget);
        final status = table.columns.firstWhere((c) => c.key == 'status');
        final context = tester.element(
          find.byType(SubcontractDecompositionPage),
        );
        final colors = [
          for (final row in table.unpagedItems) status.cellColor!(context, row),
        ];
        expect(colors, [
          // 可领=绿(就绪可动手) / 部分可领=紫 / 待仓库发料=青(等仓库)。
          utenStatusBadgeCellColor(UtenStatusBadgeType.success),
          utenStatusBadgeCellColor(UtenStatusBadgeType.violet),
          utenStatusBadgeCellColor(UtenStatusBadgeType.sky),
          // 等计划安排(没有在途供应)与等待物料(料没到)都不能领=红。
          utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
          utenStatusBadgeCellColor(UtenStatusBadgeType.danger),
        ]);
        // 可领与待仓库发同时存在时悬浮提示两者。
        expect(
          find.byTooltip('可领 20 个；另有 10 个已提交领料，等仓库发料；其余还缺物料，到货后可继续领'),
          findsOneWidget,
        );
        // 已领 / 待仓库发 / 可领 / 还缺 与货品身份三列(与申请行的数量列并存)。
        for (final label in [
          '已领',
          '待仓库发',
          '可领',
          '还缺',
          '委外件名称',
          '编号',
          '颜色',
          '需求量',
          '待下单量',
          '可下单',
        ]) {
          expect(
            table.columns.where((column) => column.label == label),
            hasLength(1),
            reason: label,
          );
        }

        final batch = find.byKey(const Key('subcontract-draw-batch'));
        expect(batch, findsOneWidget);
        expect(tester.widget<UtenButton>(batch).onPressed, isNull);
        await tester.tap(find.text('WD-002'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('WD-001'));
        await tester.pumpAndSettle();
        expect(find.text('批量领料(2)'), findsOneWidget);
        await tester.tap(batch);
        await tester.pumpAndSettle();
        expect(opened, [
          ['item-full', 'item-partial'],
        ]);
        // 领料页带 true 返回：仍在「待处理」拍平表，清掉已领勾选并重拉。
        router.pop(true);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('subcontract-decomposition-pending-table')),
          findsOneWidget,
        );
        expect(find.text('批量领料(0)'), findsOneWidget);
        expect(gateway.queries.last['status'], 'WAITING_ORDER');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'clicking a drawable status opens the draw page for that row only',
      (tester) async {
        _desktop(tester, const Size(1700, 1000));
        final draw = FakeSubcontractDrawGateway(
          count: 1,
          rows: [
            drawRow('item-1'),
            drawRow('item-2', orderBillNo: 'WD-002'),
          ],
        );
        final opened = <List<String>>[];
        final router = _router(
          page: SubcontractDecompositionPage(
            repository: _Gateway(_data(capability: true)),
            drawRepository: draw,
            initialSegment: 'draw',
          ),
          opened: opened,
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          _scope(child: MaterialApp.router(routerConfig: router)),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('subcontract-draw-go-item-2')),
        );
        await tester.pumpAndSettle();
        expect(opened, [
          ['item-2'],
        ]);
        // 返回后重拉列表与红数。
        final lists = draw.listQueries.length;
        final counts = draw.countCalls;
        router.pop(true);
        await tester.pumpAndSettle();
        expect(draw.listQueries.length, greaterThan(lists));
        expect(draw.countCalls, greaterThan(counts));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'accounts without draw capability see rows but cannot select or draw',
      (tester) async {
        _desktop(tester, const Size(1700, 1000));
        final draw = FakeSubcontractDrawGateway(
          canSubmitDraw: false,
          rows: [drawRow('item-1')],
        );
        await tester.pumpWidget(
          _scope(
            permissions: const {Perm.subcontractOrderView},
            child: MaterialApp(
              home: SubcontractDecompositionPage(
                repository: _Gateway(_data(capability: false)),
                drawRepository: draw,
                initialSegment: 'draw',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<SubcontractPendingRow>>(
          find.byKey(const Key('subcontract-decomposition-pending-table')),
        );
        // 账号没有提交领料权限：领料行可见但不可勾选(申请行勾选由下单能力
        // 另行门控)，悬浮批量按钮只剩「生成委外订货单」。
        expect(table.selectable, isFalse);
        expect(table.idOf!(table.unpagedItems.single), isNull);
        expect(find.byKey(const Key('subcontract-draw-batch')), findsNothing);
        // 只显示可领量，不出现「去领料」入口。
        expect(find.text('可领 40 个'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('subcontract-draw-go-item-1')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'task detail shows the material table and server-gated actions',
      (tester) async {
        _desktop(tester, const Size(1700, 1100));
        final draw = FakeSubcontractDrawGateway(
          count: 1,
          rows: [drawRow('item-1')],
        );
        draw.details['item-1'] = _detail(
          'item-1',
          actions: const ['WITHDRAW', 'CLOSE'],
        );
        await tester.pumpWidget(
          _scope(
            child: MaterialApp(
              home: SubcontractDecompositionPage(
                repository: _Gateway(_data(capability: true)),
                drawRepository: draw,
                initialSegment: 'draw',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _doubleTapRow(tester, find.text('WD-001'));
        await tester.pumpAndSettle();
        expect(draw.detailCalls, ['item-1']);
        final materials = tester
            .widget<MasterDataTableView<SubcontractDrawMaterial>>(
              find.byKey(const Key('subcontract-draw-detail-materials')),
            );
        // 2026-10-06 全站口径：状态列排最前。
        expect(materials.columns.map((column) => column.label).toList(), [
          '状态',
          '物料名称',
          '编号',
          '颜色',
          '单位',
          '每套用量',
          '需求',
          '已发外',
          '待仓库发',
          '仓库可用',
          '本次可领',
          '还缺',
          '供应来源',
        ]);
        expect(find.text('采购在途 50(PO-9)'), findsOneWidget);
        expect(find.text('未安排'), findsOneWidget);
        expect(find.text('缺料'), findsWidgets);
        expect(find.text('已备'), findsOneWidget);
        expect(find.textContaining('WF-1'), findsOneWidget);

        // 撤回未发领料：确认后调服务端并刷新列表。
        final listsBefore = draw.listQueries.length;
        await tester.tap(
          find.byKey(const Key('subcontract-draw-detail-withdraw')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('撤回').last);
        await tester.pumpAndSettle();
        expect(draw.withdrawn, [
          ['item-1'],
        ]);
        expect(draw.listQueries.length, greaterThan(listsBefore));

        // 结束领料：原因必填。
        await tester.tap(
          find.byKey(const Key('subcontract-draw-detail-close-draw')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('subcontract-draw-close-confirm')),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('请填写结束领料的原因'), findsOneWidget);
        expect(draw.closed, isEmpty);
        await tester.enterText(
          find.byKey(const Key('subcontract-draw-close-reason')),
          '委外商做不完',
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('subcontract-draw-close-confirm')),
        );
        await tester.pumpAndSettle();
        expect(draw.closed, [('item-1', '委外商做不完')]);
        expect(
          find.byKey(const Key('subcontract-draw-detail-materials')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'warehouse-edited draft is marked and withdraw stays hidden unless allowed',
      (tester) async {
        _desktop(tester, const Size(1700, 1100));
        final draw = FakeSubcontractDrawGateway(rows: [drawRow('item-1')]);
        // 服务端：唯一的待发领料单仓库已改过 → allowedActions 不含 WITHDRAW。
        draw.details['item-1'] = _detail(
          'item-1',
          actions: const ['CLOSE'],
          edited: true,
        );
        await tester.pumpWidget(
          _scope(
            child: MaterialApp(
              home: SubcontractDecompositionPage(
                repository: _Gateway(_data(capability: true)),
                drawRepository: draw,
                initialSegment: 'draw',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _doubleTapRow(tester, find.text('WD-001'));
        await tester.pumpAndSettle();
        expect(find.textContaining('仓库已改过'), findsWidgets);
        expect(
          find.byKey(const Key('subcontract-draw-detail-edited-hint')),
          findsOneWidget,
        );
        expect(find.textContaining('退回委外(不发)'), findsOneWidget);
        expect(
          find.byKey(const Key('subcontract-draw-detail-withdraw')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('subcontract-draw-detail-close-draw')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('detail without allowed actions shows no withdraw or close', (
      tester,
    ) async {
      _desktop(tester, const Size(1700, 1100));
      final draw = FakeSubcontractDrawGateway(
        canSubmitDraw: false,
        rows: [drawRow('item-1')],
      );
      draw.details['item-1'] = _detail('item-1', actions: const []);
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: true)),
              drawRepository: draw,
              initialSegment: 'draw',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _doubleTapRow(tester, find.text('WD-001'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('subcontract-draw-detail-withdraw')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('subcontract-draw-detail-close-draw')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('subcontract-draw-detail-go-draw')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'in-progress drawable status jumps to pending with the order scope',
      (tester) async {
        _desktop(tester, const Size(1700, 1000));
        final draw = FakeSubcontractDrawGateway(rows: [drawRow('item-1')]);
        await tester.pumpWidget(
          _scope(
            child: MaterialApp(
              home: SubcontractDecompositionPage(
                repository: _Gateway(_data(capability: true), inProgress: true),
                drawRepository: draw,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('进行中'));
        await tester.pumpAndSettle();
        expect(find.text('可领料·去领料'), findsWidgets);
        expect(find.text('已提交领料·待仓库发料'), findsWidgets);
        expect(find.text('委外加工中'), findsWidgets);
        expect(find.byTooltip('点击去领料'), findsOneWidget);
        // 状态列前置后首行状态格天然可见；ensureVisible 对 Tooltip(OverlayPortal
        // 代理几何)会错误横滚、激活行首冻结勾选框副本挡住点击，勿加。
        await tester.tap(find.byTooltip('点击去领料'));
        await tester.pumpAndSettle();
        expect(draw.listQueries.last['orderId'], 'order-drawable');
        expect(
          find.byKey(const Key('subcontract-decomposition-pending-table')),
          findsOneWidget,
        );
        expect(find.text('领料行只看订货单 EO-order-drawable 的委外任务'), findsOneWidget);
        // 清除定位 → 看全部委外任务。
        await tester.tap(find.byTooltip('看全部委外任务'));
        await tester.pumpAndSettle();
        expect(draw.listQueries.last['orderId'], isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('notice deep link lands on pending with the task scope', (
      tester,
    ) async {
      _desktop(tester, const Size(1700, 1000));
      final draw = FakeSubcontractDrawGateway(rows: [drawRow('item-9')]);
      await tester.pumpWidget(
        _scope(
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: true)),
              drawRepository: draw,
              initialSegment: 'draw',
              initialOrderItemId: 'item-9',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(draw.listQueries.single['orderItemIds'], ['item-9']);
      expect(find.text('领料行只看通知里的这条委外任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('server refusal of the draw count hides the draw rows', (
      tester,
    ) async {
      _desktop(tester, const Size(1600, 1000));
      final draw = FakeSubcontractDrawGateway()
        ..countError = ApiException('FORBIDDEN', '无权限访问', httpStatus: 403);
      await tester.pumpWidget(
        _scope(
          permissions: const {Perm.subcontractApplicationView},
          child: MaterialApp(
            home: SubcontractDecompositionPage(
              repository: _Gateway(_data(capability: true)),
              drawRepository: draw,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('待处理'), findsOneWidget);
      // 领料行整体静默隐藏：拍平表只剩申请行，待处理段不挂黄数，不向用户报错。
      expect(
        find.byKey(const Key('subcontract-decomposition-pending-table')),
        findsOneWidget,
      );
      expect(find.text('委外订货单号'), findsNothing);
      expect(find.text('委外任务加载失败'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'draw count refusal while deep-linked to draw falls back to applications',
      (tester) async {
        _desktop(tester, const Size(1600, 1000));
        final draw = FakeSubcontractDrawGateway(rows: [drawRow('item-1')])
          ..countError = ApiException('FORBIDDEN', '无权限访问', httpStatus: 403);
        final gateway = _Gateway(_data(capability: true));
        await tester.pumpWidget(
          _scope(
            child: MaterialApp(
              home: SubcontractDecompositionPage(
                repository: gateway,
                drawRepository: draw,
                initialSegment: 'draw',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 深链落「待处理」后计数被 403：领料行整体静默隐藏，申请行照常，
        // 定位芯片也不出现。
        expect(
          find.byKey(const Key('subcontract-decomposition-pending-table')),
          findsOneWidget,
        );
        expect(find.text('委外订货单号'), findsNothing);
        expect(find.text('领料行只看'), findsNothing);
        expect(gateway.statuses, contains('WAITING_ORDER'));
        expect(tester.takeException(), isNull);
      },
    );
  });
}

void _desktop(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _scope({
  required Widget child,
  Set<String> permissions = _decomposePermissions,
}) => ProviderScope(
  overrides: [
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
    apiClientProvider.overrideWithValue(_api()),
  ],
  child: child,
);

GoRouter _router({required Widget page, required List<List<String>> opened}) =>
    GoRouter(
      initialLocation: RouteName.operationsSubcontractWorkbench,
      routes: [
        GoRoute(
          path: RouteName.operationsSubcontractWorkbench,
          builder: (_, _) => page,
        ),
        GoRoute(
          path: RouteName.operationsSubcontractDrawRequest,
          builder: (_, state) {
            opened.add(
              state.uri.queryParameters['orderItemIds']!.split(',').toList(),
            );
            return const Scaffold(body: Text('领料页已打开'));
          },
        ),
      ],
    );

/// 双击指定行（两次点按间隔 50ms，落在 350ms 手动双击判定窗内）。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

/// 其余请求(徽章、草稿计数等)一律回空。
ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: <String, dynamic>{},
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

class _Gateway implements OperationsWorkbenchGateway {
  _Gateway(this.data, {this.inProgress = false});
  OperationsWorkbenchData data;
  final bool inProgress;
  Future<OperationsWorkbenchData> Function()? response;
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
      'size': size,
      'keyword': keyword,
      'sort': sort,
      'order': order,
      'status': status,
      'filters': Map<String, String?>.from(columnFilters),
    });
    if (inProgress && status == 'IN_PROGRESS') return _inProgressData();
    return response == null ? data : await response!();
  }
}

Map<String, dynamic> _sourceJson(int? product, num qty) => {
  'analysisItemId': product == null ? null : 'origin-$product',
  'sourceType': product == null ? 'PUBLIC_STOCK' : 'SALES_ORDER_ITEM',
  'sourceNo': product == null ? '' : 'SO-$product',
  'sourceLineNo': product == null ? null : product + 1,
  'productCode': product == null ? '' : 'ROOT-$product',
  'productName': product == null ? '' : '原产品${product == 1 ? '一' : '二'}',
  'materialCode': 'SC-A',
  'materialName': '委外件A',
  'quantity': qty,
  'unitName': '件',
};

OperationsWorkbenchData _data({
  required bool capability,
  bool withSources = false,
  bool onlyFirst = false,
}) => OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.subcontract,
  summary: const OperationsWorkbenchSummary(
    totalTasks: 2,
    overdueTasks: 0,
    openTasks: 2,
    openQty: 12,
    statusCounts: {'WAITING_ORDER': 2, 'IN_PROGRESS': 3},
  ),
  items: [
    _task(
      'task-1',
      'application-1',
      'application-item-1',
      sources: withSources
          ? SubcontractTaskSource.listFromJson([
              _sourceJson(1, 3),
              _sourceJson(2, 5),
              _sourceJson(null, 2),
            ])
          : const [],
    ),
    if (!onlyFirst) _task('task-2', 'application-2', 'application-item-2'),
  ],
  page: 1,
  size: 20,
  total: onlyFirst ? 1 : 2,
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

OperationsWorkbenchData _inProgressData() => OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.subcontract,
  summary: const OperationsWorkbenchSummary(
    totalTasks: 3,
    overdueTasks: 0,
    openTasks: 3,
    openQty: 30,
    statusCounts: {'IN_PROGRESS': 3},
  ),
  items: [
    _order('order-drawable', 'DRAWABLE'),
    _order('order-submitted', 'DRAW_SUBMITTED'),
    _order('order-supplier', 'AT_SUPPLIER'),
  ],
  page: 1,
  size: 50,
  total: 3,
  totalPages: 1,
  capabilities: const OperationsWorkbenchCapabilities(
    canCreateSubcontractOrder: true,
  ),
);

OperationsWorkbenchTask _order(String id, String displayStage) =>
    OperationsWorkbenchTask.fromJson({
      'taskId': id,
      'planNo': 'PP-$id',
      'supplyRoute': 'SUBCONTRACT',
      'goodsCode': 'FG-$id',
      'goodsName': '委外件 $id',
      'requiredQty': 10,
      'openQty': 4,
      'taskStatus': 'FINANCE_APPROVED',
      'displayStage': displayStage,
      'actionDocType': 'SUBCONTRACT_ORDER',
      'actionDocId': id,
      'actionDocNo': 'EO-$id',
      'actionDocCanView': true,
      'actionDocCanEdit': false,
      'actionDocStatus': '1',
    }, OperationsWorkbenchDepartment.subcontract);

/// 待处理段：一条可下单的申请行 + 一条委外件缺 BOM 的申请行(ADR-143 §二.3)。
OperationsWorkbenchData _bomMissingData() => OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.subcontract,
  summary: const OperationsWorkbenchSummary(
    totalTasks: 2,
    overdueTasks: 0,
    openTasks: 2,
    openQty: 12,
    statusCounts: {'WAITING_ORDER': 2},
  ),
  items: [
    _task('task-1', 'application-1', 'application-item-1'),
    _task(
      'task-bom',
      'application-bom',
      'application-item-bom',
      canCreateOrder: false,
      displayStage: 'BOM_MISSING',
      rdTaskNo: 'RD0007',
    ),
  ],
  page: 1,
  size: 20,
  total: 2,
  totalPages: 1,
  capabilities: const OperationsWorkbenchCapabilities(
    canCreateSubcontractOrder: true,
  ),
);

/// 待处理段(ADR-156)：一条物料全齐(可下单 6)、一条只够做 4 套(可部分下单)、
/// 一条一套都不够(等物料齐套，锁住)。三条都计入「待处理」红数。
OperationsWorkbenchData _kitData() => OperationsWorkbenchData(
  department: OperationsWorkbenchDepartment.subcontract,
  summary: const OperationsWorkbenchSummary(
    totalTasks: 3,
    overdueTasks: 0,
    openTasks: 3,
    openQty: 18,
    statusCounts: {'WAITING_ORDER': 3},
  ),
  items: [
    _task(
      'task-ready',
      'application-ready',
      'application-item-ready',
      orderableQty: 6,
    ),
    _task(
      'task-partial',
      'application-partial',
      'application-item-partial',
      displayStage: 'KIT_PARTIAL',
      orderableQty: 4,
    ),
    _task(
      'task-locked',
      'application-locked',
      'application-item-locked',
      canCreateOrder: false,
      displayStage: 'WAITING_KIT',
      orderableQty: 0,
    ),
  ],
  page: 1,
  size: 50,
  total: 3,
  totalPages: 1,
  capabilities: const OperationsWorkbenchCapabilities(
    canCreateSubcontractOrder: true,
  ),
  facets: const {
    'status': [
      MasterFacetBucket(
        value: 'WAITING_ORDER',
        label: 'WAITING_ORDER',
        count: 1,
      ),
      MasterFacetBucket(value: 'KIT_PARTIAL', label: 'KIT_PARTIAL', count: 1),
      MasterFacetBucket(value: 'WAITING_KIT', label: 'WAITING_KIT', count: 1),
    ],
  },
);

/// 齐套情况假数据：partial 够做 4 套(剩余 6)，locked 一套都不够(外壳只剩 1.5 能用)。
class _KitGateway implements SubcontractKitGateway {
  final List<String> calls = [];
  ApiException? error;

  @override
  Future<SubcontractApplicationKit> applicationKit(
    String applicationItemId,
  ) async {
    calls.add(applicationItemId);
    final failure = error;
    if (failure != null) throw failure;
    final locked = applicationItemId == 'application-item-locked';
    return SubcontractApplicationKit.fromJson({
      'applicationItemId': applicationItemId,
      'applicationId': locked ? 'application-locked' : 'application-partial',
      'applicationNo': locked ? 'EA-application-locked' : 'EA-application-9',
      'goodsId': 'goods-$applicationItemId',
      'goodsCode': locked ? 'FG-locked' : 'FG-partial',
      'goodsName': locked ? '委外件L' : '委外件P',
      'colorName': '本色',
      'unitName': '件',
      'openQty': 6,
      'kitQty': locked ? 0 : 4,
      'orderableQty': locked ? 0 : 4,
      'bomMissing': false,
      'materials': [
        {
          'goodsId': 'm-shell',
          'goodsCode': 'M-SHELL',
          'goodsName': '外壳',
          'colorId': null,
          'colorName': '黑',
          'unitName': '个',
          'bomUnitQty': 2,
          'neededQty': 12,
          'exactQty': 3,
          'exactClaimedQty': 2,
          'exactFreeQty': 1,
          'publicQty': 1,
          'publicClaimedQty': 0.5,
          'publicFreeQty': 0.5,
          'freeQty': locked ? 1.5 : 8,
          'shortQty': locked ? 10.5 : 4,
          'kitQty': locked ? 0 : 4,
        },
        {
          'goodsId': 'm-screw',
          'goodsCode': 'M-SCREW',
          'goodsName': '螺丝',
          'colorName': '',
          'unitName': '个',
          'bomUnitQty': 4,
          'neededQty': 24,
          'exactQty': 0,
          'exactClaimedQty': 0,
          'exactFreeQty': 0,
          'publicQty': 100,
          'publicClaimedQty': 0,
          'publicFreeQty': 100,
          'freeQty': 100,
          'shortQty': 0,
          'kitQty': 25,
        },
      ],
    });
  }
}

class _BomGapGateway implements SubcontractBomGapGateway {
  final List<String> forwarded = [];

  @override
  Future<SubcontractBomForwardResult> forwardBom(
    String applicationItemId,
  ) async {
    forwarded.add(applicationItemId);
    return const SubcontractBomForwardResult(taskNo: 'RD0007');
  }
}

OperationsWorkbenchTask _task(
  String taskId,
  String applicationId,
  String applicationItemId, {
  bool? canCreateOrder = true,
  List<SubcontractTaskSource> sources = const [],
  String? displayStage,
  String? rdTaskNo,
  num? orderableQty,
}) => OperationsWorkbenchTask(
  displayStage: displayStage,
  rdTaskNo: rdTaskNo,
  orderableQty: orderableQty,
  taskId: taskId,
  packageId: 'package-1',
  planId: 'plan-1',
  planNo: 'PP-001',
  warehouseName: '委外仓',
  goodsCode: 'FG-$taskId',
  goodsName: '委外件',
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
  sources: sources,
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

SubcontractDrawTaskDetail _detail(
  String orderItemId, {
  required List<String> actions,
  bool edited = false,
}) => SubcontractDrawTaskDetail.fromJson(<String, dynamic>{
  'task': drawRowJson(drawRow(orderItemId)),
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{
      'planItemId': 'plan-a',
      'lineNo': 1,
      'goodsId': 'material-a',
      'goodsCode': 'M-A',
      'goodsName': '物料A',
      'colorName': '本色',
      'unitName': 'kg',
      'perUnitQty': 2,
      'requiredQty': 200,
      'sentQty': 0,
      'pendingQty': 0,
      'availableQty': 80,
      'drawableQty': 80,
      'shortQty': 120,
      'state': 'SHORT',
      'supplySources': <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': 'PURCHASE',
          'docId': 'po-9',
          'docNo': 'PO-9',
          'openQty': 50,
        },
      ],
    },
    <String, dynamic>{
      'planItemId': 'plan-b',
      'lineNo': 2,
      'goodsId': 'material-b',
      'goodsCode': 'M-B',
      'goodsName': '物料B',
      'colorName': '黑',
      'unitName': '个',
      'perUnitQty': 1,
      'requiredQty': 100,
      'sentQty': 0,
      'pendingQty': 0,
      'availableQty': 40,
      'drawableQty': 40,
      'shortQty': 60,
      'state': 'SHORT',
      'supplySources': <Map<String, dynamic>>[],
    },
    // 物料本身已齐，但被物料A/B卡住本批可领为 0：读「已备」(ADR-143 §三.4)。
    <String, dynamic>{
      'planItemId': 'plan-c',
      'lineNo': 3,
      'goodsId': 'material-c',
      'goodsCode': 'M-C',
      'goodsName': '物料C',
      'colorName': '本色',
      'unitName': '个',
      'perUnitQty': 1,
      'requiredQty': 100,
      'sentQty': 0,
      'pendingQty': 0,
      'availableQty': 100,
      'drawableQty': 0,
      'shortQty': 0,
      'state': 'DRAWABLE',
      'supplySources': <Map<String, dynamic>>[],
    },
  ],
  'pendingDrafts': <Map<String, dynamic>>[
    <String, dynamic>{
      'issueId': 'issue-1',
      'billNo': 'WF-1',
      'warehouseId': 'wh-1',
      'warehouseName': '原料仓',
      'lineCount': 2,
      'submittedAt': '2026-10-04T08:00:00Z',
      'submittedByName': '张三',
      'edited': edited,
    },
  ],
  'allowedActions': actions,
});
