// 仓库层级下拉（V476）：
// - 运营口径（默认）：父仓渲染为禁选分组标题、子仓缩进；
// - 查询口径（allowParent）：父仓可选（=子树聚合语义）；
// - warehouseHierarchyItems（UtenDropdownField 选项）与下拉同口径。
// - 历史已保存的父仓值在运营口径下仍能回显（value 匹配真实 id）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';
import 'package:uten_imp/shared/widgets/warehouse_picker_panel.dart';
import 'package:uten_imp/shared/widgets/warehouse_selection.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';

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
  const disabled = WarehouseDictEntry(
    id: 'hardware',
    name: '五金仓库',
    parentId: 'main',
    status: '禁用',
  );
  const unaccountable = WarehouseDictEntry(
    id: 'no-ledger',
    name: '不记账仓',
    parentId: 'main',
    isAccountable: false,
  );
  const disabledMain = WarehouseDictEntry(
    id: 'closed-main',
    name: '停用主仓',
    status: '禁用',
  );
  const enabledChild = WarehouseDictEntry(
    id: 'closed-child',
    name: '启用子仓',
    parentId: 'closed-main',
    status: '使用',
  );
  const realMain = WarehouseDictEntry(
    id: 'main',
    name: '主仓库',
    isAccountable: false,
  );
  const choices = [
    realMain,
    _finished,
    disabled,
    unaccountable,
    disabledMain,
    enabledChild,
  ];

  test('canonical accountable flag wins and supports the historical alias', () {
    expect(
      WarehouseDictEntry.fromJson({
        'id': 'x',
        'name': '仓',
        'accountable': false,
        'isAccountable': true,
      }).isAccountable,
      isFalse,
    );
    expect(
      WarehouseDictEntry.fromJson({
        'id': 'x',
        'name': '仓',
        'isAccountable': false,
      }).isAccountable,
      isFalse,
    );
  });

  test(
    'new selections hide disabled ancestry and non-accounting leaves; history stays named',
    () {
      final selection = WarehouseSelection(choices);
      expect(selection.selectableIds, {'finished'});
      expect(selection.visibleIds, {'main', 'finished'});
      final items = warehouseHierarchyItems(choices, currentValue: 'hardware');
      final history = items.singleWhere((item) => item.value == 'hardware');
      expect(history.label, '五金仓库');
      expect(history.enabled, isFalse);
      expect(history.visible, isFalse);
      expect(warehouseFullLabel(choices, 'hardware'), '主仓库-五金仓库');
      expect(
        warehouseHierarchyItems(
          choices,
          allowParent: true,
        ).every((item) => item.enabled && item.visible),
        isTrue,
      );
    },
  );

  test('missing and cyclic parent references never become new choices', () {
    expect(
      WarehouseSelection(const [
        WarehouseDictEntry(id: 'orphan', name: '缺上级', parentId: 'missing'),
        WarehouseDictEntry(id: 'a', name: 'A', parentId: 'b'),
        WarehouseDictEntry(id: 'b', name: 'B', parentId: 'a'),
        WarehouseDictEntry(id: 'leaf', name: '循环下属', parentId: 'a'),
      ]).selectableIds,
      isEmpty,
    );
  });

  testWidgets(
    'historical disabled label is displayed but absent from the menu',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenDropdownField(
              value: 'hardware',
              items: warehouseHierarchyItems(choices, currentValue: 'hardware'),
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('五金仓库'), findsOneWidget);
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      expect(find.text('五金仓库'), findsOneWidget); // closed field only
      expect(find.text('成品仓库'), findsOneWidget);
      expect(find.text('启用子仓'), findsNothing);
    },
  );

  testWidgets(
    'panel keeps non-accounting parent navigation and hides disabled stock as new choices',
    (tester) async {
      WarehousePickerResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showUtenWarehousePickerPanel(
                    context,
                    hierarchy: choices,
                    initialWarehouseId: 'hardware',
                  );
                },
                child: const Text('选择仓库'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择仓库'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-picker-entry-main')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-closed-main')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-main')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-picker-entry-hardware')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-no-ledger')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const Key('warehouse-picker-entry-finished')),
      );
      await tester.pumpAndSettle();
      expect(result?.id, 'finished');
    },
  );

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

  testWidgets(
    'native historical value stays named without reappearing as a choice',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          WarehouseHierarchyDropdown(
            entries: choices,
            value: 'hardware',
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('五金仓库'), findsOneWidget);
      await tester.tap(find.byType(WarehouseHierarchyDropdown));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(DropdownMenuItem<String?>, '五金仓库'),
        findsNothing,
      );
      expect(
        find.widgetWithText(DropdownMenuItem<String?>, '成品仓库'),
        findsOneWidget,
      );
    },
  );

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
