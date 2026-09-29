// 报工页「产出去向」「去向数量」两格(V584/V595/V736, ADR-127)，用真实列定义驱动：
// - 成品行：一个可送的上层工单都没有时红字写「无法转到下一道工序：<服务端原因>」(整句在悬停提示)，
//   否则写本行去向摘要；候选读取失败红字提示刷新，不当成「没有上层工单」；
// - 去向分配子行：下拉按先急后缓列出可送的上层工单(还差 N)，本张报工已分满的置灰「已分满」，
//   结构上是上层但不能收的置灰红字写原因，最后是「送入仓库」；一个都不能送时只显示「送入仓库」。
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
    // 只有一条送入仓库、也没有可送的上层工单：不另占一行，成品行写摘要或红字。
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

  testWidgets('一个都不能送：成品行红字写明服务端原因，去向子行只显示送入仓库', (tester) async {
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
    await _pump(tester, [product, warehouse]);

    expect(
      find.byType(UtenDropdownField),
      findsNothing,
      reason: '不能转时不给下拉，只能送入仓库',
    );
    expect(find.text('送入仓库'), findsOneWidget);
    const full = '无法转到下一道工序：$_subcontractReason';
    final red = tester.widget<Text>(find.text(full));
    expect(red.style?.color, buildLightTheme().colorScheme.error);
    expect(red.maxLines, 1);
    expect(find.byTooltip(full), findsOneWidget, reason: '整句放悬停提示，防截断');
    expect(find.textContaining('无同车间上层工单'), findsNothing);
    expect(tester.takeException(), isNull);
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
    await _pump(tester, [product, chosen]);

    expect(find.text('转给工单候选读取失败，请刷新后重试'), findsOneWidget);
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

  test('已存草稿按批次还原成一行报工和它的固定去向', () {
    final items = [
      for (final (id, destination, demand, qty) in [
        ('i1', 'WORKSHOP', 'A', 1000.0),
        ('i2', 'WORKSHOP', 'B', 1000.0),
        ('i3', 'WAREHOUSE', null, 8000.0),
      ])
        ProductionDailyReportItem.fromJson({
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
        }),
    ];
    final group = productionDailyReportInputGroups(items).single;
    expect(group.qty, 10000);
    expect(group.allocations, [
      {'directTransferDemandId': 'A', 'qty': 1000.0},
      {'directTransferDemandId': 'B', 'qty': 1000.0},
      {'directTransferDemandId': null, 'qty': 8000.0},
    ]);
    expect(
      group.routeSummary,
      '本行产出 共 10000：转给 成品 · ZX-A 1000；转给 成品 · ZX-B 1000；'
      '送入仓库 8000 (能直送的上层工单都已分满，其余送入仓库)',
    );
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

Future<void> _pump(
  WidgetTester tester,
  List<DailyGridRow> rows, {
  void Function(DailyGridRow row, String? demand)? onDestinationChanged,
  void Function(DailyGridRow row)? onQtyChanged,
}) async {
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
            );
            Widget cell(String key, DailyGridRow row) => SizedBox(
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
}
