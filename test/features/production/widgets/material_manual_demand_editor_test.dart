// ADR-130 手工需求单(一个需求编号 + 多个货品)的来源整理与多选落表规则。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/production/widgets/material_manual_demand_editor.dart';

GoodsListItem _goods(String id, {String? colorId, String unitId = 'unit-1'}) =>
    GoodsListItem(
      id: id,
      code: 'C-$id',
      name: '货品 $id',
      colorId: colorId,
      unitId: unitId,
      unitName: '个',
    );

MaterialManualDemandDraft _draft({
  String? sourceType = 'REWORK',
  String sourceRef = 'RW-001',
  String reason = '客诉返工',
  DateTime? date,
  List<MaterialManualDemandLine>? lines,
}) => MaterialManualDemandDraft(
  sourceType: sourceType,
  sourceRef: sourceRef,
  reason: reason,
  date: date,
  lines: lines,
);

void main() {
  group('buildMaterialManualDemandSources', () {
    test('one demand number carries many goods lines as one source each', () {
      final draft = _draft(
        sourceRef: '  RW-001 ',
        reason: ' 客诉返工 ',
        date: DateTime(2026, 10, 3),
        lines: [
          MaterialManualDemandLine(goods: _goods('g1'), qty: '5'),
          MaterialManualDemandLine(),
          MaterialManualDemandLine(
            goods: _goods('g2', colorId: 'red'),
            qty: '2.5',
            needDate: DateTime(2026, 9, 30),
          ),
          MaterialManualDemandLine(goods: _goods('g3'), qty: '1'),
        ],
      );
      addTearDown(draft.dispose);
      final result = buildMaterialManualDemandSources([
        draft,
      ], defaultDeliveryDate: DateTime(2026, 12, 31));
      expect(result.isValid, isTrue);
      expect(result.sources.map((source) => source.toJson()).toList(), [
        {
          'sourceType': 'REWORK',
          'sourceRef': 'RW-001',
          'goodsId': 'g1',
          'unitId': 'unit-1',
          'requestedQty': 5.0,
          'sourceReason': '客诉返工',
          'deliveryDate': '2026-10-03',
        },
        {
          'sourceType': 'REWORK',
          'sourceRef': 'RW-001',
          'goodsId': 'g2',
          'colorId': 'red',
          'unitId': 'unit-1',
          'requestedQty': 2.5,
          'sourceReason': '客诉返工',
          'deliveryDate': '2026-09-30',
        },
        {
          'sourceType': 'REWORK',
          'sourceRef': 'RW-001',
          'goodsId': 'g3',
          'unitId': 'unit-1',
          'requestedQty': 1.0,
          'sourceReason': '客诉返工',
          'deliveryDate': '2026-10-03',
        },
      ]);
    });

    test('line date falls back to the header date, then the page default', () {
      final draft = _draft(
        lines: [MaterialManualDemandLine(goods: _goods('g1'), qty: '1')],
      );
      addTearDown(draft.dispose);
      expect(
        buildMaterialManualDemandSources(
          [draft],
          defaultDeliveryDate: DateTime(2026, 11, 2),
        ).sources.single.deliveryDate,
        '2026-11-02',
      );
      expect(
        buildMaterialManualDemandSources([draft]).sources.single.deliveryDate,
        isNull,
      );
    });

    test('untouched blank card is ignored; sales-only analysis is valid', () {
      final blank = MaterialManualDemandDraft();
      addTearDown(blank.dispose);
      final result = buildMaterialManualDemandSources([
        blank,
      ], otherSourceCount: 2);
      expect(result.isValid, isTrue);
      expect(result.sources, isEmpty);
    });

    test('nothing entered anywhere asks the planner to pick something', () {
      final blank = MaterialManualDemandDraft();
      addTearDown(blank.dispose);
      final result = buildMaterialManualDemandSources([blank]);
      expect(result.isValid, isFalse);
      expect(result.error, '请先勾选销售订单产品，或在「手工需求」里选择货品');
      expect(result.draftIndex, isNull);
    });

    test('header without goods is not silently dropped', () {
      final draft = MaterialManualDemandDraft(sourceRef: 'RW-9');
      addTearDown(draft.dispose);
      final result = buildMaterialManualDemandSources([
        draft,
      ], otherSourceCount: 1);
      expect(result.isValid, isFalse);
      expect(result.error, contains('还没有选货品'));
      expect(result.draftIndex, 0);
    });

    test('header fields are validated in plain language', () {
      MaterialManualDemandSourcesResult check(MaterialManualDemandDraft draft) {
        addTearDown(draft.dispose);
        return buildMaterialManualDemandSources([draft]);
      }

      List<MaterialManualDemandLine> oneLine() => [
        MaterialManualDemandLine(goods: _goods('g1'), qty: '1'),
      ];
      expect(
        check(_draft(sourceType: null, lines: oneLine())).error,
        '手工需求单请选择来源类型(返工、试制、样品、备库或其他)',
      );
      expect(
        check(_draft(sourceRef: '   ', lines: oneLine())).error,
        '手工需求单请填写需求编号',
      );
      expect(
        check(_draft(sourceRef: 'R' * 201, lines: oneLine())).error,
        '手工需求单的需求编号不能超过 200 个字符',
      );
      expect(
        check(_draft(reason: ' 返 ', lines: oneLine())).error,
        '手工需求单请填写来源原因(至少 2 个字)',
      );
    });

    test('quantity and goods are required on every entered line', () {
      final missingQty = _draft(
        lines: [
          MaterialManualDemandLine(goods: _goods('g1'), qty: '1'),
          MaterialManualDemandLine(goods: _goods('g2'), qty: '0'),
        ],
      );
      addTearDown(missingQty.dispose);
      final qtyResult = buildMaterialManualDemandSources([missingQty]);
      expect(qtyResult.error, '手工需求单第 2 行「货品 g2」的数量必须大于 0');
      expect(qtyResult.flaggedLines, [missingQty.grid[1]]);

      final missingGoods = _draft(lines: [MaterialManualDemandLine(qty: '3')]);
      addTearDown(missingGoods.dispose);
      expect(
        buildMaterialManualDemandSources([missingGoods]).error,
        '手工需求单第 1 行还没选货品',
      );
    });

    test('the same goods twice under one number must be merged', () {
      final draft = _draft(
        lines: [
          MaterialManualDemandLine(goods: _goods('g1'), qty: '1'),
          MaterialManualDemandLine(goods: _goods('g2'), qty: '1'),
          MaterialManualDemandLine(goods: _goods('g1'), qty: '4'),
        ],
      );
      addTearDown(draft.dispose);
      final result = buildMaterialManualDemandSources([draft]);
      expect(result.error, '手工需求单里「货品 g1」重复了(第 1、3 行)；同一货品请合并成一行');
      expect(result.flaggedLines, [draft.grid[0], draft.grid[2]]);
      // 同一货品不同颜色是两个货品身份，允许并存。
      final colors = _draft(
        lines: [
          MaterialManualDemandLine(goods: _goods('g1'), qty: '1'),
          MaterialManualDemandLine(
            goods: _goods('g1', colorId: 'red'),
            qty: '1',
          ),
        ],
      );
      addTearDown(colors.dispose);
      expect(buildMaterialManualDemandSources([colors]).isValid, isTrue);
    });

    test('one demand number cannot be split across two cards', () {
      final first = _draft(
        lines: [MaterialManualDemandLine(goods: _goods('g1'), qty: '1')],
      );
      final second = _draft(
        sourceRef: ' rw-001 ',
        lines: [MaterialManualDemandLine(goods: _goods('g2'), qty: '1')],
      );
      final otherType = _draft(
        sourceType: 'SAMPLE',
        lines: [MaterialManualDemandLine(goods: _goods('g3'), qty: '1')],
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(otherType.dispose);
      final result = buildMaterialManualDemandSources([first, second]);
      expect(result.error, '第 1 张和第 2 张手工需求单用了同一个需求编号「rw-001」；同一编号的货品请录在同一张单里');
      expect(result.draftIndex, 1);
      // 不同来源类型的同名编号是两份需求。
      expect(
        buildMaterialManualDemandSources([first, otherType]).isValid,
        isTrue,
      );
    });

    test('sales and manual lines share the 500 cap', () {
      final draft = _draft(
        lines: [
          MaterialManualDemandLine(goods: _goods('g1'), qty: '1'),
          MaterialManualDemandLine(goods: _goods('g2'), qty: '1'),
        ],
      );
      addTearDown(draft.dispose);
      expect(
        buildMaterialManualDemandSources([
          draft,
        ], otherSourceCount: 498).isValid,
        isTrue,
      );
      expect(
        buildMaterialManualDemandSources([draft], otherSourceCount: 499).error,
        '单次联合分析最多 500 项(销售订单产品与手工需求合计)，当前 501 项；请拆成多个分析批次',
      );
    });
  });

  group('applyMaterialManualDemandPick', () {
    test(
      'first goods fills the tapped row, the rest fill blanks then append',
      () {
        final draft = MaterialManualDemandDraft(
          lines: [
            MaterialManualDemandLine(),
            MaterialManualDemandLine(goods: _goods('kept'), qty: '1'),
            MaterialManualDemandLine(),
          ],
        );
        addTearDown(draft.dispose);
        final result = applyMaterialManualDemandPick(draft, draft.grid[0], [
          _goods('a'),
          _goods('b'),
          _goods('c'),
        ], remainingSlots: 10);
        expect(result.added, 3);
        expect(draft.grid.rows.map((line) => line.goods?.id).toList(), [
          'a',
          'kept',
          'b',
          'c',
        ]);
      },
    );

    test('goods already in this card are skipped', () {
      final draft = MaterialManualDemandDraft(
        lines: [
          MaterialManualDemandLine(goods: _goods('a'), qty: '1'),
          MaterialManualDemandLine(),
        ],
      );
      addTearDown(draft.dispose);
      final result = applyMaterialManualDemandPick(draft, draft.grid[1], [
        _goods('a'),
        _goods('b'),
      ], remainingSlots: 10);
      expect(result.duplicates, 1);
      expect(result.added, 1);
      expect(draft.grid.rows.map((line) => line.goods?.id).toList(), [
        'a',
        'b',
      ]);
    });

    test('keeps what fits under the cap; replacing a goods costs no slot', () {
      final draft = MaterialManualDemandDraft();
      addTearDown(draft.dispose);
      final capped = applyMaterialManualDemandPick(draft, draft.grid[0], [
        _goods('a'),
        _goods('b'),
        _goods('c'),
      ], remainingSlots: 2);
      expect(capped.added, 2);
      expect(capped.capped, 1);
      expect(draft.grid.length, 2);

      final replaced = applyMaterialManualDemandPick(draft, draft.grid[0], [
        _goods('z'),
      ], remainingSlots: 0);
      expect(replaced.added, 1);
      expect(replaced.capped, 0);
      expect(draft.grid[0].goods?.id, 'z');
    });

    test('a removed target row is ignored', () {
      final draft = MaterialManualDemandDraft();
      final orphan = MaterialManualDemandLine();
      addTearDown(draft.dispose);
      addTearDown(orphan.dispose);
      final result = applyMaterialManualDemandPick(draft, orphan, [
        _goods('a'),
      ], remainingSlots: 10);
      expect(result.added, 0);
      expect(draft.grid[0].goods, isNull);
    });
  });

  test('line date picker starts inside the header date range', () {
    // 单头 2019 年的日期不能让行日期选择器因「初始日期早于可选范围」打不开。
    expect(
      materialManualDemandPickerInitialDate(null, DateTime(2019, 12, 15)),
      materialManualDemandFirstDate,
    );
    expect(
      materialManualDemandPickerInitialDate(DateTime(2101, 3, 5), null),
      materialManualDemandLastDate,
    );
    expect(
      materialManualDemandPickerInitialDate(
        DateTime(2026, 10, 5),
        DateTime(2019, 12, 15),
      ),
      DateTime(2026, 10, 5),
    );
    expect(
      materialManualDemandPickerInitialDate(null, DateTime(2026, 11, 2)),
      DateTime(2026, 11, 2),
    );
    expect(materialManualDemandFirstDate, DateTime(2020));
    expect(materialManualDemandLastDate, DateTime(2100));
  });

  test('cloned lines copy goods, quantity and need date', () {
    final line = MaterialManualDemandLine(
      goods: _goods('a'),
      qty: '3',
      needDate: DateTime(2026, 10, 5),
    );
    final copy = line.clone();
    addTearDown(line.dispose);
    addTearDown(copy.dispose);
    expect(copy.goods?.id, 'a');
    expect(copy.qty.text, '3');
    expect(copy.needDate.value, DateTime(2026, 10, 5));
    expect(identical(copy.qty, line.qty), isFalse);
  });
}
