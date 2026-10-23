import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_line_grid.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_issue_batch_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import 'workshop_material_test_support.dart';

class _BatchRepository extends FakeWorkshopMaterialRepository {
  _BatchRepository() {
    requisitionById = {};
    materialsByWorkshop = const {
      'w1': [wmTestPp],
    };
    for (var index = 1; index <= 2; index++) {
      requisitionById['request-$index'] = WmRequisition(
        id: 'request-$index',
        requestNo: 'LL-$index',
        kind: 'ISSUE',
        status: 'PENDING',
        workshopDepartmentId: 'w1',
        binWarehouseId: 'bin1',
        rowVersion: 1,
        allowedActions: const ['FULFIL'],
        lines: [
          WmRequisitionLine(
            id: 'chosen-$index',
            goodsId: 'pp',
            goodsName: '所选材料$index',
            requestedQty: 25,
            suggestedLeafWarehouseId: 'leafA',
            unitName: '公斤',
          ),
          WmRequisitionLine(
            id: 'unselected-$index',
            goodsId: 'pp',
            goodsName: '未选材料$index',
            requestedQty: 50,
            suggestedLeafWarehouseId: 'leafA',
            unitName: '公斤',
          ),
        ],
      );
    }
  }
  final calls = <({String request, List<String> lines, String key})>[];
  final supplements = <WmSupplement?>[];
  final bodies = <Map<String, dynamic>>[];
  bool reject = true;
  @override
  Future<WmIssueResult> fulfil(
    String id, {
    required int expectedVersion,
    required List<Map<String, dynamic>> lines,
    WmSupplement? supplement,
    List<Map<String, dynamic>> materialSetup = const [],
    required String idempotencyKey,
  }) async {
    bodies.add({
      'version': expectedVersion,
      'lines': lines,
      'materialSetup': materialSetup,
      'supplement': supplement?.toJson(),
    });
    supplements.add(supplement);
    calls.add((
      request: id,
      lines: [for (final line in lines) line['lineId'] as String],
      key: idempotencyKey,
    ));
    if (reject) throw ApiException('STOCK_SHORT', '库存不足，本次未办理');
    return WmIssueResult(requestNo: id);
  }
}

Future<void> confirmBatch(WidgetTester tester, {bool inbound = false}) async {
  await tester.tap(find.byKey(const Key('wm-issue-submit')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.widgetWithText(UtenButton, inbound ? '确认入库' : '确认出库').last,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('统一表格每行数量独立，复制选区不暗中改其它明细', (tester) async {
    final repo = _BatchRepository();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(
        selections: {
          'request-1': ['chosen-1'],
          'request-2': ['chosen-2'],
        },
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    final grid = tester.widget<UtenEditableGrid<WmIssueLineRow>>(
      find.byKey(const Key('wm-issue-grid')),
    );
    grid.controller.setSelected(grid.controller.rows, true);
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '7');
    await tester.pump();
    expect(grid.controller.rows.first.qty.text, '7');
    expect(grid.controller.rows.last.qty.text, '25');
    expect(grid.selectable, isFalse);
    expect(grid.columns.first.label, '状态');
    expect(grid.columns.take(5).map((column) => column.key), [
      'result',
      'billNo',
      'workshop',
      'material',
      'qty',
    ]);
    final keys = grid.columns.map((column) => column.key).toList();
    expect(keys.indexOf('bags'), 5);
    expect(keys.indexOf('leaf'), 6);
    expect(repo.calls, isEmpty);
  });

  testWidgets('统一领退料表在窄屏大文字深色状态没有布局溢出', (tester) async {
    final repo = _BatchRepository();
    repo.periodsByBin = const {
      'bin1': [
        WmPeriod(
          id: 'prior',
          periodNo: 1,
          startDate: '2026-09-01',
          status: WmPeriodStatus.counting,
        ),
      ],
    };
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(
        selections: {
          'request-1': ['chosen-1'],
        },
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
      size: const Size(390, 844),
      textScale: 2,
      theme: ThemeData.dark(),
    );
    expect(find.byKey(const Key('wm-issue-grid')), findsOneWidget);
    await tester.tap(find.text('补录前期发料'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('wm-batch-supplement-request-1')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(repo.calls, isEmpty);
  });
  testWidgets('统一表格保留可选前期补录，期间与原因进入同一出库命令', (tester) async {
    final repo = _BatchRepository()..reject = false;
    repo.periodsByBin = const {
      'bin1': [
        WmPeriod(
          id: 'prior',
          periodNo: 1,
          startDate: '2026-09-01',
          status: WmPeriodStatus.counting,
        ),
      ],
    };
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(
        selections: {
          'request-1': ['chosen-1'],
        },
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    await tester.tap(find.text('补录前期发料'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('wm-batch-supplement-request-1')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('wm-batch-supplement-reason-request-1')),
      '盘点前夜班漏录',
    );
    await tester.pumpAndSettle();
    await confirmBatch(tester);
    expect(repo.supplements.single?.periodId, 'prior');
    expect(repo.supplements.single?.reason, '盘点前夜班漏录');
    expect(repo.calls.single.lines, ['chosen-1']);
  });
  testWidgets('重开批次从实办行恢复进度，只继续其余申请', (tester) async {
    final repo = _BatchRepository()..reject = false;
    repo.requisitionById['request-1'] = const WmRequisition(
      id: 'request-1',
      requestNo: 'LL-1',
      kind: 'ISSUE',
      status: 'PENDING',
      workshopDepartmentId: 'w1',
      binWarehouseId: 'bin1',
      rowVersion: 2,
      allowedActions: ['FULFIL'],
      lines: [
        WmRequisitionLine(
          id: 'chosen-1',
          goodsId: 'pp',
          requestedQty: 25,
          fulfilledQty: 20,
          suggestedLeafWarehouseId: 'leafA',
        ),
        WmRequisitionLine(
          id: 'unselected-1',
          goodsId: 'pp',
          requestedQty: 50,
          suggestedLeafWarehouseId: 'leafA',
        ),
      ],
    );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(
        selections: {
          'request-1': ['chosen-1'],
          'request-2': ['chosen-2'],
        },
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    expect(find.text('已出库'), findsOneWidget);
    expect(find.text('继续办理'), findsNothing);
    await confirmBatch(tester);
    expect(repo.calls.single.request, 'request-2');
    expect(repo.calls.single.lines, ['chosen-2']);
    expect(find.text('已出库'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('同申请已办行与待办行混合重开，只提交尚未办理的原选行', (tester) async {
    final repo = _BatchRepository()..reject = false;
    repo.requisitionById['request-1'] = const WmRequisition(
      id: 'request-1',
      requestNo: 'LL-1',
      kind: 'ISSUE',
      status: 'PENDING',
      workshopDepartmentId: 'w1',
      binWarehouseId: 'bin1',
      rowVersion: 2,
      allowedActions: ['FULFIL'],
      lines: [
        WmRequisitionLine(
          id: 'chosen-1',
          goodsId: 'pp',
          requestedQty: 25,
          fulfilledQty: 20,
          suggestedLeafWarehouseId: 'leafA',
        ),
        WmRequisitionLine(
          id: 'unselected-1',
          goodsId: 'pp',
          requestedQty: 50,
          suggestedLeafWarehouseId: 'leafA',
        ),
      ],
    );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(
        selections: {
          'request-1': ['chosen-1', 'unselected-1'],
        },
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    expect(find.text('开始逐单核对'), findsNothing);
    expect(find.textContaining('已选 2 项'), findsOneWidget);
    await confirmBatch(tester);
    expect(repo.calls.single.lines, ['unselected-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('跨申请只办理所选明细，失败保留当前单和请求号，成功后不重复办理', (tester) async {
    final repo = _BatchRepository();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(
        selections: {
          'request-1': ['chosen-1'],
          'request-2': ['chosen-2'],
        },
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    expect(find.text('未选材料1'), findsNothing);
    expect(find.text('未选材料2'), findsNothing);
    expect(find.textContaining('已选 2 项'), findsOneWidget);
    expect(repo.calls, isEmpty);
    expect(find.text('开始逐单核对'), findsNothing);
    expect(find.byKey(const Key('wm-issue-grid')), findsOneWidget);
    await confirmBatch(tester);
    expect(find.text('库存不足，本次未办理'), findsOneWidget);
    expect(repo.calls.single.request, 'request-1');
    expect(repo.calls.single.lines, ['chosen-1']);
    repo.reject = false;
    await confirmBatch(tester);
    expect(repo.calls[1].key, repo.calls.first.key);
    expect(repo.calls.map((call) => call.request), [
      'request-1',
      'request-1',
      'request-2',
    ]);
    expect(repo.calls.last.lines, ['chosen-2']);
    expect(find.text('继续办理'), findsNothing);
    expect(find.text('已出库'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('退料与出库共用单表和一次确认，取消确认不办理', (tester) async {
    final repo = _BatchRepository()..reject = false;
    final source = repo.requisitionById['request-1']!;
    repo.requisitionById['request-1'] = WmRequisition(
      id: source.id,
      requestNo: source.requestNo,
      kind: 'RETURN',
      status: source.status,
      workshopDepartmentId: source.workshopDepartmentId,
      binWarehouseId: source.binWarehouseId,
      rowVersion: source.rowVersion,
      allowedActions: source.allowedActions,
      lines: source.lines,
    );
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(
        selections: {
          'request-1': ['chosen-1'],
        },
      ),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    expect(find.byKey(const Key('wm-issue-grid')), findsOneWidget);
    expect(find.text('生产退料批量入库'), findsOneWidget);
    expect(find.text('开始逐单核对'), findsNothing);
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty);
    await confirmBatch(tester, inbound: true);
    expect(repo.calls.single.lines, ['chosen-1']);
    expect(find.text('已入库'), findsOneWidget);
  });

  testWidgets('未知批量提交重开仍保留原键与范围，不需逐单进入', (tester) async {
    final repo = _UnknownRepository();
    final storage = MemoryFormDraftStorage();
    const page = WorkshopMaterialIssueBatchPage(
      selections: {
        'request-1': ['chosen-1'],
        'request-2': ['chosen-2'],
      },
    );
    await pumpWorkshopMaterialPage(
      tester,
      page,
      repo: repo,
      draftStorage: storage,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    await confirmBatch(tester);
    expect(repo.calls, hasLength(1));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
    );
    final draft = container.read(formDraftsProvider).single;
    expect(draft.hasUnknownSubmission, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await pumpWorkshopMaterialPage(
      tester,
      WorkshopMaterialIssueBatchPage(
        selections: page.selections,
        resumeDraftId: draft.id,
      ),
      repo: repo,
      draftStorage: storage,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    expect(find.text('原样重试核对结果'), findsOneWidget);
    expect(find.text('开始逐单核对'), findsNothing);
    await confirmBatch(tester);
    expect(repo.calls.map((call) => call.request), [
      'request-1',
      'request-1',
      'request-2',
    ]);
    expect(repo.calls[1].key, repo.calls.first.key);
    expect(repo.calls[1].lines, repo.calls.first.lines);
  });

  testWidgets('批量空选择不能隐式读取并办理原单全部明细', (tester) async {
    final repo = _BatchRepository();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(selections: {'request-1': []}),
      repo: repo,
      permissions: const {
        Perm.workshopMaterialView,
        Perm.workshopMaterialIssue,
      },
    );
    expect(find.text('请返回任务列表选择要办理的明细'), findsOneWidget);
    expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
    expect(find.text('开始逐单核对'), findsNothing);
    expect(repo.calls, isEmpty);
  });

  testWidgets('unknown command recovers after an unsent sibling is cancelled', (
    tester,
  ) async {
    final repo = _UnknownRepository();
    final originalA = repo.requisitionById['request-1']!;
    repo.requisitionById['request-1'] = WmRequisition(
      id: originalA.id,
      requestNo: originalA.requestNo,
      kind: originalA.kind,
      status: originalA.status,
      workshopDepartmentId: originalA.workshopDepartmentId,
      binWarehouseId: originalA.binWarehouseId,
      rowVersion: originalA.rowVersion,
      allowedActions: originalA.allowedActions,
      lines: [originalA.lines.first],
    );
    final storage = MemoryFormDraftStorage();
    const selections = {
      'request-1': ['chosen-1'],
      'request-2': ['chosen-2'],
    };
    const permissions = {Perm.workshopMaterialView, Perm.workshopMaterialIssue};
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssueBatchPage(selections: selections),
      repo: repo,
      draftStorage: storage,
      permissions: permissions,
    );
    await confirmBatch(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
    );
    final original = container.read(formDraftsProvider).single;
    final key = repo.calls.single.key;
    final body = repo.bodies.single;
    expect(original.hasUnknownSubmission, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    repo.requisitionById['request-1'] = WmRequisition(
      id: originalA.id,
      requestNo: originalA.requestNo,
      kind: originalA.kind,
      status: 'DONE',
      workshopDepartmentId: originalA.workshopDepartmentId,
      binWarehouseId: originalA.binWarehouseId,
      rowVersion: 2,
      lines: const [
        WmRequisitionLine(
          id: 'chosen-1',
          goodsId: 'pp',
          goodsName: '所选材料1',
          requestedQty: 25,
          fulfilledQty: 25,
          suggestedLeafWarehouseId: 'leafA',
          unitName: '公斤',
        ),
      ],
    );
    final originalB = repo.requisitionById['request-2']!;
    final cancelledB = WmRequisition(
      id: originalB.id,
      requestNo: originalB.requestNo,
      kind: originalB.kind,
      status: 'CANCELLED',
      workshopDepartmentId: originalB.workshopDepartmentId,
      binWarehouseId: originalB.binWarehouseId,
      rowVersion: 2,
      lines: originalB.lines,
    );
    repo.requisitionById['request-2'] = cancelledB;
    await pumpWorkshopMaterialPage(
      tester,
      WorkshopMaterialIssueBatchPage(
        selections: selections,
        resumeDraftId: original.id,
      ),
      repo: repo,
      draftStorage: storage,
      permissions: permissions,
    );
    expect(find.text('原样重试核对结果'), findsOneWidget);
    expect(find.text('已取消，本次未办理'), findsOneWidget);
    expect(find.textContaining('已选 2 项'), findsOneWidget);
    await confirmBatch(tester);
    expect(repo.calls.map((call) => call.request), ['request-1', 'request-1']);
    expect(repo.calls.last.key, key);
    expect(repo.bodies.last, body);
    expect(identical(repo.requisitionById['request-2'], cancelledB), isTrue);
    expect(cancelledB.lines.every((line) => line.fulfilledQty == 0), isTrue);
    expect(find.text('已出库'), findsOneWidget);
    expect(find.text('已取消，本次未办理'), findsOneWidget);
    expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
    final restoredContainer = ProviderScope.containerOf(
      tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
    );
    final remaining = restoredContainer.read(formDraftsProvider).single;
    expect(remaining.hasUnknownSubmission, isFalse);
    expect(remaining.data['selections'], selections);
    expect((remaining.data['rows'] as List), hasLength(2));
    final state =
        tester.state(find.byType(WorkshopMaterialIssueBatchPage))
            as FormDraftMixin<WorkshopMaterialIssueBatchPage>;
    expect(state.formDraftHasUnknownSubmission, isFalse);
    final exit = state.confirmFormDraftExit();
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存草稿').last);
    await tester.pumpAndSettle();
    expect(await exit, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final status in [403, 404]) {
    testWidgets(
      'unreadable sibling $status stays opaque while the original unknown command recovers',
      (tester) async {
        final fixture = await _unknownDraft(tester);
        fixture.repo.readFailures['request-2'] = ApiException(
          'SOURCE_UNAVAILABLE',
          '旧敏感资料不得显示',
          httpStatus: status,
        );
        await _restoreUnknown(tester, fixture);
        expect(
          find.byKey(const ValueKey('wm-unavailable-source-request-2')),
          findsOneWidget,
        );
        expect(find.textContaining('旧敏感资料不得显示'), findsNothing);
        expect(find.textContaining('所选材料2'), findsNothing);
        expect(find.textContaining('LL-2'), findsNothing);
        final grid = tester.widget<UtenEditableGrid<WmIssueLineRow>>(
          find.byKey(const Key('wm-issue-grid')),
        );
        expect(grid.controller.rows.map((row) => row.requisitionLine!.id), [
          'chosen-1',
        ]);
        expect(find.textContaining('已选 2 项'), findsOneWidget);
        await confirmBatch(tester);
        expect(fixture.repo.calls.map((call) => call.request), [
          'request-1',
          'request-1',
        ]);
        expect(fixture.repo.calls.last.key, fixture.key);
        expect(fixture.repo.bodies.last, fixture.body);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
        );
        final remaining = container.read(formDraftsProvider).single;
        expect(remaining.hasUnknownSubmission, isFalse);
        expect(remaining.data['selections'], _originalSelections);
        expect(
          (remaining.data['rows'] as List)
              .map((row) => (row as Map)['lineId'])
              .toSet(),
          {'chosen-1', 'chosen-2'},
        );
        expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an unreadable original unknown source cannot replay or dispatch its still-valid sibling',
    (tester) async {
      final fixture = await _unknownDraft(tester);
      fixture.repo.readFailures['request-1'] = ApiException(
        'NOT_FOUND',
        '原申请不可查看',
        httpStatus: 404,
      );
      await _restoreUnknown(tester, fixture);
      expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
      expect(fixture.repo.calls, hasLength(1));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
      );
      final preserved = container.read(formDraftsProvider).single;
      expect(preserved.hasUnknownSubmission, isTrue);
      expect(preserved.data['commands'], fixture.draft.data['commands']);
      expect(preserved.data['selections'], _originalSelections);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a malformed frozen command cannot use partial source recovery to dispatch',
    (tester) async {
      final fixture = await _unknownDraft(tester);
      final key = fixture.storage.records.keys.singleWhere(
        (key) => key.endsWith(fixture.draft.id),
      );
      final saved =
          jsonDecode(fixture.storage.records[key]!) as Map<String, dynamic>;
      final commands = (saved['data'] as Map)['commands'] as Map;
      ((commands['request-1'] as Map)['body'] as Map)['id'] = 'request-2';
      fixture.storage.records[key] = jsonEncode(saved);
      fixture.repo.readFailures['request-2'] = ApiException(
        'FORBIDDEN',
        '来源不可读',
        httpStatus: 403,
      );
      await _restoreUnknown(tester, fixture);
      expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
      expect(fixture.repo.calls, hasLength(1));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
      );
      expect(
        container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a normal fresh entry still rejects an unavailable sibling before any dispatch',
    (tester) async {
      final repo = _UnknownRepository();
      repo.readFailures['request-2'] = ApiException(
        'NOT_FOUND',
        '来源不存在',
        httpStatus: 404,
      );
      await pumpWorkshopMaterialPage(
        tester,
        const WorkshopMaterialIssueBatchPage(selections: _originalSelections),
        repo: repo,
        permissions: _issuePermissions,
      );
      expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
      expect(repo.calls, isEmpty);
      expect(find.byKey(const Key('wm-issue-grid')), findsNothing);
    },
  );

  testWidgets(
    'a stale unsent source never rebases after its sibling receipt is recovered',
    (tester) async {
      final fixture = await _unknownDraft(tester);
      final old = fixture.repo.requisitionById['request-2']!;
      fixture.repo.requisitionById['request-2'] = WmRequisition(
        id: old.id,
        requestNo: old.requestNo,
        kind: old.kind,
        status: old.status,
        workshopDepartmentId: old.workshopDepartmentId,
        binWarehouseId: old.binWarehouseId,
        rowVersion: 2,
        allowedActions: old.allowedActions,
        lines: old.lines,
      );
      await _restoreUnknown(tester, fixture);
      expect(find.text('申请已变化，本次未办理'), findsOneWidget);
      await confirmBatch(tester);
      expect(fixture.repo.calls.map((call) => call.request), [
        'request-1',
        'request-1',
      ]);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
      );
      final remaining = container.read(formDraftsProvider).single;
      expect((remaining.data['versions'] as Map)['request-2'], 1);
      expect(remaining.hasUnknownSubmission, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await _restoreUnknown(tester, fixture);
      expect(find.text('申请已变化，本次未办理'), findsOneWidget);
      expect(find.byKey(const Key('wm-issue-submit')), findsNothing);
      expect(fixture.repo.calls, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}

const _originalSelections = {
  'request-1': ['chosen-1'],
  'request-2': ['chosen-2'],
};
const _issuePermissions = {
  Perm.workshopMaterialView,
  Perm.workshopMaterialIssue,
};
typedef _UnknownFixture = ({
  _UnknownRepository repo,
  MemoryFormDraftStorage storage,
  FormDraft draft,
  String key,
  Map<String, dynamic> body,
});

Future<_UnknownFixture> _unknownDraft(WidgetTester tester) async {
  final repo = _UnknownRepository();
  final storage = MemoryFormDraftStorage();
  await pumpWorkshopMaterialPage(
    tester,
    const WorkshopMaterialIssueBatchPage(selections: _originalSelections),
    repo: repo,
    draftStorage: storage,
    permissions: _issuePermissions,
  );
  await confirmBatch(tester);
  final container = ProviderScope.containerOf(
    tester.element(find.byType(WorkshopMaterialIssueBatchPage)),
  );
  final draft = container.read(formDraftsProvider).single;
  final key = repo.calls.single.key;
  final body = repo.bodies.single;
  expect(draft.hasUnknownSubmission, isTrue);
  final source = repo.requisitionById['request-1']!;
  repo.requisitionById['request-1'] = WmRequisition(
    id: source.id,
    requestNo: source.requestNo,
    kind: source.kind,
    status: source.status,
    workshopDepartmentId: source.workshopDepartmentId,
    binWarehouseId: source.binWarehouseId,
    rowVersion: 2,
    allowedActions: source.allowedActions,
    lines: [
      const WmRequisitionLine(
        id: 'chosen-1',
        goodsId: 'pp',
        goodsName: '所选材料1',
        requestedQty: 25,
        fulfilledQty: 25,
        suggestedLeafWarehouseId: 'leafA',
        unitName: '公斤',
      ),
      source.lines.last,
    ],
  );
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  return (repo: repo, storage: storage, draft: draft, key: key, body: body);
}

Future<void> _restoreUnknown(WidgetTester tester, _UnknownFixture fixture) =>
    pumpWorkshopMaterialPage(
      tester,
      WorkshopMaterialIssueBatchPage(
        selections: _originalSelections,
        resumeDraftId: fixture.draft.id,
      ),
      repo: fixture.repo,
      draftStorage: fixture.storage,
      permissions: _issuePermissions,
    );

class _UnknownRepository extends _BatchRepository {
  bool loseResponse = true;
  final readFailures = <String, Object>{};
  @override
  Future<WmRequisition> requisition(String id) {
    if (readFailures[id] case final failure?) throw failure;
    return super.requisition(id);
  }

  @override
  Future<WmIssueResult> fulfil(
    String id, {
    required int expectedVersion,
    required List<Map<String, dynamic>> lines,
    WmSupplement? supplement,
    List<Map<String, dynamic>> materialSetup = const [],
    required String idempotencyKey,
  }) async {
    reject = false;
    final result = await super.fulfil(
      id,
      expectedVersion: expectedVersion,
      lines: lines,
      supplement: supplement,
      materialSetup: materialSetup,
      idempotencyKey: idempotencyKey,
    );
    if (loseResponse) {
      loseResponse = false;
      throw NetworkTimeoutException();
    }
    return result;
  }
}
