// 报工页「产出去向」「去向数量」两格(V584/V595/V736, ADR-127)，用真实列定义驱动：
// - 成品行：一个可送的上层工单都没有时写仓库去向摘要，原因放在整格悬停提示里，
//   未分配数量也显示「送入仓库」；候选读取失败仍红字提示刷新，不当成「没有上层工单」；
// - 去向分配子行：下拉按先急后缓列出可送的上层工单(还差 N)，本张报工已分满的置灰「已分满」，
//   结构上是上层但不能收的置灰红字写原因，最后是「送入仓库」；一个都不能送时只读显示「送入仓库」，
//   整格悬停可看原因；原来已选的失效工单保留，并允许人手修改。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';

const _subcontractReason = 'HV5ZJ012 是委外件：做好后先送入仓库，发外加工回来后，上层工单再从仓库领料';
const _crossReason = '上层工单 ZX-C 在二车间，跨车间必须送入仓库';

DailyGridRow _product() => DailyGridRow()
  ..executionSegmentId = 'segment'
  ..directTransferCandidates = const [
    ProductionDirectTransferCandidate(
      demandId: 'A',
      executionSegmentId: 'segment-a',
      executionSegmentCode: 'ZX-A',
      receivingGoodsName: '成品甲',
      remainingQty: 6,
    ),
    ProductionDirectTransferCandidate(
      demandId: 'B',
      executionSegmentId: 'segment-b',
      executionSegmentCode: 'ZX-B',
      receivingGoodsName: '成品乙',
      remainingQty: 3,
    ),
  ]
  ..directTransferBlockedTargets = const [
    ProductionDirectTransferBlockedTarget(
      demandId: 'C',
      executionSegmentCode: 'ZX-C',
      reasonCode: 'DIFFERENT_WORKSHOP',
      reason: _crossReason,
    ),
  ]
  ..directTransferRoomBase = const {'A': 6, 'B': 0};

DailyGridRow _allocation(DailyGridRow product, String? demand, String qty) {
  final row = DailyGridRow()
    ..depth = 1
    ..allocationParent = product
    ..allocationDemandId = demand;
  row.allocationQty.text = qty;
  product.allocationRows = [...product.allocationRows, row];
  return row;
}

void main() {
  test('去向下拉：先急后缓的上层工单、已分满置灰、不能收的红字原因、最后是送入仓库', () {
    final product = _product();
    final warehouse = _allocation(product, null, '10');
    addTearDown(product.dispose);
    addTearDown(warehouse.dispose);
    final options = outputAllocationOptions(warehouse);
    expect(options.map((item) => item.value), [
      'A',
      'B',
      'C',
      outputAllocationWarehouseValue,
    ]);
    expect(options[0].label, 'ZX-A · 成品甲 · 还差 6');
    expect(options[0].enabled, isTrue);
    expect(options[1].label, 'ZX-B · 成品乙 · 已分满');
    expect(options[1].enabled, isFalse, reason: '本张报工其它行已把它分满');
    expect(options[2].enabled, isFalse);
    expect(options[2].error, isTrue);
    expect(options[2].label, 'ZX-C · $_crossReason');
    expect(options[3].label, '送入仓库');
    // 同一行的另一条去向已分给 A：不能再选一次。
    final first = _allocation(product, 'A', '4');
    addTearDown(first.dispose);
    expect(outputAllocationOptions(warehouse).first.enabled, isFalse);
    expect(outputAllocationOptions(warehouse).first.label, endsWith('本行已分给它'));
    expect(outputAllocationSummary(product), '转下一道工序 1 个工单 4 · 送入仓库 10');
    expect(showsOutputAllocations(product), isTrue);
    // 只有一条送入仓库、也没有可送的上层工单：不另占一行，成品行写摘要。
    final top = DailyGridRow();
    final only = _allocation(top, null, '10');
    addTearDown(top.dispose);
    addTearDown(only.dispose);
    expect(showsOutputAllocations(top), isFalse);
    expect(outputAllocationSummary(top), '送入仓库 10');
  });

  testWidgets('选一个上层工单：回调带上它的需求', (tester) async {
    final product = _product();
    final warehouse = _allocation(product, null, '10');
    addTearDown(product.dispose);
    addTearDown(warehouse.dispose);
    final picked = <String?>[];
    await _pump(tester, [
      product,
      warehouse,
    ], onDestinationChanged: (_, demand) => picked.add(demand));
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    expect(
      find.text('ZX-C · $_crossReason'),
      findsOneWidget,
      reason: '不能收的也列出来并写原因',
    );
    await tester.tap(find.text('ZX-A · 成品甲 · 还差 6').last);
    await tester.pumpAndSettle();
    expect(picked, ['A']);
  });

  testWidgets('一个都不能送：只读显示仓库去向，整格悬停才展示服务端原因', (tester) async {
    final result = DirectTransferCandidatesResult.fromJson(const {
      'candidates': <dynamic>[],
      'unavailableReasonCode': 'SUBCONTRACT_ROUTE',
      'unavailableReason': _subcontractReason,
    });
    final product = DailyGridRow()
      ..directTransferCandidates = result.candidates
      ..directTransferBlockedText = result.blockedText
      ..directTransferLoadFailed = result.loadFailed;
    final warehouse = _allocation(product, null, '10');
    addTearDown(product.dispose);
    addTearDown(warehouse.dispose);
    final picked = <String?>[];
    final columnTexts = await _pump(tester, [
      product,
      warehouse,
    ], onDestinationChanged: (_, demand) => picked.add(demand));

    expect(
      find.byType(UtenDropdownField),
      findsNothing,
      reason: '不能转时不给下拉，只能送入仓库',
    );
    expect(columnTexts, ['送入仓库 10', '送入仓库'], reason: '列测宽与复制使用去向摘要');
    expect(find.text('送入仓库 10'), findsOneWidget);
    expect(find.text('送入仓库'), findsOneWidget);
    const full = '无法转到下一道工序：$_subcontractReason';
    expect(find.text(full), findsNothing, reason: '日常展示的是去向，不直接展示不可转原因');
    for (final label in ['送入仓库 10', '送入仓库']) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.style?.color, isNot(buildLightTheme().colorScheme.error));
      expect(text.maxLines, 1);
    }
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(790, 590));
    for (final row in [product, warehouse]) {
      final cell = find.byKey(
        ValueKey('test-destination-${identityHashCode(row)}'),
      );
      // 在文字右侧的空白位置悬停，验证提示覆盖整格，而非仅覆盖文字。
      final blank = tester.getTopRight(cell) + const Offset(-4, 20);
      await mouse.moveTo(blank);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(full), findsOneWidget);
      await mouse.moveTo(const Offset(790, 590));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(full), findsNothing);
      await tester.tapAt(blank);
      await tester.pumpAndSettle();
      expect(find.byType(UtenDropdownField), findsNothing);
    }
    expect(picked, isEmpty, reason: '仓库只读单元格不会触发改去向');
    expect(warehouse.allocationDemandId, isNull);
    expect(warehouse.allocationQty.text, '10');
    expect(find.textContaining('无同车间上层工单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一个都不能送且尚未分配数量：成品行和去向子行默认显示送入仓库', (tester) async {
    final product = DailyGridRow()
      ..directTransferBlockedText = '无法转到下一道工序：$_subcontractReason';
    final warehouse = _allocation(product, null, '');
    addTearDown(product.dispose);
    addTearDown(warehouse.dispose);
    final columnTexts = await _pump(tester, [product, warehouse]);

    expect(columnTexts, ['送入仓库', '送入仓库']);
    expect(find.text('送入仓库'), findsNWidgets(2));
    expect(find.text('—'), findsNothing);
    expect(find.textContaining('无法转到下一道工序'), findsNothing);
    expect(find.byType(UtenDropdownField), findsNothing);
    expect(warehouse.allocationQty.text, isEmpty);
  });

  testWidgets('候选读取失败：成品行提示刷新重试，不当成没有上层工单', (tester) async {
    const result = DirectTransferCandidatesResult.loadFailed();
    final product = DailyGridRow()
      ..directTransferCandidates = result.candidates
      ..directTransferBlockedText = result.blockedText
      ..directTransferLoadFailed = result.loadFailed;
    final chosen = _allocation(product, 'A', '4');
    addTearDown(product.dispose);
    addTearDown(chosen.dispose);
    final columnTexts = await _pump(tester, [product, chosen]);

    expect(find.text('转给工单候选读取失败，请刷新后重试'), findsOneWidget);
    final failed = tester.widget<Text>(find.text(directTransferLoadFailedText));
    expect(failed.style?.color, buildLightTheme().colorScheme.error);
    expect(columnTexts.first, directTransferLoadFailedText);
    expect(find.textContaining('无法转到下一道工序'), findsNothing);
    expect(
      find.byType(UtenDropdownField),
      findsOneWidget,
      reason: '已定的去向不锁死、不替人改',
    );
    // 读不到只是暂时核对不了：不能说成「现在不能收」，也不标红。
    expect(find.textContaining('现在不能收'), findsNothing);
    final kept = outputAllocationOptions(
      chosen,
    ).firstWhere((item) => item.value == 'A');
    expect(kept.label, '原来选的上层工单(候选读取失败，暂时无法核对)');
    expect(kept.error, isFalse);
    expect(chosen.allocationDemandId, 'A');
    expect(chosen.allocationQty.text, '4');
  });

  testWidgets('原来选的工单失效：保留原去向与数量，仍可下拉改为送入仓库', (tester) async {
    final product = DailyGridRow()
      ..directTransferBlockedText = '无法转到下一道工序：$_crossReason'
      ..directTransferBlockedTargets = const [
        ProductionDirectTransferBlockedTarget(
          demandId: 'C',
          executionSegmentCode: 'ZX-C',
          reasonCode: 'DIFFERENT_WORKSHOP',
          reason: _crossReason,
        ),
      ];
    final chosen = _allocation(product, 'C', '4');
    addTearDown(product.dispose);
    addTearDown(chosen.dispose);
    final picked = <String?>[];
    final columnTexts = await _pump(tester, [
      product,
      chosen,
    ], onDestinationChanged: (_, demand) => picked.add(demand));

    expect(columnTexts, ['转下一道工序 1 个工单 4', 'ZX-C · $_crossReason']);
    expect(find.text('转下一道工序 1 个工单 4'), findsOneWidget);
    expect(find.text('送入仓库'), findsNothing);
    expect(find.byType(UtenDropdownField), findsOneWidget);
    expect(chosen.allocationDemandId, 'C');
    expect(chosen.allocationQty.text, '4');
    expect(picked, isEmpty, reason: '候选失效不会静默修改去向');
    final kept = outputAllocationOptions(chosen).first;
    expect(kept.value, 'C');
    expect(kept.enabled, isFalse);
    expect(kept.error, isTrue);

    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送入仓库').last);
    await tester.pumpAndSettle();
    expect(picked, [null], reason: '工人仍能明确选择改送仓库');
  });

  testWidgets('去向数量：输入即回调，问题用红框写在格内', (tester) async {
    final product = _product();
    final row = _allocation(product, 'A', '6');
    row.allocationIssue.value = 'ZX-A 最多还能收 6';
    addTearDown(product.dispose);
    addTearDown(row.dispose);
    final changed = <DailyGridRow>[];
    await _pump(tester, [product, row], onQtyChanged: changed.add);
    await tester.enterText(find.byType(TextField), '5');
    await tester.pump();
    expect(changed, [row]);
    expect(row.allocationQty.text, '5');
    expect(find.byTooltip('ZX-A 最多还能收 6'), findsWidgets);
  });

  testWidgets('产出去向格：恒定 Tooltip 悬停给全文（摘要/兜底「—」/已审核行）', (tester) async {
    final product = _product();
    final direct = _allocation(product, 'A', '4');
    final warehouse = _allocation(product, null, '10');
    addTearDown(product.dispose);
    addTearDown(direct.dispose);
    addTearDown(warehouse.dispose);
    await _pump(tester, [product]);

    // 摘要被单行省略截断时，悬停提示给完整摘要（恒定包裹，不按内容切换）。
    expect(find.byTooltip('转下一道工序 1 个工单 4 · 送入仓库 10'), findsOneWidget);
    // 空去向格显示「—」，悬停兜底文案与显示一致，不给空 Tooltip。
    final empty = DailyGridRow();
    addTearDown(empty.dispose);
    await _pump(tester, [empty]);
    expect(find.text('—'), findsOneWidget);
    expect(find.byTooltip('—'), findsOneWidget);
    // 已审核行(只读回看)同样恒定悬停全文。
    final accepted = DailyGridRow()
      ..acceptedDestinationLabel = '转下一道工序 · 成品甲 ZX-A';
    addTearDown(accepted.dispose);
    await _pump(tester, [accepted]);
    expect(find.byTooltip('转下一道工序 · 成品甲 ZX-A'), findsOneWidget);
  });

  testWidgets('去向子行格：下拉收起态恒定 Tooltip 给选中项全文，红字问题优先', (tester) async {
    final product = _product();
    final chosen = _allocation(product, 'A', '4');
    addTearDown(product.dispose);
    addTearDown(chosen.dispose);
    await _pump(tester, [product, chosen]);
    // 收起态只显示单行省略，悬停给当前选中项的全文（含「还差 N」）。
    expect(find.byTooltip('ZX-A · 成品甲 · 还差 6'), findsOneWidget);
    // 送入仓库条目兜底同名文案；有问题时悬停优先给问题。
    final warehouse = _allocation(product, null, '3');
    addTearDown(warehouse.dispose);
    await _pump(tester, [product, warehouse]);
    expect(find.byTooltip('送入仓库'), findsOneWidget);
    // 有问题时悬停优先给问题（去向格与去向数量格的红框装饰各自带一条，都算数）。
    warehouse.allocationIssue.value = 'ZX-A 最多还能收 6';
    await tester.pump();
    expect(find.byTooltip('ZX-A 最多还能收 6'), findsWidgets);
  });

  testWidgets('产出去向格：编辑态收起给展开/收起切换钮，点击回调带成品行', (tester) async {
    final product = _product();
    final direct = _allocation(product, 'A', '4');
    final warehouse = _allocation(product, null, '10');
    addTearDown(product.dispose);
    addTearDown(direct.dispose);
    addTearDown(warehouse.dispose);

    // 未接回调（如纯单元格预览）不出切换钮，避免死按钮。
    await _pump(tester, [product]);
    expect(find.byTooltip('展开去向明细'), findsNothing);
    expect(find.byTooltip('收起去向明细'), findsNothing);

    // 收起态给「展开去向明细」，展开态给「收起去向明细」；图标随展开态翻转。
    DailyGridRow? toggled;
    await _pump(
      tester,
      [product],
      allocationsExpanded: (row) => false,
      onToggleAllocations: (row) => toggled = row,
    );
    expect(find.byTooltip('展开去向明细'), findsOneWidget);
    await tester.tap(find.byTooltip('展开去向明细'));
    await tester.pump();
    expect(toggled, same(product));

    await _pump(
      tester,
      [product],
      allocationsExpanded: (row) => true,
      onToggleAllocations: (row) => toggled = row,
    );
    expect(find.byTooltip('收起去向明细'), findsOneWidget);
    await tester.tap(find.byTooltip('收起去向明细'));
    await tester.pump();
    expect(toggled, same(product));

    // 只有一条「送入仓库」、没有可送工单的行不占子行，也就没有切换钮。
    final top = DailyGridRow();
    final only = _allocation(top, null, '10');
    addTearDown(top.dispose);
    addTearDown(only.dispose);
    await _pump(
      tester,
      [top],
      allocationsExpanded: (row) => true,
      onToggleAllocations: (row) => toggled = row,
    );
    expect(find.byTooltip('收起去向明细'), findsNothing);
  });

  test('已存草稿按批次还原成一行报工和它的固定去向', () {
    final items = [
      for (final (id, destination, demand, qty) in [
        ('i1', 'WORKSHOP', 'A', 1000.0),
        ('i2', 'WORKSHOP', 'B', 1000.0),
        ('i3', 'WAREHOUSE', null, 8000.0),
      ])
        <String, dynamic>{
          'id': id,
          'goodsId': 'g',
          'unitId': 'u',
          'unitRate': 1,
          'planItemId': 'p',
          'executionSegmentId': 's',
          'qty': qty,
          'outputBatchId': 'batch',
          'outputBatchQty': 10000,
          'destination': destination,
          'directTransferDemandId': demand,
          'directTransferTargetLabel': demand == null
              ? null
              : '成品 · ZX-$demand',
          if (demand == null) 'outputRouteReasonText': '能直送的上层工单都已分满，其余送入仓库',
        },
    ];
    // ADR-148：批次分组由服务端给(outputBatches)，页面按 itemIds 合回一行。
    final group = ProductionDailyReportDetail.fromJson({
      'id': 'report',
      'items': items,
      'outputBatches': [
        {
          'batchKey': 'batch',
          'itemIds': ['i1', 'i2', 'i3'],
          'qty': 10000,
          'summary': '本行产出 共 10000',
        },
      ],
    }).inputGroups.single;
    expect(group.qty, 10000);
    expect(group.allocations, [
      {'directTransferDemandId': 'A', 'qty': 1000.0},
      {'directTransferDemandId': 'B', 'qty': 1000.0},
      {'directTransferDemandId': null, 'qty': 8000.0},
    ]);
    final product = DailyGridRow();
    addTearDown(product.dispose);
    restoreOutputAllocations(product, group.allocations);
    expect(product.allocationRows.map((row) => row.allocationDemandId), [
      'A',
      'B',
      null,
    ]);
    expect(
      product.allocationRows.every((row) => row.allocationFixed),
      isTrue,
      reason: '草稿里的去向是工人的选择，候选到了也不替换',
    );
    expect(product.allocationRows.map((row) => row.allocationQty.text), [
      '1000',
      '1000',
      '8000',
    ]);
    expect(outputAllocationBody(product), [
      {'directTransferDemandId': 'A', 'qty': 1000.0},
      {'directTransferDemandId': 'B', 'qty': 1000.0},
      {'directTransferDemandId': null, 'qty': 8000.0},
    ]);
    for (final row in product.allocationRows) {
      addTearDown(row.dispose);
    }
  });
}

Future<List<String>> _pump(
  WidgetTester tester,
  List<DailyGridRow> rows, {
  void Function(DailyGridRow row, String? demand)? onDestinationChanged,
  void Function(DailyGridRow row)? onQtyChanged,
  bool Function(DailyGridRow product)? allocationsExpanded,
  void Function(DailyGridRow product)? onToggleAllocations,
}) async {
  var destinationTexts = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            final columns = dailyGridColumns(
              context: context,
              onPickGoods: (_) async {},
              onPickSource: (_) async {},
              onClearSource: (_) {},
              colorEntries: const {},
              unitEntries: const {},
              onAllocationDestinationChanged: onDestinationChanged,
              onAllocationQtyChanged: onQtyChanged,
              allocationsExpanded: allocationsExpanded,
              onToggleAllocations: onToggleAllocations,
            );
            final destination = columns.firstWhere(
              (column) => column.key == 'destination',
            );
            destinationTexts = [
              for (final row in rows) destination.textOf!(row),
            ];
            Widget cell(String key, DailyGridRow row) => SizedBox(
              key: ValueKey('test-$key-${identityHashCode(row)}'),
              width: 300,
              height: 40,
              child: columns
                  .firstWhere((column) => column.key == key)
                  .cellBuilder(context, row),
            );
            return Column(
              children: [
                for (final row in rows) ...[
                  cell('destination', row),
                  cell('allocationQty', row),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return destinationTexts;
}
