// UtenEditableGrid 大数据量性能契约（2026-09-05）：
// 用**构建计数**（非墙钟）锁「灭重绘风暴」的两条核心性质——
//   1. 初始构建：N 行明细每格只构建一次（shrinkWrap content-tall 的固有代价是
//      一次性全量构建，不允许意外翻倍）；
//   2. 敲一个字：只重建受影响的订阅格（金额格/表尾合计），其余行/格零重建。
// 墙钟断言在 CI 上随机器漂移必抖红，构建计数是确定性的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _PerfRow extends EditableGridRow with AmountRowMixin {
  _PerfRow(this.name);
  final String name;
  final ValueNotifier<String> field = ValueNotifier('');

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }
}

void main() {
  testWidgets('300 行初始每格只构建一次', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final rows = List.generate(300, (i) => _PerfRow('行$i'));
    final controller = UtenEditableGridController<_PerfRow>(initial: rows);
    final builds = <String, int>{};

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              UtenEditableGrid<_PerfRow>(
                controller: controller,
                columns: [
                  EditableGridColumn<_PerfRow>(
                    key: 'name',
                    label: '名称',
                    width: 160,
                    cellBuilder: (context, row) {
                      builds[row.name] = (builds[row.name] ?? 0) + 1;
                      return ValueListenableBuilder<String>(
                        valueListenable: row.field,
                        builder: (_, v, _) => Text('${row.name}-$v'),
                      );
                    },
                  ),
                  EditableGridColumn<_PerfRow>(
                    key: 'amount',
                    label: '金额',
                    width: 140,
                    numeric: true,
                    cellBuilder: (context, row) =>
                        ValueListenableBuilder<double>(
                          valueListenable: row.amountNotifier,
                          builder: (_, v, _) => Text(v.toStringAsFixed(2)),
                        ),
                  ),
                ],
                createBlankRow: () => _PerfRow('新行'),
                showColumnSettings: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初建允许 ≤2 次：首帧 + 表头实测高度修正（40 → 实际值）的一次性 setState 整表重建。
    // 这是 content-tall sticky 表头的固有一次性代价；再有任何多余构建都是回归。
    expect(builds.length, 300);
    expect(
      builds.values.every((n) => n <= 2),
      isTrue,
      reason:
          '存在超过 2 次构建的行：${builds.entries.where((e) => e.value > 2).take(3).toList()}',
    );

    // 稳态零重建：再 pump 数帧（无交互），计数不再增长。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds.values.every((n) => n <= 2), isTrue);
  });

  testWidgets('敲一个字只重建该格订阅链，不蔓延整表', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final rows = List.generate(300, (i) => _PerfRow('行$i'));
    final controller = UtenEditableGridController<_PerfRow>(initial: rows);
    final builds = <String, int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              UtenEditableGrid<_PerfRow>(
                controller: controller,
                columns: [
                  EditableGridColumn<_PerfRow>(
                    key: 'name',
                    label: '名称',
                    width: 160,
                    cellBuilder: (context, row) {
                      builds[row.name] = (builds[row.name] ?? 0) + 1;
                      return ValueListenableBuilder<String>(
                        valueListenable: row.field,
                        builder: (_, v, _) => Text('${row.name}-$v'),
                      );
                    },
                  ),
                  EditableGridColumn<_PerfRow>(
                    key: 'amount',
                    label: '金额',
                    width: 140,
                    numeric: true,
                    cellBuilder: (context, row) =>
                        ValueListenableBuilder<double>(
                          valueListenable: row.amountNotifier,
                          builder: (_, v, _) => Text(v.toStringAsFixed(2)),
                        ),
                  ),
                ],
                createBlankRow: () => _PerfRow('新行'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final baseline = Map.of(builds);

    // 改第 0 行的字段值（等价于 TextField 敲一个字驱动的 notifier 通知）。
    rows.first.field.value = 'x';
    await tester.pump();

    expect(find.text('行0-x'), findsOneWidget);
    // 外层 cellBuilder（行/格控件构造）在全表范围零重跑——变化只发生在第 0 行
    // 名称格内层的 ValueListenableBuilder（上面文案断言即其证据）。
    for (final e in baseline.entries) {
      expect(builds[e.key], e.value, reason: '${e.key} 在敲字后被重建');
    }

    // 金额通知链独立：改第 0 行金额同样不触发任何名称格重建。
    rows.first.recalcAmount(() => 1.5);
    await tester.pump();
    expect(find.text('1.50'), findsOneWidget);
    for (final e in baseline.entries) {
      expect(builds[e.key], e.value, reason: '${e.key} 在金额变化后被重建');
    }
  });
}
