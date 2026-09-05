// 仓库层级下拉（V476）：
// - 运营口径（默认）：父仓渲染为禁选分组标题、子仓缩进；
// - 查询口径（allowParent）：父仓可选（=子树聚合语义）；
// - warehouseHierarchyItems（UtenDropdownField 选项）与下拉同口径。
// - 历史已保存的父仓值在运营口径下仍能回显（value 匹配真实 id）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';

const _main = WarehouseDictEntry(id: 'main', name: '仓库（14年版）', code: '001');
const _finished = WarehouseDictEntry(
  id: 'finished',
  name: '成品仓库',
  code: 'C04',
  parentId: 'main',
);
const _defective = WarehouseDictEntry(
  id: 'defective',
  name: '成品不良品仓',
  code: 'C0401',
  parentId: 'main',
);
const _hierarchy = [_main, _finished, _defective];

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 300, child: child)),
    ),
  );

  testWidgets('operational dropdown groups parent as disabled header', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        WarehouseHierarchyDropdown(
          entries: _hierarchy,
          value: null,
          onChanged: (_) {},
        ),
      ),
    );
    await tester.tap(find.byType(WarehouseHierarchyDropdown));
    await tester.pumpAndSettle();

    // 父仓条目存在但禁用；子仓条目可选。
    final mainItem = tester.widget<DropdownMenuItem<String?>>(
      find.widgetWithText(DropdownMenuItem<String?>, '仓库（14年版）'),
    );
    expect(mainItem.enabled, isFalse);
    final finishedItem = tester.widget<DropdownMenuItem<String?>>(
      find.widgetWithText(DropdownMenuItem<String?>, '成品仓库'),
    );
    expect(finishedItem.enabled, isTrue);
    // 子仓带缩进（视觉分组）。
    expect(
      find.descendant(
        of: find.widgetWithText(DropdownMenuItem<String?>, '成品仓库'),
        matching: find.byType(Padding),
      ),
      findsOneWidget,
    );
  });

  testWidgets('allowParent makes the parent selectable (aggregate scope)', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      wrap(
        StatefulBuilder(
          builder: (context, setState) => WarehouseHierarchyDropdown(
            entries: _hierarchy,
            value: selected,
            includeAll: true,
            allowParent: true,
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(WarehouseHierarchyDropdown));
    await tester.pumpAndSettle();

    final mainItem = tester.widget<DropdownMenuItem<String?>>(
      find.widgetWithText(DropdownMenuItem<String?>, '仓库（14年版）'),
    );
    expect(mainItem.enabled, isTrue);

    await tester.tap(find.text('仓库（14年版）').last);
    await tester.pumpAndSettle();
    expect(selected, 'main');
  });

  testWidgets('saved parent value still displays in operational mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        WarehouseHierarchyDropdown(
          entries: _hierarchy,
          value: 'main',
          onChanged: (_) {},
        ),
      ),
    );
    // 闭态按钮显示父仓名（历史单据回显），不显示空值占位。
    expect(find.text('仓库（14年版）'), findsOneWidget);
  });

  test('warehouseHierarchyItems mirrors the grouping semantics', () {
    final items = warehouseHierarchyItems(_hierarchy);
    expect(items, hasLength(3));
    // 父仓=禁选标题；子仓可选并缩进。
    expect(items[0].value, 'main');
    expect(items[0].enabled, isFalse);
    expect(items[0].indent, 0);
    expect(items[1].value, 'finished');
    expect(items[1].enabled, isTrue);
    expect(items[1].indent, 16);

    // 查询口径：父仓可选。
    final aggregate = warehouseHierarchyItems(_hierarchy, allowParent: true);
    expect(aggregate[0].enabled, isTrue);
  });
}
