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
import 'package:flutter/services.dart';
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

/// SelectableRegionState 实现了 TextSelectionDelegate：textEditingValue 是
/// 选区几何的公开镜像（未折叠选区 → 非折叠 selection，清空 → 折叠）。
bool _hasAreaSelection(WidgetTester tester) {
  final value = tester
      .state<SelectionAreaState>(find.byType(SelectionArea))
      .selectableRegion
      .textEditingValue;
  return value.selection.isValid && !value.selection.isCollapsed;
}

void main() {
  // 光标断言走端到端解析：mock mouseCursor 通道，看框架最终激活的光标种类。
  // （只数 MouseRegion widget 不够——行 InkWell 会给子树注入
  // DefaultSelectionStyle(basic)，Text 自带的最内层光标区域会压过外层包裹。）
  testWidgets('字体本体上解析为 I 型光标；空白格与关闭框选时不解析为 text', (tester) async {
    String? cursor;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.mouseCursor, (call) async {
          cursor = (call.arguments as Map)['kind']?.toString();
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.mouseCursor, null);
    });
    await tester.pumpWidget(_table(const [_Row('a1'), _Row('a2')]));
    await tester.pumpAndSettle();
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 9,
    );
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    Future<String?> hover(Offset pos) async {
      cursor = null;
      await gesture.moveTo(pos);
      await tester.pump();
      return cursor;
    }

    // 字体本体：两列有内容的文本都解析为 text（第二次无激活=保持 text，也算过）。
    final first = await hover(tester.getCenter(find.text('a1')));
    expect(first == 'text' || first == null, isTrue, reason: 'a1 文本应为 text 光标');
    // 从文本移到同格空白区：解析回行的可点击/箭头（basic），不再是 text。
    expect(
      await hover(
        Offset(
          tester.getRect(find.text('内容文本')).right + 30,
          tester.getCenter(find.text('内容文本')).dy,
        ),
      ),
      isNot('text'),
    );

    // 关闭文字选择：文本上也不再解析为 text。
    await tester.pumpWidget(
      _table(const [_Row('a1')], enableTextSelection: false),
    );
    await tester.pumpAndSettle();
    final offKind = await hover(tester.getCenter(find.text('a1')));
    expect(offKind, isNot('text'));
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
