// 2026-10-19 框选交互两处口径：
//
//  1. 单元格有内容时 hover 显 I 型文本光标（此前 SelectionArea 不设光标、
//     行 InkWell 给可点击光标，用户在可框选的格上看不到「能拖选」的示意）；
//     空白格与 enableTextSelection=false 的表不换光标。
//  2. 存在文字框选时，左键单击只取消框选，不再切换行选中（Excel/浏览器口径；
//     此前 InkWell tap 抢赢手势竞技场，直接选中了行）。
//
// 观察 SelectionArea 的选区用 SelectableRegionState.textEditingValue
// （TextSelectionDelegate 的公开镜像）；官方没有替代的只读查询口
// （deprecation 指向的是可编辑场景），测试专用本豁免。
// ignore_for_file: deprecated_member_use
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

Widget _table(
  List<_Row> items, {
  bool enableTextSelection = true,
  ValueChanged<Set<String>>? onSelected,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: 260,
        child: StatefulBuilder(
          builder: (context, update) {
            var selected = <String>{};
            return MasterDataTableView<_Row>(
              enableTextSelection: enableTextSelection,
              columns: [
                MasterColumnDef<_Row>(
                  key: 'id',
                  label: 'ID',
                  width: 240,
                  value: (r) => r.id,
                ),
                MasterColumnDef<_Row>(
                  key: 'note',
                  label: '备注',
                  width: 160,
                  // 第二列只在 a1 行有内容：空白格不许换光标。
                  value: (r) => r.id == 'a1' ? '内容文本' : '',
                ),
              ],
              items: items,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              selectable: true,
              idOf: (r) => r.id,
              selectedIds: selected,
              onSelectedIdsChanged: (next) {
                update(() => selected = next);
                onSelected?.call(next);
              },
            );
          },
        ),
      ),
    ),
  );
}

Finder _textCursorRegions() => find.byWidgetPredicate(
  (w) => w is MouseRegion && w.cursor == SystemMouseCursors.text,
);

/// SelectableRegionState 实现了 TextSelectionDelegate：textEditingValue 是
/// 选区几何的公开镜像（未折叠选区 → 非折叠 selection，清空 → 折叠）。
bool _hasAreaSelection(WidgetTester tester) {
  final value =
      tester
          .state<SelectionAreaState>(find.byType(SelectionArea))
          .selectableRegion
          .textEditingValue;
  return value.selection.isValid && !value.selection.isCollapsed;
}

void main() {
  testWidgets('有内容的格带 I 型文本光标区域；空白格与关闭框选时不带', (
    tester,
  ) async {
    await tester.pumpWidget(_table(const [_Row('a1'), _Row('a2')]));
    await tester.pumpAndSettle();

    // a1 行两个有内容的格（ID + 备注）、a2 行一个（ID）：共 3 个文本光标区域。
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('a1'), matching: _textCursorRegions()),
        matching: find.text('a1'),
      ),
      findsOneWidget,
    );
    expect(_textCursorRegions(), findsNWidgets(3));

    // 关闭文字选择后：不再出现文本光标区域（行为回到行可点击光标）。
    await tester.pumpWidget(
      _table(const [_Row('a1'), _Row('a2')], enableTextSelection: false),
    );
    await tester.pumpAndSettle();
    expect(_textCursorRegions(), findsNothing);
  });

  testWidgets('框选存在时单击只清框选，不选中行；清完后再点才恢复选行', (tester) async {
    final selectedCalls = <Set<String>>[];
    await tester.pumpWidget(
      _table(const [_Row('a1'), _Row('a2')], onSelected: selectedCalls.add),
    );
    await tester.pumpAndSettle();

    // 鼠标从 a1 文字向下拖到 a2：产生跨行文字框选。
    final start = tester.getCenter(find.text('a1'));
    final gesture = await tester.startGesture(
      start,
      pointer: 0,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveTo(tester.getCenter(find.text('a2')));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_hasAreaSelection(tester), isTrue);
    expect(selectedCalls, isEmpty, reason: '拖选文字不得触发行勾选');

    // 框选存在时单击 a2：只取消框选——行不进选中集（此前的缺陷行为）。
    await tester.tap(find.text('a2'), pointer: 1);
    await tester.pumpAndSettle();
    expect(_hasAreaSelection(tester), isFalse);
    expect(selectedCalls, isEmpty, reason: '取消框选的那次单击不许顺带选中行');

    // 再单击 a2：恢复正常交互——行进入选中集。
    await tester.tap(find.text('a2'), pointer: 2);
    await tester.pumpAndSettle();
    expect(selectedCalls, [
      {'a2'},
    ]);
  });
}
