// 报工页「产出去向」「去向数量」两格(V584/V595/V736, ADR-127)，用真实列定义驱动：
// - 成品行：一个可送的上层工单都没有时写仓库去向摘要，原因放在整格悬停提示里，
//   未分配数量也显示「送入仓库」；候选读取失败仍红字提示刷新，不当成「没有上层工单」；
// - 去向分组收起时，去向格悬停给逐条「去向全名：数量」全文（名称过长在这里看全）；
// - 去向分配子行：下拉按先急后缓列出可送的上层工单(还差 N)，本张报工已分满的置灰「已分满」，
//   结构上是上层但不能收的置灰红字写原因，最后是「送入仓库」；一个都不能送时只读显示「送入仓库」，
//   整格悬停可看原因；原来已选的失效工单保留，并允许人手修改；
// - 货品列的「产出去向」「子件用料」分组头行：两个分组各带展开/收起钮，独立控制。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../../support/audit_screenshot_support.dart';

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
  for (final (themeName, theme) in [
    ('浅色', buildLightTheme()),
    ('深色', buildDarkTheme()),
  ]) {
    testWidgets('$themeName空白输入格显示字段提示，填写后隐藏且不产生假零', (tester) async {
      final product = _product()..allowActualOverproduction = true;
      final allocation = _allocation(product, 'A', '');
      final material = DailyGridRow()
        ..depth = 2
        ..material = ProductionMaterialClearanceRow.fromJson({
          'planId': 'plan',
          'demandId': 'demand',
          'goodsId': 'raw',
          'availableToSettleQty': 20,
        });
      for (final row in [product, allocation, material]) {
        addTearDown(row.dispose);
      }
      final fields = [
        (product, 'qty', '完工申报量', product.qty, '9.9999'),
        (product, 'defectQty', '不良数', product.defectQty, '0.0001'),
        (
          product,
          'overLimitReason',
          '超限原因（超量时必填）',
          product.overLimitReason,
          '当天实际多产',
        ),
        (product, 'remark', '备注', product.remark, '保留手填备注'),
        (
          allocation,
          'allocationQty',
          '去向数量',
          allocation.allocationQty,
          '4.5001',
        ),
        (material, 'materialUsed', '本次实际用料', material.materialUsed, '6.0001'),
      ];
      final cells = [for (final (row, key, _, _, _) in fields) (row, key)];
      await _pumpNamedCells(tester, cells, theme);
      for (final (_, _, hint, controller, _) in fields) {
        expect(controller.text, isEmpty, reason: '提示不是默认数量或已填写事实');
        expect(_hintOpacity(tester, hint), 1);
        expect(
          UtenTableCellInputTheme.contains(tester.element(_hintText(hint))),
          isTrue,
        );
        expect(
          tester.widget<Text>(_hintText(hint)).style?.color,
          // 表格宿主使用语义提示色，普通页面的暗色70%提示色不适用于表格。
          theme.colorScheme.onSurfaceVariant,
        );
      }
      for (final (row, key, hint, controller, input) in fields) {
        final field = find.descendant(
          of: find.byKey(ValueKey('test-$key-${identityHashCode(row)}')),
          matching: find.byType(TextField),
        );
        await tester.enterText(field, input);
        await tester.pumpAndSettle();
        expect(controller.text, input);
        expect(_hintOpacity(tester, hint), 0, reason: '已有输入时提示自然隐藏');
      }
      await _pumpNamedCells(tester, cells, theme);
      for (final (_, _, hint, controller, input) in fields) {
        expect(controller.text, input, reason: '单元格重建保留原文与四位小数');
        expect(_hintOpacity(tester, hint), 0);
        controller.clear();
      }
      await tester.pumpAndSettle();
      for (final (_, _, hint, controller, _) in fields) {
        expect(controller.text, isEmpty);
        expect(_hintOpacity(tester, hint), 1);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('已有建议和手填值保留原文、提示不替换数值或建议状态', (tester) async {
    final product = _product()..qty.text = '9999999999999.9999';
    final allocation = _allocation(product, 'A', '4.5001')
      ..allocationAutofilled.value = true;
    final material = DailyGridRow()
      ..depth = 2
      ..material = ProductionMaterialClearanceRow.fromJson({
        'planId': 'plan',
        'demandId': 'demand',
        'goodsId': 'raw',
        'availableToSettleQty': 10,
      })
      ..materialUsed.text = '6.0001'
      ..materialUsageAutofilled.value = true;
    for (final row in [product, allocation, material]) {
      addTearDown(row.dispose);
    }
    await _pumpNamedCells(tester, [
      (product, 'qty'),
      (allocation, 'allocationQty'),
      (material, 'materialUsed'),
    ], buildLightTheme());
    expect(product.qty.text, '9999999999999.9999');
    expect(allocation.allocationQty.text, '4.5001');
    expect(material.materialUsed.text, '6.0001');
    expect(allocation.allocationAutofilled.value, isTrue);
    expect(material.materialUsageAutofilled.value, isTrue);
    for (final hint in ['完工申报量', '去向数量', '本次实际用料']) {
      expect(_hintOpacity(tester, hint), 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('空选择格显示货品和来源字段名，选定后展示真实值', (tester) async {
    final row = DailyGridRow();
    addTearDown(row.dispose);
    final theme = buildLightTheme();
    await _pumpNamedCells(tester, [(row, 'goods'), (row, 'planNo')], theme);
    for (final hint in ['货品名称', '来源子任务']) {
      expect(find.text(hint), findsOneWidget);
      expect(
        tester.widget<Text>(find.text(hint)).style?.color,
        theme.colorScheme.onSurfaceVariant,
      );
    }
    row.goods = const GoodsOption(id: 'goods', name: '真实货品');
    row.executionSegmentCode = 'ZX-原工单';
    row.planNo.text = 'SJ-原计划';
    await tester.pumpAndSettle();
    expect(find.text('货品名称'), findsNothing);
    expect(find.text('来源子任务'), findsNothing);
    expect(find.text('真实货品'), findsOneWidget);
    expect(find.text('ZX-原工单'), findsOneWidget);
    expect(row.planNo.text, 'SJ-原计划');
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets('真实报工表格选择格保持触控规格并自然放大 $platform $textScale', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 375 : 1400,
          900,
        );
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await loadAuditScreenshotFonts(tester);
        final row = DailyGridRow();
        final controller = UtenEditableGridController<DailyGridRow>(
          initial: [row],
        );
        addTearDown(controller.dispose);
        final theme = auditScreenshotTheme(
          buildLightTheme(),
        ).copyWith(platform: platform);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => SingleChildScrollView(
                    child: UtenEditableGrid<DailyGridRow>(
                      controller: controller,
                      columns:
                          dailyGridColumns(
                                context: context,
                                onPickGoods: (_) async {},
                                onPickSource: (_) async {},
                                onClearSource: (_) {},
                                colorEntries: const {},
                                unitEntries: const {},
                                standaloneDetails: true,
                              )
                              .where((c) => ['goods', 'planNo'].contains(c.key))
                              .toList(),
                      showAddRow: false,
                      showRowDelete: false,
                      showColumnSettings: false,
                      stickyHeader: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Finder inputOf(String text) => find
            .ancestor(
              of: find.text(text),
              matching: find.byType(InputDecorator),
            )
            .first;
        final goodsInput = inputOf('货品名称');
        final goodsPlaceholder = find.descendant(
          of: goodsInput,
          matching: find.text('货品名称'),
        );
        expect(goodsPlaceholder, findsOneWidget);
        final sourceButton = find.ancestor(
          of: find.text('来源子任务'),
          matching: find.byWidgetPredicate((widget) => widget is TextButton),
        );
        expect(sourceButton, findsOneWidget);
        expect(
          find.descendant(of: sourceButton, matching: find.text('来源子任务')),
          findsOneWidget,
        );
        final context = tester.element(goodsPlaceholder);
        expect(UtenTableCellInputTheme.contains(context), isTrue);
        final minimum = platform == TargetPlatform.android ? 48.0 : 32.0;
        expect(UtenEditableGridCellSpec.heightOf(context), minimum);
        final emptyHeight = tester.getSize(goodsInput).height;
        expect(emptyHeight, greaterThanOrEqualTo(minimum));
        if (textScale > 1) expect(emptyHeight, greaterThan(minimum));
        expect(tester.takeException(), isNull);

        row.goods = const GoodsOption(id: 'goods', name: '真实货品');
        row.executionSegmentCode = 'ZX-原工单';
        row.planNo.text = 'SJ-原计划';
        await tester.pumpAndSettle();
        expect(
          find.ancestor(
            of: find.text('货品名称'),
            matching: find.byType(InputDecorator),
          ),
          findsNothing,
        );
        expect(
          find.ancestor(
            of: find.text('来源子任务'),
            matching: find.byWidgetPredicate((widget) => widget is TextButton),
          ),
          findsNothing,
        );
        expect(find.text('真实货品'), findsOneWidget);
        expect(find.text('ZX-原工单'), findsOneWidget);
        expect(row.planNo.text, 'SJ-原计划');
        final selectedHeight = tester.getSize(inputOf('真实货品')).height;
        expect(selectedHeight, greaterThanOrEqualTo(minimum));
        if (textScale > 1) expect(selectedHeight, greaterThan(minimum));
        expect(tester.takeException(), isNull);
      });
    }
  }

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

  testWidgets('去向子行格：下拉收起态 Tooltip 同时保留完整名称和异常原因', (tester) async {
    final product = _product();
    final chosen = _allocation(product, 'A', '4');
    addTearDown(product.dispose);
    addTearDown(chosen.dispose);
    await _pump(tester, [product, chosen]);
    // 收起态只显示单行省略，悬停给当前选中项的全文（含「还差 N」）。
    expect(find.byTooltip('ZX-A · 成品甲 · 还差 6'), findsOneWidget);
    // 送入仓库条目兜底同名文案；有问题时全文与原因同时可见。
    final warehouse = _allocation(product, null, '3');
    addTearDown(warehouse.dispose);
    await _pump(tester, [product, warehouse]);
    expect(find.byTooltip('送入仓库'), findsOneWidget);
    // 有问题时悬停优先给问题（去向格与去向数量格的红框装饰各自带一条，都算数）。
    warehouse.allocationIssue.value = 'ZX-A 最多还能收 6';
    await tester.pump();
    expect(find.byTooltip('ZX-A 最多还能收 6'), findsWidgets);
    expect(find.byTooltip('送入仓库\nZX-A 最多还能收 6'), findsOneWidget);
  });

  testWidgets('产出去向格：去向分组收起时悬停给逐条去向全文', (tester) async {
    final product = _product();
    final direct = _allocation(product, 'A', '4');
    final warehouse = _allocation(product, null, '10');
    addTearDown(product.dispose);
    addTearDown(direct.dispose);
    addTearDown(warehouse.dispose);
    // 收起态子行不在表格里：摘要只有合计数，悬停给逐条「去向全名：数量」。
    await _pump(tester, [product], isGroupExpanded: (row, group) => false);
    expect(find.byTooltip('ZX-A · 成品甲 · 还差 6：4\n送入仓库：10'), findsOneWidget);
    // 展开态回到摘要全文（子行自己另有整格悬停）。
    await _pump(tester, [product], isGroupExpanded: (row, group) => true);
    expect(find.byTooltip('转下一道工序 1 个工单 4 · 送入仓库 10'), findsOneWidget);
    // 没接回调（纯单元格预览）按展开态处理，不因缺状态而丢摘要悬停。
    await _pump(tester, [product]);
    expect(find.byTooltip('转下一道工序 1 个工单 4 · 送入仓库 10'), findsOneWidget);
  });

  testWidgets('分组头：产出去向/子件用料各自独立展开收起，回调带成品行与分组', (tester) async {
    final product = _product();
    final direct = _allocation(product, 'A', '4');
    final warehouse = _allocation(product, null, '10');
    addTearDown(product.dispose);
    addTearDown(direct.dispose);
    addTearDown(warehouse.dispose);

    DailyGridRow header(DailyRowGroup group, int childCount) => DailyGridRow()
      ..depth = 1
      ..groupHeader = group
      ..groupParent = product
      ..groupChildCount = childCount;
    final allocationsHeader = header(DailyRowGroup.allocations, 2);
    final materialsHeader = header(DailyRowGroup.materials, 5);
    addTearDown(allocationsHeader.dispose);
    addTearDown(materialsHeader.dispose);

    // 未接回调（如纯单元格预览）不出可点的展开钮，避免死按钮。
    await _pump(tester, [allocationsHeader, materialsHeader], cells: ['goods']);
    expect(find.byType(IconButton), findsNothing);

    final toggled = <(DailyGridRow, DailyRowGroup)>[];
    // 收起态给「展开产出去向」/「展开子件用料」，两个分组互不影响。
    await _pump(
      tester,
      [allocationsHeader, materialsHeader],
      cells: ['goods'],
      isGroupExpanded: (row, group) => false,
      onToggleGroup: (row, group) => toggled.add((row, group)),
    );
    expect(find.byTooltip('展开产出去向'), findsOneWidget);
    expect(find.byTooltip('展开子件用料'), findsOneWidget);
    await tester.tap(find.byTooltip('展开产出去向'));
    await tester.pump();
    expect(toggled, [(product, DailyRowGroup.allocations)]);
    await tester.tap(find.byTooltip('展开子件用料'));
    await tester.pump();
    expect(toggled, [
      (product, DailyRowGroup.allocations),
      (product, DailyRowGroup.materials),
    ]);

    // 展开态换「收起」文案；两个分组可同时处于展开态。
    toggled.clear();
    await _pump(
      tester,
      [allocationsHeader, materialsHeader],
      cells: ['goods'],
      isGroupExpanded: (row, group) => true,
      onToggleGroup: (row, group) => toggled.add((row, group)),
    );
    expect(find.byTooltip('收起产出去向'), findsOneWidget);
    expect(find.byTooltip('收起子件用料'), findsOneWidget);
    await tester.tap(find.byTooltip('收起子件用料'));
    await tester.pump();
    expect(toggled, [(product, DailyRowGroup.materials)]);
    // 一个分组收起不影响另一个分组保持展开。
    expect(find.byTooltip('收起产出去向'), findsOneWidget);
  });

  testWidgets('去向子行与物料子行的货品格：挂在分组头下的第二层树格', (tester) async {
    final product = _product();
    final direct = _allocation(product, 'A', '4');
    addTearDown(product.dispose);
    addTearDown(direct.dispose);
    await _pump(tester, [direct], cells: ['goods']);
    // 分组头已写「产出去向」，子行只标「去向」；标题仍是加粗单行省略口径。
    expect(find.text('去向'), findsOneWidget);
    expect(find.text('产出去向'), findsNothing);
    expect(
      tester.widget<Text>(find.text('去向')).style?.fontWeight,
      FontWeight.w700,
    );
  });

  testWidgets('共享用料只读镜像保留四位小数原文', (tester) async {
    final material = DailyGridRow()
      ..depth = 2
      ..materialOwnsInput = false
      ..material = ProductionMaterialClearanceRow.fromJson({
        'planId': 'plan',
        'demandId': 'demand',
        'goodsId': 'raw',
        'unitName': '个',
        'issuedQty': 1,
        'availableToSettleQty': 1,
      })
      ..materialUsed.text = '0.9999';
    addTearDown(material.dispose);
    await _pump(tester, [material], cells: ['materialUsed']);
    expect(find.text('0.9999 个'), findsOneWidget);
    expect(find.text('1 个'), findsNothing);
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

Finder _hintAnimation(String text) => find.byWidgetPredicate((widget) {
  if (widget is! AnimatedOpacity) return false;
  final child = widget.child;
  return child is Text && (child.data ?? child.textSpan?.toPlainText()) == text;
});

Finder _hintText(String text) =>
    find.descendant(of: _hintAnimation(text), matching: find.text(text));

double _hintOpacity(WidgetTester tester, String text) =>
    tester.widget<AnimatedOpacity>(_hintAnimation(text)).opacity;

Future<void> _pumpNamedCells(
  WidgetTester tester,
  List<(DailyGridRow, String)> cells,
  ThemeData theme,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: UtenTableCellInputTheme(
          child: Builder(
            builder: (cellContext) {
              final columns = dailyGridColumns(
                context: cellContext,
                onPickGoods: (_) async {},
                onPickSource: (_) async {},
                onClearSource: (_) {},
                colorEntries: const {},
                unitEntries: const {},
              );
              return Column(
                children: [
                  for (final (row, key) in cells)
                    SizedBox(
                      key: ValueKey('test-$key-${identityHashCode(row)}'),
                      width: 350,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: UtenEditableGridCellSpec.heightOf(
                            cellContext,
                          ),
                        ),
                        child: columns
                            .firstWhere((column) => column.key == key)
                            .cellBuilder(cellContext, row),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<List<String>> _pump(
  WidgetTester tester,
  List<DailyGridRow> rows, {
  void Function(DailyGridRow row, String? demand)? onDestinationChanged,
  void Function(DailyGridRow row)? onQtyChanged,
  bool Function(DailyGridRow product, DailyRowGroup group)? isGroupExpanded,
  void Function(DailyGridRow product, DailyRowGroup group)? onToggleGroup,
  List<String> cells = const ['destination', 'allocationQty'],
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
              isGroupExpanded: isGroupExpanded,
              onToggleGroup: onToggleGroup,
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
                for (final row in rows)
                  for (final key in cells) cell(key, row),
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
