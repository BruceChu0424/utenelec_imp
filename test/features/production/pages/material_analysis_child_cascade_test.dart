// 「父件 + 下层一起下单」整页（ADR-081，2026-09-14 修订三见 ADR §八）。
//
// 场景：成品A 本批需求 10，计划员按 20 下达（超产 10）。它的 BOM 是
//   成品A ─┬─ 外购件B  单件用 2（采购）
//          └─ 半成品C  单件用 1（自制）
//                └─ 外购件D  单件用 3（采购，孙层）
// 断言：
//  1. 点「创建生产计划」后**直接进整页**（父件还没提交、此刻零网络写），
//     树顶是本次要下达的件，按 BOM 自顶向下列出子层 / 孙层，数量按**本批 20**
//     而不是快照需求 10 算出来；
//  2. 一键下单按序提交：父件 issue-plans → 采购 notify BUY → 自制 issue-plans；
//  3. 下单数量按行内填写值提交，不是默认的剩余需求；
//  4. 折叠分支撤掉的勾选在展开时原样恢复（不再静默少下单）；
//  5. 树顶那一行不画多选框，改它的数量下层第一次按键就跟着重算；
//  6. 树顶数量被清空时当场拦下，不按旧值提交父件；
//  7. 列集合守在定稿那一组(需求 / 还缺数量 / 下单数量 …),多余列不回潮；
//  8. 基础需求已下过单的下层行：申请未分解的把追加量并入原申请（明细数量
//     改大，V477）；已分解出下游单据的、以及需求已全部转成计划的自制行，
//     本页**不可勾选**，状态列如实写明该去哪儿办。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/material_analysis_warehouse_prefs_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

void main() {
  testWidgets('点创建生产计划先弹「跟父件一起办」，一键下单按序提交父件与下层', (tester) async {
    final harness = await _pump(tester);

    await _openWorkshopBucket(tester);

    // 本批数量改成 20（需求 10）——超产 10。
    await tester.enterText(_bucketQty('p1'), '20');
    await tester.pumpAndSettle();

    // 只勾选产品行（半成品C 那条自制候选留给下层办齐弹窗处理）。
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    // 超量二次确认。
    await tester.tap(find.text('确认超量下达'));
    await tester.pumpAndSettle();

    // 2026-09-14 修订：不再「先落库父件再补问」，也**不再弹窗**——确认超量后
    // 直接进入「跟父件一起办」整页（树表格 + 右下悬浮动作），此刻零网络写。
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    expect(find.text('父件 + 下层一起下单'), findsOneWidget);
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );

    // 树顶是本次要下达的那个件本身（只读上下文，状态列说明），下面才是子层 /
    // 孙层；名称列用与准备页同款的树组件（缩进 + 连线 + 展开箭头）。
    expect(find.textContaining('本次将下达 20'), findsOneWidget);
    expect(_inDialog('成品A'), findsOneWidget);
    expect(_inDialog('外购件B'), findsOneWidget);
    expect(_inDialog('半成品C'), findsOneWidget);
    expect(_inDialog('外购件D'), findsOneWidget);
    // 收起「半成品C」分支：孙层外购件D 隐藏、勾选随之撤掉（所见勾选=提交内容）；
    // 再展开时**原样恢复**勾选（2026-09-14：原来撤了就没了，折叠看一眼再展开
    // 就会静默少下单，用户还会以为一键下单按钮坏了）。
    await tester.tap(find.byKey(const Key('cascade-toggle-m-c')));
    await tester.pumpAndSettle();
    expect(_inDialog('外购件D'), findsNothing);
    await tester.tap(find.byKey(const Key('cascade-toggle-m-c')));
    await tester.pumpAndSettle();
    expect(_inDialog('外购件D'), findsOneWidget);

    // 数量按本批 20 算：B=20×2=40、C=20×1=20、D=20×3=60。
    expect(_qtyOf(tester, 'm-b'), '40');
    expect(_qtyOf(tester, 'm-c'), '20');
    expect(_qtyOf(tester, 'm-d'), '60');

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 一键下单之后才有提交：父件 issue-plans → 采购 notify → 下层自制 issue-plans。
    final issue = harness.writes
        .where((request) => request.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(2));
    // 第一次是父件产品行（本批 20），第二次是下层办齐把半成品C下到车间（20）。
    final parentLines =
        (issue.first.data as Map<String, dynamic>)['lines'] as List;
    expect(
      (parentLines.single as Map<String, dynamic>)['analysisLineId'],
      'p1',
    );
    final cascadeLines =
        (issue.last.data as Map<String, dynamic>)['lines'] as List;
    expect(cascadeLines, hasLength(1));
    final line = cascadeLines.single as Map<String, dynamic>;
    expect(line['materialLineId'], 'm-c');
    expect(line['qty'], 20.0);
    expect(line['departmentId'], 'dept-1');

    // 采购两行合并成一次 notify。
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    final notifyBody = notify.single.data as Map<String, dynamic>;
    expect(notifyBody['target'], 'BUY');
    // 超出本需求的部分按 V472 分账：qty = 归本需求量，publicExtraQty = 公共备货量。
    expect(
      (notifyBody['quantities'] as List)
          .cast<Map<String, dynamic>>()
          .map(
            (row) =>
                '${row['actionGroupKey']}=${row['qty']}+${row['publicExtraQty']}',
          )
          .toSet(),
      {'ag-b=20.0+20.0', 'ag-d=30.0+30.0'},
    );
  });

  testWidgets('已下单子件：申请未分解并入原申请调量，已分解问过后按追加另立', (tester) async {
    final harness = await _pump(
      tester,
      childrenAlreadyOrdered: true,
      customizeAnalysis: (analysis) {
        final rows = (analysis['flatMaterials'] as List)
            .cast<Map<String, dynamic>>();
        // C is a frozen workshop commitment, not ten finished units on a shelf.
        rows[2].addAll({
          'availableQty': 0,
          'allocatedAvailableQty': 0,
          'internalCommittedOutputQty': 10,
        });
        rows[3].addAll({
          'availableQty': 0,
          'allocatedAvailableQty': 0,
          'externalFutureCoverageQty': 30,
        });
      },
    );

    await _openWorkshopBucket(tester);

    // 基础需求已全部下过单（现货全覆盖=还可下达 0），按 20 超量下达 →
    // 下层超产多需：B=20、C=10、D=60。
    await tester.enterText(_bucketQty('p1'), '20');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认超量下达'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    // 联动状态加载后：B（申请未分解）显示并入口径，D（已分解）显示追加口径。
    await tester.pumpAndSettle();
    expect(find.textContaining('PR-0001（未分解）'), findsOneWidget);
    expect(find.textContaining('已下单 PO-0002'), findsOneWidget);
    // 自制候选：需求已全转计划，本页不下单，状态如实写明去处。
    expect(find.textContaining('本批需求已全部转成生产计划'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    // 确认弹窗把两类去向说清（用户口径「问是不是追加」）。
    final confirmDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
        of: confirmDialog,
        matching: find.textContaining('并入原申请'),
      ),
      findsOneWidget,
    );
    // 已分解出下游单据的行本页不下单：分析侧的提交单元已不可执行，勾了也只会
    // 在采购段被整段挡住。弹窗如实指到能办的地方去。
    expect(
      find.descendant(
        of: confirmDialog,
        matching: find.textContaining('本页不下单，请到下游模块追加'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 并入申请：把 PR-0001 明细从 20 改大到 20+20=40（V477 sanctioned 入口）。
    final adjust = harness.writes
        .where((request) => request.path.endsWith('/items/pri-1/qty'))
        .toList();
    expect(adjust, hasLength(1));
    expect(adjust.single.data, {'qty': 40.0});

    // 已分解的 D 不再从本页下单（它的提交单元在分析侧已不可执行），
    // 因此这一批里没有任何采购 notify。
    final notify = harness.writes
        .where((request) => request.path.endsWith('/notify'))
        .toList();
    expect(notify, isEmpty);

    // 半成品C 的本批需求已全部转成计划（还可下达 0），只剩超产多出来的量：
    // 服务端的排产资格闸早于数量校验，必拒 400/409，一拒就把整条一键下单
    // 卡在车间段。所以它在本页**不可勾选**，只剩父件那一次 issue-plans。
    final issue = harness.writes
        .where((request) => request.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(1));
    final parentLines =
        (issue.single.data as Map<String, dynamic>)['lines'] as List;
    expect(
      (parentLines.single as Map<String, dynamic>)['analysisLineId'],
      'p1',
    );
  });

  testWidgets('分桶详情改供应方式=立即确认路线并换桶', (tester) async {
    final harness = await _pump(tester);
    final entry = find.byKey(const Key('material-analysis-entry-buy'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 采购桶里把「外购件B」的供应方式改成自制。
    await tester.tap(
      find.byKey(const ValueKey('material-bucket-route-NODE|ag-b|m-b')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自制').last);
    await tester.pumpAndSettle();
    expect(find.text('确认并换桶'), findsOneWidget);
    await tester.tap(find.text('确认并换桶'));
    await tester.pumpAndSettle();

    final routes = harness.writes
        .where((request) => request.path.endsWith('/routes'))
        .toList();
    expect(routes, hasLength(1));
    expect((routes.single.data as Map<String, dynamic>)['decisions'], [
      {'actionGroupKey': 'ag-b', 'route': 'MAKE'},
    ]);
  });

  testWidgets('树顶父件行没有多选框，且改它的数量下层立刻跟着重算', (tester) async {
    await _pump(tester);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '10');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();

    // 用户口径「父类应该默认没有多选框」：树顶那一行整格不渲染 Checkbox
    // （不是画一个点不动的灰框——那会被读成权限不足 / 数据有问题）。
    final seedRow = find.ancestor(
      of: _inDialog('成品A'),
      matching: find.byType(UtenFrozenLeadingColumn),
    );
    expect(
      find.descendant(of: seedRow, matching: find.byType(Checkbox)),
      findsNothing,
    );
    // 子层行照常有勾选框。
    final childRow = find.ancestor(
      of: _inDialog('外购件B'),
      matching: find.byType(UtenFrozenLeadingColumn),
    );
    expect(
      find.descendant(of: childRow, matching: find.byType(Checkbox)),
      findsWidgets,
    );

    // 默认：B=10×2=20、C=10×1=10、D=10×3=30。
    expect(_qtyOf(tester, 'm-b'), '20');
    expect(_qtyOf(tester, 'm-d'), '30');

    // 改树顶数量 → 下层**第一次按键就**跟着重算（原来控制器监听早于
    // onChanged 置 qtyTouched，第一次输入被整个吞掉）。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '30',
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '60');
    expect(_qtyOf(tester, 'm-d'), '90');
  });

  testWidgets('树顶数量被清空时不按旧数量提交，而是当场拦下', (tester) async {
    final harness = await _pump(tester);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '10');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    // 一行都不许提交，页面也不许关：原来 seed.batchQty 保留上一次的合法值，
    // 守卫直接放行，父件按一个界面上根本不存在的数量落库。
    //（错误提示走全局顶部通知 provider，不在本页组件树里，故只断事实。）
    expect(
      harness.writes.where((r) => r.path.endsWith('/issue-plans')),
      isEmpty,
    );
    expect(harness.writes.where((r) => r.path.endsWith('/notify')), isEmpty);
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
  });

  testWidgets('级联页表头与外面那张表一致，不多塞列', (tester) async {
    await _pump(tester);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '10');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();

    // 2026-09-14 用户口径「表头应该和外面的一样，不要添加这么多没用的」：
    // 与分桶详情那张表同一组列，外加本页结构上必需的两列(下达去向 / 还缺数量)
    // ——没有它们就说不清「这行该走哪条路、还能下多少」。
    // 2026-09-15 追加「所属仓库」(V587)：货品主档归属，三张表同一列同一份真相。
    // 必填列的表头带红星(RichText)，用包含匹配而不是全等。
    for (final label in [
      '物料名称',
      '编号',
      '颜色',
      '单位',
      '供料路线',
      '所属仓库',
      '下达去向',
      '需求数量',
      '还缺数量',
      '下单数量',
      '生产车间',
      '负责人',
      '状态',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(const Key('material-analysis-child-cascade-dialog')),
          matching: find.textContaining(label),
        ),
        findsWidgets,
        reason: '缺少「$label」列',
      );
    }
    // 这些是一轮过度添加后按用户要求撤掉的，别再回来。
    // 2026-09-15 追加「本批要用」：它与「需求数量」只差一个超产量，摆在表上
    // 要用户自己做减法，用户明确要求删掉（字段仍在，只是不出列）。
    // 「还可下达」同批改名为「还缺数量」，旧名不该再出现在表头。
    for (final label in [
      '可用数量',
      '缺口',
      '在途未入库',
      '单位耗用',
      '公共认领未实收',
      '来自',
      '本批要用',
      '还可下达',
    ]) {
      expect(_inDialog(label), findsNothing, reason: '「$label」列是多余的，不该出现');
    }
  });

  testWidgets('没有采购分解权限时，「并入已有申请」只读提示而不是提交后 403', (tester) async {
    final harness = await _pump(
      tester,
      childrenAlreadyOrdered: true,
      withPurchaseAdjustPermission: false,
    );
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '20');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认超量下达'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    // 端点要 purchase_request:view + purchase_order:decompose，计划员通常没有。
    // 不先判一下就会：勾上、弹窗承诺「并入原申请」、一提交 403，并把整条
    // 一键下单卡在这一段（父件那时已经落库）。
    expect(find.textContaining('需要采购申请查看 + 订货分解权限'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    if (find.text('一键下单').evaluate().isNotEmpty) {
      await tester.tap(find.text('一键下单'));
    } else {
      await tester.tap(find.text('只下达父件'));
    }
    await tester.pumpAndSettle();
    // 一次采购申请调量都不该发出去。
    expect(
      harness.writes.where((r) => r.path.endsWith('/items/pri-1/qty')),
      isEmpty,
    );
  });

  testWidgets('下层无需再下单时不弹弹窗，父件直接按原路提交', (tester) async {
    await _pump(tester, childrenAlreadyOrdered: true);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '10');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('留在物料分析'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsNothing,
    );
  });

  // V581：只有一个叶子子件的委外件**不进车间**——父件走 notify SUBCONTRACT，
  // 那颗子件仍要我方备出来，所以照样进「跟父件一起办」整页。
  testWidgets('单一叶子子件的委外件：父件走下达委外，子件仍进一起办', (tester) async {
    final harness = await _pump(tester, soleComponentSubcontract: true);
    final entry = find.byKey(const Key('material-analysis-entry-subcontract'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-subcontract')),
    );
    await tester.pumpAndSettle();

    // 进了整页（因为那颗子件还没下单），而不是直接提交。
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    expect(harness.writes, isEmpty);
    expect(_inDialog('外购件B'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    final paths = harness.writes.map((write) => write.path).toList();
    // 父件段必须是 notify（委外申请），绝不能是 issue-plans（建生产计划）。
    expect(
      paths.where((path) => path.endsWith('/issue-plans')),
      isEmpty,
      reason: '单一子件委外不先自制，不该出现生产计划',
    );
    expect(paths.where((path) => path.endsWith('/notify')), isNotEmpty);
    final targets = harness.writes
        .where((write) => write.path.endsWith('/notify'))
        .map((write) => (write.data as Map)['target'])
        .toList();
    expect(targets, contains('SUBCONTRACT'));
    expect(targets, contains('BUY'));
  });

  // 2026-09-15 用户反馈 3：树顶（父件）那一行也要有生产车间与负责人，且要有
  // 相应限制。此前 `needsWorkshop` 硬写 `!isSeed`、`_canAssignWorkshop` 还要
  // `ownsInput`（树顶恒为 false），整格被一句「车间在上一页已经填过」封死——
  // 那句话对「下达委外」入口根本不成立，而车间入口的值也只是看不见地带过去。
  testWidgets('树顶父件行显示并回写生产车间与负责人，父件段按它提交', (tester) async {
    final harness = await _pump(tester);
    await _openWorkshopBucket(tester);
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();

    // 树顶行不再是灰 '—'：上一页选的车间/负责人落在它自己的格子里，且可点重选。
    expect(
      find.byKey(const Key('material-analysis-child-cascade-workshop-root-1')),
      findsOneWidget,
      reason: '树顶的车间格是可点的选择器，不是死的 —',
    );
    expect(
      find.byKey(const Key('material-analysis-child-cascade-worker-root-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    final issue = harness.writes
        .where((request) => request.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, isNotEmpty);
    final parent =
        ((issue.first.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(parent['analysisLineId'], 'p1');
    expect(parent['departmentId'], 'dept-1');
    expect(parent['workerId'], 'emp-1');
  });

  // 2026-09-15 用户反馈 2 最直接的根因：分桶页那个「下达委外(N)」红按钮点下去
  // 只是打开了本页，父件一个字节都没提交；而本页的返回箭头与右下角按钮都
  // 直接 pop，零提示——用户当然以为已经下达了，回头看那行还在「未下达」。
  testWidgets('父件尚未提交时退出必须确认，确认后一个写请求都不发', (tester) async {
    final harness = await _pump(tester);
    await _openWorkshopBucket(tester);
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();

    // 按钮文案说实话：这一步不是「稍后再办下层」，是整次下达作废。
    expect(find.text('放弃本次下达'), findsWidgets);
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-discard')),
    );
    await tester.pumpAndSettle();
    expect(find.text('放弃本次下达？'), findsOneWidget);

    // 取消 → 留在本页，什么都没丢。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-discard')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('放弃本次下达'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsNothing,
    );
    expect(harness.writes, isEmpty, reason: '放弃就是一个写请求都不发');
  });

  // 2026-09-15 用户口径「点了下达没反馈像卡住」：一键下单是多段网络提交，
  // 跑批期间本页必须盖全屏加载遮罩——级联页是 opaque 整页，宿主页/分桶页
  // Stack 里那份遮罩被盖住根本不会 build。父件段挂起时遮罩在场、标题跟着
  // 车间段（planSubmissionProgress）走；跑完自动撤下。
  testWidgets('一键下单跑批期间整页盖全屏加载遮罩，跑完自动撤下', (tester) async {
    final issueGate = Completer<void>();
    final harness = await _pump(
      tester,
      writeGate: (request) async {
        if (request.path.endsWith('/issue-plans')) {
          await issueGate.future;
        }
      },
    );
    await _openWorkshopBucket(tester);
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(
      find.byKey(const Key('material-analysis-child-cascade-busy')),
      findsOneWidget,
    );
    // 父件段走 issue-plans：车间段标题（无审核权限 → 不带「并审核」）。
    expect(find.text('正在生成生产计划'), findsOneWidget);

    issueGate.complete();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('material-analysis-child-cascade-busy')),
      findsNothing,
    );
    expect(
      harness.writes.where((request) => request.path.endsWith('/issue-plans')),
      isNotEmpty,
    );
  });

  // 2026-09-15 用户反馈 2：委外子层级物料数 >= 1 时要走自制，下达之后「下达
  // 车间」里应该自动出现对应的、已下达的前置自制任务。此前服务端 notify 只
  // 建台账与分析行、不出计划，前端编排也没有把它接上，于是那件东西只会静静
  // 躺在「下达车间 / 未下达」里，用户看到的就是「下达了，什么都没发生」。
  testWidgets('有自制子层的委外件：父件 notify 之后，前置自制任务自动下达车间', (tester) async {
    final harness = await _pump(tester, makeFirstSubcontract: true);
    final entry = find.byKey(const Key('material-analysis-entry-subcontract'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-subcontract')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    expect(harness.writes, isEmpty, reason: '进页之前零网络写');

    // 有自制子层的委外件在服务端强制整量接管，所以树顶那格数量是只读的，
    // 不再给一个填了也会被丢弃的输入框。
    expect(
      find.byKey(const Key('material-analysis-child-cascade-qty-root-1')),
      findsNothing,
    );
    // 但它**要**车间与负责人——真正需要车间的正是随后建出来的前置自制任务。
    expect(
      find.byKey(const Key('material-analysis-child-cascade-workshop-root-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    final paths = harness.writes.map((write) => write.path).toList();
    final notifyTargets = harness.writes
        .where((write) => write.path.endsWith('/notify'))
        .map((write) => (write.data as Map)['target'])
        .toList();
    expect(notifyTargets.first, 'SUBCONTRACT', reason: '父件段先建前置自制台账');
    expect(notifyTargets, contains('BUY'), reason: '下层外购件同批下达采购');

    // 关键：台账建完立刻按树顶填的车间/负责人把锚点下达车间，锚点因此进入
    // 「下达车间 / 已下达」，而不是躺在未下达里等人发现。
    final issue = harness.writes
        .where((write) => write.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(1));
    final line =
        ((issue.single.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(line['analysisLineId'], 'sc-make-1');
    expect(line['departmentId'], 'dept-1');
    expect(line['workerId'], 'emp-1');
    expect(
      paths.indexOf(issue.single.path),
      greaterThan(0),
      reason: '前置自制排产必须排在父件 notify 之后',
    );
  });

  // 2026-09-16 用户反馈：「委外，子层有很多物料的时候，下单数量不可以修改」。
  // 根因是那条行走 notify，服务端 `createsChildOwnership` 强制整量接管；有生成
  // 生产计划权限时改走 issue-plans 的 ARRANGE 段（V589 让委外台账跟量），数量
  // 就可以改，且台账 + 锚点 + 计划一步建好——不再需要第二段「前置自制下达车间」。
  testWidgets('非顶层的有子层委外件：数量可改，一步走 issue-plans 并带动下层重算', (tester) async {
    final harness = await _pump(tester, nestedMakeFirstSubcontract: true);
    final entry = find.byKey(const Key('material-analysis-entry-subcontract'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '委外件S');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-subcontract')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );
    expect(harness.writes, isEmpty, reason: '进页之前零网络写');

    // 树顶数量**可改**（不再是只读的锁定格），改了下层跟着重算：B = 30 × 2。
    final seedQty = find.byKey(
      const Key('material-analysis-child-cascade-qty-m-s'),
    );
    expect(seedQty, findsOneWidget);
    expect(_qtyOf(tester, 'm-b'), '20');
    await tester.enterText(seedQty, '30');
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '60');

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    // 本页改大了数量：超量二次确认必须补问一次（分桶页那一下没问过）。
    await tester.tap(find.text('确认超量下达').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 父件段是 issue-plans（候选行 m-s），不是 notify SUBCONTRACT。
    final issue = harness.writes
        .where((write) => write.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(1), reason: '一步建好台账+锚点+计划，不再有第二段排产');
    final line =
        ((issue.single.data as Map<String, dynamic>)['lines'] as List).single
            as Map<String, dynamic>;
    expect(line['materialLineId'], 'm-s');
    expect(line['qty'], 30.0);
    expect(line['departmentId'], 'dept-1');
    // 下层采购按放大后的量下达。
    final notify = harness.writes
        .where((write) => write.path.endsWith('/notify'))
        .toList();
    expect(notify, hasLength(1));
    final notifyBody = notify.single.data as Map<String, dynamic>;
    expect(notifyBody['target'], 'BUY');
    expect(
      (notifyBody['quantities'] as List)
          .cast<Map<String, dynamic>>()
          .map((row) => '${row['actionGroupKey']}=${row['qty']}')
          .single,
      startsWith('ag-b=20.0'),
      reason: '归需求 20，多出来的 40 走公共备货片',
    );
  });

  // 2026-09-16 用户反馈：「我下达车间选择很多，包括顶层的，它们都是顶层的子层级；
  // 我多选后改顶层的数量，其他的就不会变」。根因是每个勾选行各成一棵树、互不驱动。
  testWidgets('多选父件与它的下层：合并成一棵树，改父件数量下层一起变', (tester) async {
    final harness = await _pump(tester);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '10');
    await tester.pumpAndSettle();
    await tester.enterText(_bucketQty('m-c'), '10');
    await tester.pumpAndSettle();
    // 同时勾选顶层产品与它的自制子件（半成品C 是成品A 的 BOM 后代）。
    await _tapRowCheckbox(tester, '成品A');
    await _tapRowCheckbox(tester, '半成品C');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-child-cascade-dialog')),
      findsOneWidget,
    );

    // 只有一个树顶：半成品C 并进了成品A 那棵树，顶部提示点名说清去向。
    expect(find.textContaining('本次将下达：成品A'), findsOneWidget);
    expect(find.textContaining('半成品C'), findsWidgets);
    // 半成品C 现在是一行普通下层行，有自己的数量框（树顶行没有 m-c 的框）。
    expect(_qtyOf(tester, 'm-c'), '10');
    expect(_qtyOf(tester, 'm-d'), '30');

    // 改顶层数量 → 半成品C 与它下面的外购件D 一起跟着变（正是用户说的「不会变」）。
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '30',
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-c'), '30');
    expect(_qtyOf(tester, 'm-d'), '90');

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认超量下达').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    // 父件段只提交顶层那一行：被吸收的半成品C 从父件请求里剔除，
    // 由级联页的车间段按算好的 30 提交，不会按分桶页那个旧的 10 下两次。
    final issue = harness.writes
        .where((write) => write.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(2));
    final parentLines =
        (issue.first.data as Map<String, dynamic>)['lines'] as List;
    expect(parentLines, hasLength(1));
    expect(
      (parentLines.single as Map<String, dynamic>)['analysisLineId'],
      'p1',
    );
    final cascadeLines =
        (issue.last.data as Map<String, dynamic>)['lines'] as List;
    expect(cascadeLines, hasLength(1));
    final cascaded = cascadeLines.single as Map<String, dynamic>;
    expect(cascaded['materialLineId'], 'm-c');
    expect(cascaded['qty'], 30.0);
  });

  testWidgets('父子多选保留默认跟量，父件改小后采购子层和孙层也减少', (tester) async {
    final harness = await _pump(tester);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '5');
    await _tapRowCheckbox(tester, '成品A');
    await _tapRowCheckbox(tester, '半成品C');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-c'), '5');
    expect(_qtyOf(tester, 'm-b'), '10');
    expect(_qtyOf(tester, 'm-d'), '15');
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '2',
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-c'), '2');
    expect(_qtyOf(tester, 'm-b'), '4');
    expect(_qtyOf(tester, 'm-d'), '6');
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();
    final issues = harness.writes
        .where((r) => r.path.endsWith('/issue-plans'))
        .toList();
    expect(issues, hasLength(2));
    expect(
      (((issues.last.data as Map)['lines'] as List).single
          as Map<String, dynamic>)['qty'],
      2.0,
    );
  });

  testWidgets('采购起订策略只抬本批需要量，且超产后仍按整包装抬量', (tester) async {
    await _pump(
      tester,
      customizeAnalysis: (analysis) {
        final material = (analysis['flatMaterials'] as List)[1] as Map;
        material['minOrderQty'] = 12;
        material['orderMultipleQty'] = 5;
      },
    );
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '5');
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '15');
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '12',
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '25');
  });

  testWidgets('父件非基本单位按换算率与逐边包装固定批次算量', (tester) async {
    await _pump(
      tester,
      customizeAnalysis: (analysis) {
        (analysis['products'] as List)
                .cast<Map<String, dynamic>>()
                .first['unitRate'] =
            2;
        final rows = (analysis['flatMaterials'] as List)
            .cast<Map<String, dynamic>>();
        rows[0]['perProductQty'] = 2;
        rows[1].addAll({
          'bomQty': 3,
          'consumptionBasis': 'PER_PACKAGE',
          'basisOutputQty': 4,
          'allowPartialPackage': false,
        });
        rows[2].addAll({'bomQty': 0.2, 'consumptionBasis': 'PER_UNIT'});
        rows[3].addAll({
          'bomQty': 0.3,
          'consumptionBasis': 'FIXED_BATCH',
          'basisOutputQty': 1,
        });
      },
    );
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '3');
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '6');
    expect(_qtyOf(tester, 'm-c'), '1.2');
    expect(_qtyOf(tester, 'm-d'), '0.6');
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '2.5',
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'm-b'), '6');
    expect(_qtyOf(tester, 'm-c'), '1');
    expect(_qtyOf(tester, 'm-d'), '0.3');
  });

  for (final externalSupply in [false, true]) {
    testWidgets('父件部分批先用${externalSupply ? '外部在途' : '已有库存'}，已覆盖半成品不重复备孙层', (
      tester,
    ) async {
      await _pump(
        tester,
        customizeAnalysis: (analysis) {
          final rows = (analysis['flatMaterials'] as List)
              .cast<Map<String, dynamic>>();
          rows[1]['additionalSupplyRecommendedQty'] = 4;
          rows[1]['allocatedAvailableQty'] = 16;
          rows[2]['additionalSupplyRecommendedQty'] = 2;
          rows[2]['allocatedAvailableQty'] = externalSupply ? 0 : 8;
          rows[2]['externalFutureCoverageQty'] = externalSupply ? 8 : 0;
        },
      );
      await _openWorkshopBucket(tester);
      await tester.enterText(_bucketQty('p1'), '9');
      await _tapRowCheckbox(tester, '成品A');
      await tester.tap(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
      );
      await tester.pumpAndSettle();
      expect(_qtyOf(tester, 'm-b'), '2');
      expect(_qtyOf(tester, 'm-c'), '1');
      expect(_qtyOf(tester, 'm-d'), '3');
      await tester.enterText(
        find.byKey(
          const ValueKey('material-analysis-child-cascade-qty-root-1'),
        ),
        '5',
      );
      await tester.pumpAndSettle();
      for (final id in ['m-b', 'm-c', 'm-d']) {
        expect(
          find.byKey(ValueKey('material-analysis-child-cascade-qty-$id')),
          findsNothing,
        );
      }
      expect(find.text('已勾选 0 行'), findsOneWidget);
    });
  }

  testWidgets('千节点分析限制级联页窗，输入全量联动且跨页校验提交', (tester) async {
    final harness = await _pump(
      tester,
      customizeAnalysis: (analysis) {
        final rows = (analysis['flatMaterials'] as List)
            .cast<Map<String, dynamic>>();
        analysis['flatMaterials'] = [
          rows.first,
          for (var i = 0; i < 1000; i++)
            {
              ...rows[1],
              'materialLineId': 'large-$i',
              'nodeKey': 'large-$i',
              'actionGroupKey': 'large-action-$i',
              'goodsCode': 'large-${i.toString().padLeft(4, '0')}',
            },
        ];
      },
    );
    await _openWorkshopBucket(tester);
    await _tapRowCheckbox(tester, '成品A');
    final watch = Stopwatch()..start();
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    final openMs = watch.elapsedMilliseconds;
    expect(
      find.byKey(const Key('material-analysis-child-cascade-truncated')),
      findsOneWidget,
    );
    watch.reset();
    await tester.enterText(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-root-1')),
      '5',
    );
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'large-0'), '10');
    expect(harness.writes, isEmpty);
    final inputMs = watch.elapsedMilliseconds;
    expect(find.text('1 / 6 · 共 300 条'), findsOneWidget);
    expect(find.text('一键下单(299)'), findsOneWidget);
    await tester.tap(find.text('下一页').last);
    await tester.pumpAndSettle();
    expect(_qtyOf(tester, 'large-49'), '10');
    await tester.enterText(
      find.byKey(
        const ValueKey('material-analysis-child-cascade-qty-large-49'),
      ),
      '1',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('上一页').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('2 / 6 · 共 300 条'),
      findsOneWidget,
      reason: 'The invalid selected row on another page must be revealed.',
    );
    expect(harness.writes, isEmpty);
    await tester.enterText(
      find.byKey(
        const ValueKey('material-analysis-child-cascade-qty-large-49'),
      ),
      '10',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('将按各自路线依次下达 299 行'), findsOneWidget);
    await tester.tap(find.text('一键下单').last);
    await tester.pumpAndSettle();
    final purchases = harness.writes.where(
      (write) => write.path.endsWith('/notify'),
    );
    expect(purchases, hasLength(1));
    expect((purchases.single.data as Map)['quantities'], hasLength(299));
    // Diagnostic measurements have no environment-dependent timing assertion.
    debugPrint(
      'cascade 1000-node snapshot / 50-row page: open ${openMs}ms, input ${inputMs}ms',
    );
  });

  for (final legacy in [false, true]) {
    testWidgets('已排产锚点保留已安排覆盖，${legacy ? '历史转交' : '原位需求'}只补剩余量', (
      tester,
    ) async {
      await _pump(
        tester,
        anchoredMakeChild: true,
        customizeAnalysis: (analysis) {
          final anchor = (analysis['products'] as List).last as Map;
          anchor['remainingQty'] = 4;
          final child =
              (analysis['flatMaterials'] as List)[2] as Map<String, dynamic>;
          if (!legacy) {
            child.addAll({'requiredQty': 10, 'requirementState': null});
          }
          child['internalCommittedOutputQty'] = 6;
        },
      );
      await _openWorkshopBucket(tester);
      await _tapRowCheckbox(tester, '成品A');
      await tester.tap(
        find.byKey(const Key('material-analysis-bucket-action-ready')),
      );
      await tester.pumpAndSettle();
      expect(_qtyOf(tester, 'm-c'), '4');
      expect(
        _qtyOf(tester, 'm-d'),
        '30',
        reason: 'The existing internal work still needs its material.',
      );
    });
  }

  testWidgets('锚点保留原位需求时先用现货，不再增产已覆盖半成品', (tester) async {
    await _pump(
      tester,
      anchoredMakeChild: true,
      customizeAnalysis: (analysis) {
        ((analysis['products'] as List).last as Map)['remainingQty'] = 2;
        ((analysis['flatMaterials'] as List)[2] as Map<String, dynamic>)
            .addAll({
              'requiredQty': 10,
              'requirementState': null,
              'allocatedAvailableQty': 8,
              'additionalSupplyRecommendedQty': 2,
            });
      },
    );
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '5');
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-c')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('material-analysis-child-cascade-qty-m-d')),
      findsNothing,
    );
  });

  // 2026-09-16 用户口径：「已经下达了的(委外/其他自制件/采购)，再次点最顶层
  // 下达车间时里面的数值计算对不对、是不是减去可用、顶层数值再增加怎么处理」。
  // 已建过自制子件任务的行原来一律「本页不下达」，现在按锚点产品行追加。
  testWidgets('已建自制任务的下层：按锚点追加下达，数量不被重复计算', (tester) async {
    final harness = await _pump(tester, anchoredMakeChild: true);
    await _openWorkshopBucket(tester);
    await tester.enterText(_bucketQty('p1'), '30');
    await tester.pumpAndSettle();
    await _tapRowCheckbox(tester, '成品A');
    await tester.tap(
      find.byKey(const Key('material-analysis-bucket-action-ready')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认超量下达').last);
    await tester.pumpAndSettle();

    // 半成品C 的需求账已搬到锚点上(物料行 requiredQty=0)。下单数量必须正好是
    // 父件这一批要用的 30——不能因为「快照需求 0」把超产量算成整个毛需求再叠
    // 一次(那样会变成 60)。孙层外购件D 照旧按 30 × 3 = 90。
    expect(_qtyOf(tester, 'm-c'), '30');
    expect(_qtyOf(tester, 'm-d'), '90');

    await tester.tap(
      find.byKey(const Key('material-analysis-child-cascade-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键下单'));
    await tester.pumpAndSettle();

    final issue = harness.writes
        .where((write) => write.path.endsWith('/issue-plans'))
        .toList();
    expect(issue, hasLength(2));
    // 关键：锚点接管过的行按**产品行 id** 追加(analysisLineId=锚点)，
    // 不是按物料行 id 再建一个新任务。
    final cascadeLines =
        (issue.last.data as Map<String, dynamic>)['lines'] as List;
    final anchored = cascadeLines
        .cast<Map<String, dynamic>>()
        .where((line) => line['analysisLineId'] == 'make-c-1')
        .single;
    expect(anchored['qty'], 30.0);
    expect(anchored['materialLineId'], isNull);
  });
}

Finder _inDialog(String text) => find.descendant(
  of: find.byKey(const Key('material-analysis-child-cascade-dialog')),
  matching: find.text(text),
);

Finder _bucketQty(String rowId) =>
    find.byKey(ValueKey('material-analysis-bucket-qty-$rowId'));

/// 按行内文本定位整行（横滚时首列勾选框在冻结包裹层里，不再是数据 Row 的后代）
/// 并点它的勾选框。
Future<void> _tapRowCheckbox(WidgetTester tester, String text) async {
  final frozen = find.ancestor(
    of: find.text(text).first,
    matching: find.byType(UtenFrozenLeadingColumn),
  );
  final row = frozen.evaluate().isNotEmpty
      ? frozen.first
      : find
            .ancestor(of: find.text(text).first, matching: find.byType(Row))
            .first;
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

String _qtyOf(WidgetTester tester, String materialLineId) => tester
    .widget<TextField>(
      find.byKey(
        ValueKey('material-analysis-child-cascade-qty-$materialLineId'),
      ),
    )
    .controller!
    .text;

Future<void> _openWorkshopBucket(WidgetTester tester) async {
  final entry = find.byKey(const Key('material-analysis-entry-workshop'));
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

/// 写请求之后把快照版本推进一版（`analysis` 直接返回的与 issue-plans 包在
/// `{'analysis': ...}` 里的两种形状都要覆盖）。
Object? _bumpVersion(Object? data, int writes) {
  if (writes <= 0) return data;
  if (data is Map<String, dynamic> && data['version'] is int) {
    return {
      ...data,
      'version': (data['version'] as int) + writes,
      'fingerprint': 'a' * 63 + '$writes',
    };
  }
  if (data is Map<String, dynamic> && data['analysis'] is Map) {
    return {
      ...data,
      'analysis': _bumpVersion(
        (data['analysis'] as Map).cast<String, dynamic>(),
        writes,
      ),
    };
  }
  return data;
}

class _Harness {
  final List<RequestOptions> writes = [];

  /// 有子层委外的父件段已经 notify 过（假后端据此换快照，见 [_pump]）。
  bool subcontractNotified = false;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool childrenAlreadyOrdered = false,
  bool withPurchaseAdjustPermission = true,
  bool soleComponentSubcontract = false,
  bool makeFirstSubcontract = false,
  bool nestedMakeFirstSubcontract = false,
  bool anchoredMakeChild = false,
  void Function(Map<String, dynamic> analysis)? customizeAnalysis,
  Future<void> Function(RequestOptions request)? writeGate,
}) async {
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final harness = _Harness();
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        if (request.method != 'GET') harness.writes.add(request);
        // 写请求闸门（测试用）：挂起指定请求，让「在途」状态可观察——
        // 加载遮罩 / 进度卡这类只在网络段存在的 UI 必须能被这样锁住。
        if (writeGate != null && request.method != 'GET') {
          await writeGate(request);
        }
        // 最小状态机：notify 成功之后快照要真的换一版（多出前置自制锚点行）。
        // 不这么做就只能证明「请求发出去了」，证明不了「下达完之后该行落在
        // 哪个桶、车间里有没有对应的任务」——用户反馈 2 的正题恰恰在这里。
        if (makeFirstSubcontract &&
            request.method != 'GET' &&
            request.path.endsWith('/notify')) {
          harness.subcontractNotified = true;
        }
        final analysis = anchoredMakeChild
            ? _anchoredMakeChildAnalysis()
            : nestedMakeFirstSubcontract
            ? _nestedMakeFirstSubcontractAnalysis()
            : makeFirstSubcontract
            ? _makeFirstSubcontractAnalysis(
                afterNotify: harness.subcontractNotified,
              )
            : soleComponentSubcontract
            ? _soleComponentSubcontractAnalysis()
            : _analysis(childrenAlreadyOrdered: childrenAlreadyOrdered);
        customizeAnalysis?.call(analysis);
        final data = switch (request.path) {
          '/master/warehouses/dict' => [
            {'id': 'warehouse-1', 'name': '主仓'},
          ],
          '/production/material-analyses/default-workshops' => [
            for (final goods in ['g-a', 'g-c', 'g-s'])
              {
                'goodsId': goods,
                'departmentId': 'dept-1',
                'departmentName': '一车间',
                'responsibleEmployeeId': 'emp-1',
                'responsibleEmployeeName': '张三',
              },
          ],
          '/production/material-analyses/sales-candidates' => {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          // 已下单子件的下游联动（ADR-081）：B=申请未分解可并入，D=已分解按追加。
          '/production/material-analyses/analysis-1/supply-links' => [
            {
              'materialLineId': 'm-b',
              'route': 'BUY',
              'mode': 'ADJUSTABLE',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'pr-1',
              'documentNo': 'PR-0001',
              'documentItemId': 'pri-1',
              'itemQty': 20,
              'orderedQty': 0,
            },
            {
              'materialLineId': 'm-d',
              'route': 'BUY',
              'mode': 'ORDERED',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'po-2',
              'documentNo': 'PO-0002',
              'documentItemId': 'poi-2',
              'itemQty': 30,
              'orderedQty': 30,
            },
          ],
          // 并入申请调量（V477）：返回最小合法详情即可。
          '/purchase/requests/pr-1/items/pri-1/qty' => {'id': 'pr-1'},
          '/production/material-analyses/analysis-1' => analysis,
          '/production/material-analyses/analysis-1/notify' => analysis,
          '/production/material-analyses/analysis-1/issue-plans' => {
            'analysis': analysis,
            'plans': [
              {'planId': 'plan-1', 'planNo': 'PP-1', 'status': 'DRAFT'},
            ],
          },
          _ => <Object>[],
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            // 真实服务端只有**真的写了东西**才会重建快照（version/fingerprint
            // 换一版）；界面据此判断「这次到底有没有产生下达」。假后端必须照做，
            // 否则每次写都被判成「什么都没发生」（2026-09-15）。
            data: _bumpVersion(data, harness.writes.length),
          ),
        );
      },
    ),
  );
  final api = ApiClient(dio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        purchaseRepositoryProvider.overrideWith(
          (ref, type) => PurchaseRepository(api, type),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentRepositoryProvider.overrideWithValue(_DepartmentRepository()),
        materialAnalysisWarehousePrefsProvider.overrideWith(
          _WarehousePrefs.new,
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionMaterialAnalysisView,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionMaterialAnalysisOverSupply,
          // 「并入已有采购申请」走采购侧 sanctioned 入口
          // （PUT /purchase/requests/{id}/items/{itemId}/qty，要
          // purchase_request:view + purchase_order:decompose）。计划员通常
          // 没有这两个权限——本用例演的是**兼有**采购权限的账号；不给的话
          // 该行按「需采购分解权限」只读展示，见同文件末尾的权限用例。
          if (withPurchaseAdjustPermission) ...[
            Perm.purchaseRequestView,
            Perm.purchaseOrderDecompose,
          ],
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: 'analysis-1',
            warehouseId: 'warehouse-1',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  harness.writes.clear();
  return harness;
}

class _DepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WarehousePrefs extends MaterialAnalysisWarehousePrefsNotifier {
  @override
  MaterialAnalysisWarehousePrefs build() =>
      const MaterialAnalysisWarehousePrefs();
  @override
  Future<void> syncNow() async {}
  @override
  void update(MaterialAnalysisWarehousePrefs value) {
    state = value.normalized();
  }
}

/// V581 变体：成品A 改成「只有一个叶子子件」的委外件——树顶走委外下达
/// （notify SUBCONTRACT），那颗子件仍要我方采购出来，所以仍进「跟父件一起办」。
Map<String, dynamic> _soleComponentSubcontractAnalysis() {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  analysis['products'] = [
    {
      ...(analysis['products'] as List).first as Map<String, dynamic>,
      'canSchedule': false,
    },
  ];
  analysis['flatMaterials'] = [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'SUBCONTRACT',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
      subcontractOutboundForm: 'COMPONENT_OUTBOUND',
      actionable: true,
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
    ),
  ];
  return analysis;
}

/// 有自制子层的委外件（ADR-062「先自制、后通知委外」）：成品A 路线为委外，
/// BOM 上还有我方要备的外购件B，且**不是** V581 的单一子件形态，因此服务端
/// notify 时建的是「前置自制任务台账 + SUBCONTRACT_MAKE 分析产品行」。
///
/// [afterNotify] = 父件段提交之后的快照：多出那条锚点产品行，并把它挂回原
/// 物料行（planAnchorAnalysisLineId）。真实服务端就是这么换版本的；不模拟这
/// 一步就永远测不出「下达完委外，车间里有没有对应的已下达」。
Map<String, dynamic> _makeFirstSubcontractAnalysis({
  required bool afterNotify,
}) {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  final product = Map<String, dynamic>.from(
    (analysis['products'] as List).first as Map<String, dynamic>,
  )..['canSchedule'] = false;
  analysis['products'] = [
    product,
    if (afterNotify)
      {
        'analysisLineId': 'sc-make-1',
        'sourceType': 'SUBCONTRACT_MAKE',
        'goodsId': 'g-a',
        'goodsCode': 'A-001',
        'goodsName': '成品A(委外自制)',
        'unitName': '件',
        'requestedQty': 10,
        'remainingQty': 10,
        'readyNowQty': 0,
        'canSchedule': true,
        'sourceRef': '委外自制 2026-09-15 abcd',
      },
  ];
  analysis['flatMaterials'] = [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'SUBCONTRACT',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
      actionable: true,
    )..addAll(
      afterNotify
          ? {
              'planAnchorAnalysisLineId': 'sc-make-1',
              'notifiedTargets': [
                {
                  'target': 'SUBCONTRACT',
                  'documentType': 'SUBCONTRACT_MAKE_TASK',
                  'documentId': 'sc-make-1',
                  'status': 'CREATED',
                  'allocatedQty': 10,
                },
              ],
              // 台账建起来后服务端的有效在途覆盖吃掉这 10，行离开「未下达」。
              'additionalSupplyRecommendedQty': 0,
            }
          : const <String, Object?>{},
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
    ),
  ];
  return analysis;
}

/// 2026-09-16 变体：半成品C 已经建过自制子件任务(锚点 make-c-1)。
///
/// 需求账整块搬到了锚点产品行上，所以物料行 m-c 的 requiredQty 归零
/// (DELEGATED_TO_MAKE_CHILD)。这类行以前一律「本页不下达」，现在按锚点追加。
Map<String, dynamic> _anchoredMakeChildAnalysis() {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  analysis['products'] = [
    ...(analysis['products'] as List),
    {
      'analysisLineId': 'make-c-1',
      'sourceType': 'MAKE_COMPONENT',
      'goodsId': 'g-c',
      'goodsCode': 'C-001',
      'goodsName': '半成品C',
      'unitName': '件',
      'requestedQty': 10,
      'remainingQty': 10,
      'readyNowQty': 0,
      'canSchedule': true,
      'maxSchedulableQty': 10,
      'sourceRef': '自制备料 2026-09-16 abcd',
    },
  ];
  analysis['flatMaterials'] = [
    for (final raw in (analysis['flatMaterials'] as List))
      if ((raw as Map<String, dynamic>)['materialLineId'] == 'm-c')
        Map<String, dynamic>.from(raw)..addAll({
          'planAnchorAnalysisLineId': 'make-c-1',
          // 需求已转交锚点：物料行本身归零。
          'requiredQty': 0,
          'additionalSupplyRecommendedQty': 0,
          'requirementState': 'DELEGATED_TO_MAKE_CHILD',
        })
      else
        raw,
  ];
  return analysis;
}

/// 2026-09-16 变体：**非顶层**的有自制子层委外件。
///
///   成品A (顶层, 自制)
///     └─ 委外件S (depth 1, 委外, 有自制子层)
///          └─ 外购件B (depth 2, 采购, 单件用 2)
///
/// 这类行有生成生产计划权限时改走 issue-plans 的 ARRANGE 段：数量可改、超量
/// 按 V589 跟到委外台账，台账 + 锚点 + 计划同一事务建好，不再需要第二段
/// 「前置自制任务下达车间」。
Map<String, dynamic> _nestedMakeFirstSubcontractAnalysis() {
  final analysis = Map<String, dynamic>.from(
    _analysis(childrenAlreadyOrdered: false),
  );
  analysis['flatMaterials'] = [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
    ),
    _material(
      id: 'm-s',
      name: '委外件S',
      goodsId: 'g-s',
      level: 1,
      nodeKey: 'ns',
      perProductQty: 1,
      requiredQty: 10,
      route: 'SUBCONTRACT',
      actionGroupKey: 'ag-s',
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 2,
      nodeKey: 'ns/nb',
      parentNodeKey: 'ns',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
    ),
  ];
  return analysis;
}

Map<String, dynamic> _analysis({required bool childrenAlreadyOrdered}) => {
  'analysisId': 'analysis-1',
  'status': 'ACTIVE',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'warehouseIds': ['warehouse-1'],
  'allowedActions': [
    'VIEW',
    'CONFIRM_ROUTES',
    'NOTIFY_SUPPLY',
    'GENERATE_PLAN',
    'OVER_SUPPLY',
  ],
  'products': [
    {
      'analysisLineId': 'p1',
      'sourceType': 'STOCK',
      'rootMaterialLineId': 'root-1',
      // 销售订单来源顶层行：2026-09-14 修订二起超量也放行（服务端拆
      // 「订单行 + 公共备货单」两张计划），这里锁住前端不再拦。
      'salesOrderItemId': 'soi-1',
      'salesOrderNo': 'SO-0001',
      'goodsId': 'g-a',
      'goodsCode': 'A-001',
      'goodsName': '成品A',
      'unitName': '件',
      'requestedQty': 10,
      'remainingQty': 10,
      'readyNowQty': 0,
      'canSchedule': true,
      'maxSchedulableQty': 10,
    },
  ],
  'flatMaterials': [
    _material(
      id: 'root-1',
      name: '成品A',
      goodsId: 'g-a',
      level: 0,
      nodeKey: 'root',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      nodeRole: 'ROOT_SUPPLY',
      actionGroupKey: 'ag-root',
    ),
    _material(
      id: 'm-b',
      name: '外购件B',
      goodsId: 'g-b',
      level: 1,
      nodeKey: 'nb',
      perProductQty: 2,
      requiredQty: 20,
      route: 'BUY',
      actionGroupKey: 'ag-b',
      covered: childrenAlreadyOrdered,
    ),
    _material(
      id: 'm-c',
      name: '半成品C',
      goodsId: 'g-c',
      level: 1,
      nodeKey: 'nc',
      perProductQty: 1,
      requiredQty: 10,
      route: 'MAKE',
      actionGroupKey: 'ag-c',
      covered: childrenAlreadyOrdered,
    ),
    _material(
      id: 'm-d',
      name: '外购件D',
      goodsId: 'g-d',
      level: 2,
      nodeKey: 'nc/nd',
      parentNodeKey: 'nc',
      perProductQty: 3,
      requiredQty: 30,
      route: 'BUY',
      actionGroupKey: 'ag-d',
      covered: childrenAlreadyOrdered,
    ),
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _material({
  required String id,
  required String name,
  required String goodsId,
  required int level,
  required String nodeKey,
  required double perProductQty,
  required double requiredQty,
  required String route,
  required String actionGroupKey,
  String? parentNodeKey,
  String nodeRole = 'BOM_COMPONENT',
  bool covered = false,
  String? subcontractOutboundForm,
  bool? actionable,
}) => {
  'subcontractOutboundForm': subcontractOutboundForm,
  'materialLineId': id,
  'analysisLineId': 'p1',
  'nodeRole': nodeRole,
  'nodeKey': nodeKey,
  'parentNodeKey': parentNodeKey,
  'goodsId': goodsId,
  'goodsCode': '$goodsId-code',
  'goodsName': name,
  'unitName': '件',
  'level': level,
  // 服务端口径：根供给行 depth=0 恒 actionable；子件按缺口。
  'actionable': actionable ?? level > 0,
  'actionGroupKey': actionGroupKey,
  'materialKey': goodsId,
  'perProductQty': perProductQty,
  'requiredQty': requiredQty,
  // covered=true 时现货已全覆盖：还可下达 = 0，不该再进下层办齐弹窗。
  'availableQty': covered ? requiredQty : 0,
  'allocatedAvailableQty': covered ? requiredQty : 0,
  'shortageQty': covered ? 0 : requiredQty,
  'demandSupplyGapQty': covered ? 0 : requiredQty,
  // 服务端恒定下发的「还可下达」（= max(0, 缺口 − 有效在途覆盖)），界面以它为
  // 唯一主口径。本夹具没有在途，所以与缺口同值——不带这个字段就只会跑到
  // 真实服务端永不执行的那条回退分支上。
  'additionalSupplyRecommendedQty': covered ? 0 : requiredQty,
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'warehouseBreakdown': <Object>[],
};
