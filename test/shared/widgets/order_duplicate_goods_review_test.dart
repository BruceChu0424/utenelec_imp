// 重复货品复核（销售/采购/委外订货编辑页共用）：
//  - collectDuplicateGoodsGroups：同键 ≥2 行成组、组序/组内序稳定、identical 签名；
//  - showDuplicateGoodsReviewDialog：三选一按钮与返回值；数量/单价不同的组
//    不提供「删除重复行」（删行=丢数据）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/order_duplicate_goods_review.dart';

class _Row {
  _Row(this.key, this.qty, this.price);

  final String key;
  final String qty;
  final String price;
}

DuplicateGoodsGroup<_Row> _group(List<_Row> rows) => DuplicateGoodsGroup<_Row>(
  rows: rows,
  identityLabel: '货品A',
  rowSummaries: [
    for (var i = 0; i < rows.length; i++) '第 ${i + 1} 行 · 数量 ${rows[i].qty}',
  ],
  identical: rows.map((r) => '${r.qty}|${r.price}').toSet().length == 1,
);

/// 弹窗结果持有器：_pumpDialog 只负责打开弹窗，按钮点击后的返回值写进
/// [value] 供用例读取（避免「返回快照早于点击」的时序坑）。
class _DialogResult {
  DuplicateGoodsReviewAction? value = DuplicateGoodsReviewAction.back;
}

Future<_DialogResult> _pumpDialog(
  WidgetTester tester,
  List<DuplicateGoodsGroup<_Row>> groups,
) async {
  final holder = _DialogResult();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                holder.value = await showDuplicateGoodsReviewDialog<_Row>(
                  context,
                  groups: groups,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return holder;
}

void main() {
  group('collectDuplicateGoodsGroups', () {
    test('同键 ≥2 行成组；单行不成组；组序与组内行序保持明细原顺序', () {
      final a1 = _Row('A', '10', '3.5');
      final b1 = _Row('B', '5', '2');
      final a2 = _Row('A', '6', '3.5');
      final c1 = _Row('C', '1', '9');
      final groups = collectDuplicateGoodsGroups<_Row>(
        rows: [a1, b1, a2, c1],
        rowNoOf: (r) => [a1, b1, a2, c1].indexOf(r) + 1,
        groupKey: (r) => r.key,
        identityLabel: (r) => '货品${r.key}',
        rowSummary: (r, rowNo) => '第 $rowNo 行 · 数量 ${r.qty}',
        identicalSignature: (r) => '${r.qty}|${r.price}',
      );

      expect(groups, hasLength(1));
      expect(groups.single.rows, [a1, a2]);
      expect(groups.single.identityLabel, '货品A');
      expect(groups.single.rowSummaries, ['第 1 行 · 数量 10', '第 3 行 · 数量 6']);
      // 数量不同 → 不完全一致。
      expect(groups.single.identical, isFalse);
    });

    test('各键独立成组且组间顺序按首现行位置', () {
      final rows = [
        _Row('A', '1', '2'),
        _Row('B', '1', '2'),
        _Row('A', '1', '2'),
        _Row('B', '1', '2'),
      ];
      final groups = collectDuplicateGoodsGroups<_Row>(
        rows: rows,
        rowNoOf: (r) => rows.indexOf(r) + 1,
        groupKey: (r) => r.key,
        identityLabel: (r) => r.key,
        rowSummary: (r, rowNo) => '$rowNo',
        identicalSignature: (r) => '${r.qty}|${r.price}',
      );

      expect(groups.map((g) => g.identityLabel), ['A', 'B']);
      expect(groups.every((g) => g.identical), isTrue);
    });
  });

  testWidgets('完全一致的组：三个按钮，删除重复行返回 dedupe', (tester) async {
    final result = await _pumpDialog(tester, [
      _group([_Row('A', '5', '3.5'), _Row('A', '5', '3.5')]),
    ]);
    // result 是持有器：点击动作后从 value 读弹窗返回值。

    expect(find.text('发现重复货品'), findsOneWidget);
    expect(find.textContaining('以下货品在明细中出现了多行'), findsOneWidget);
    expect(find.text('各行内容完全一致'), findsOneWidget);
    expect(find.text('返回修改'), findsOneWidget);
    expect(find.text('删除重复行'), findsOneWidget);
    expect(find.text('汇总合并'), findsOneWidget);

    await tester.tap(find.text('删除重复行'));
    await tester.pumpAndSettle();
    expect(result.value, DuplicateGoodsReviewAction.dedupe);
  });

  testWidgets('完全一致的组：汇总合并返回 merge', (tester) async {
    final result = await _pumpDialog(tester, [
      _group([_Row('A', '5', '3.5'), _Row('A', '5', '3.5')]),
    ]);

    await tester.tap(find.text('汇总合并'));
    await tester.pumpAndSettle();
    expect(result.value, DuplicateGoodsReviewAction.merge);
  });

  testWidgets('数量不同的组：不提供删除重复行；返回修改返回 back', (tester) async {
    final result = await _pumpDialog(tester, [
      _group([_Row('A', '10', '3.5'), _Row('A', '5', '3.5')]),
    ]);

    expect(find.text('删除重复行'), findsNothing);
    expect(find.textContaining('各行数量或单价不同'), findsOneWidget);

    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    expect(result.value, DuplicateGoodsReviewAction.back);
  });

  testWidgets('多组且任一组不一致：整窗不提供删除重复行', (tester) async {
    await _pumpDialog(tester, [
      _group([_Row('A', '5', '3.5'), _Row('A', '5', '3.5')]),
      _group([_Row('B', '1', '2'), _Row('B', '3', '2')]),
    ]);

    expect(find.text('发现 2 组重复货品'), findsOneWidget);
    expect(find.text('删除重复行'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
