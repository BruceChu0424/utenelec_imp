// 仓库直接发料页 (ADR-131 §5.2, 实现规格 §5.4):
// 袋数↔公斤联动; 同一种料两个出库仓库两行; 领料人默认上一次; 盘点中提示"算到下一期";
// 勾"这批料是上一期漏录的"后出现期间下拉与原因; 失败保留输入、原样重试用同一个请求号。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_issue_page.dart';

import 'workshop_material_test_support.dart';

FakeWorkshopMaterialRepository _repo() => FakeWorkshopMaterialRepository()
  ..settingsResult = const [wmTestWorkshop]
  ..materialsByWorkshop = const {
    'w1': [wmTestPp],
  }
  ..defaultsByWorkshop = const {
    'w1': WmDirectIssueDefaults(
      receiverEmployeeId: 'e1',
      receiverName: '张三',
      receiverCode: 'E001',
    ),
  }
  ..periodsByBin = const {
    'bin1': [
      WmPeriod(
        id: 'p1',
        periodNo: 1,
        startDate: '2026-09-01',
        endDate: '2026-09-27',
        status: 'COUNTING',
      ),
      WmPeriod(id: 'p2', periodNo: 2, startDate: '2026-09-28', status: 'OPEN'),
    ],
  };

TextEditingController _controller(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!;

Future<void> _pickMaterial(WidgetTester tester, String rowId) async {
  final field = find.byKey(ValueKey('wm-line-material-$rowId'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text('PP 颗粒').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('领料人默认上一次, 盘点中提示这批料算到下一期', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    expect(find.byKey(const Key('wm-issue-counting-hint')), findsOneWidget);
    expect(find.text('已开始盘点, 这批料算到下一期'), findsOneWidget);

    await _pickMaterial(tester, 'r1');
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '50');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(1));
    // 没动领料人: 提交的就是该车间上一次的领料人。
    expect(repo.directIssues.single.receiverId, 'e1');
    expect(repo.directIssues.single.workshopId, 'w1');
    expect(repo.directIssues.single.supplement, isNull);
  });

  testWidgets('袋数与公斤联动, 同一种料从两个仓库出就是两行', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    await _pickMaterial(tester, 'r1');
    // 选了料, 出库仓库默认货品归属仓。
    await tester.enterText(find.byKey(const ValueKey('wm-line-bags-r1')), '4');
    await tester.pump();
    expect(_controller(tester, 'wm-line-qty-r1').text, '100');

    // 改公斤反算袋数。
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '60');
    await tester.pump();
    expect(_controller(tester, 'wm-line-bags-r1').text, '2.4');

    // 第二行: 同一种料, 改从原料仓 B 出。
    final addRow = find.text('添加行');
    await tester.ensureVisible(addRow);
    await tester.tap(addRow);
    await tester.pumpAndSettle();
    await _pickMaterial(tester, 'r2');
    final leaf = find.byKey(const ValueKey('wm-line-leaf-r2'));
    await tester.ensureVisible(leaf);
    await tester.tap(leaf);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('原料仓 B').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('wm-line-bags-r2')), '2');
    await tester.pump();
    expect(_controller(tester, 'wm-line-qty-r2').text, '50');

    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(1));
    final lines = repo.directIssues.single.lines;
    expect(lines, hasLength(2));
    expect(lines[0]['leafWarehouseId'], 'leafA');
    expect(lines[0]['qty'], 60);
    expect(lines[0]['bags'], 2.4);
    expect(lines[1]['leafWarehouseId'], 'leafB');
    expect(lines[1]['qty'], 50);
    expect(lines.every((l) => l['goodsId'] == 'pp'), isTrue);
  });

  testWidgets('勾"这批料是上一期漏录的"后出现补到哪一期与原因', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    expect(find.byKey(const Key('wm-issue-supplement-period')), findsNothing);
    final flag = find.byKey(const Key('wm-issue-supplement'));
    await tester.ensureVisible(flag);
    await tester.tap(flag);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wm-issue-supplement-period')), findsOneWidget);
    expect(find.byKey(const Key('wm-issue-supplement-reason')), findsOneWidget);
    // 补录时不再提示"算到下一期"。
    expect(find.byKey(const Key('wm-issue-counting-hint')), findsNothing);

    await _pickMaterial(tester, 'r1');
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '25');
    await tester.pump();
    // 没写原因提交被拦住。
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();
    expect(repo.directIssues, isEmpty);
    expect(find.byKey(const Key('wm-issue-error')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('wm-issue-supplement-reason')),
      '9 月 26 日夜班发的料忘了录',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(1));
    final supplement = repo.directIssues.single.supplement;
    // 只有一期可补 (盘点中那一期), 自动选中。
    expect(supplement?.periodId, 'p1');
    expect(supplement?.reason, '9 月 26 日夜班发的料忘了录');
  });

  testWidgets('失败保留输入, 原样重试用同一个请求号', (tester) async {
    final repo = _repo()
      ..directIssueFailure = ApiException('STOCK_SHORT', '原料仓 A 的 PP 颗粒不够')
      ..directIssueFailuresLeft = 1;
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    await _pickMaterial(tester, 'r1');
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '75');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(find.text('原料仓 A 的 PP 颗粒不够'), findsOneWidget);
    expect(_controller(tester, 'wm-line-qty-r1').text, '75');
    expect(_controller(tester, 'wm-line-bags-r1').text, '3');

    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(2));
    expect(repo.directIssues[1].key, repo.directIssues[0].key);
    // 成功后清空明细, 换新的一行等下一次发料。
    expect(_controller(tester, 'wm-line-qty-r2').text, '');
  });
}
