// 仓库层级下拉 / 侧滑面板(ADR-145 单主仓)：
// - 运营口径(默认，WarehouseUse.good)：只认服务端算好的 selectableForNew，主仓渲染为禁选分组标题、
//   子仓缩进；不良品仓、停用仓、内料仓、主仓都不是新选项，前端不再自己推算；
// - 查询口径(allowParent，WarehouseUse.query)：任意层级可选(= 子树聚合语义)，默认不列停用仓；
// - warehouseHierarchyItems(UtenDropdownField 选项, use: WarehouseUse.goodIn)与下拉同口径；
// - 历史已保存的值在两种口径下都能回显(value 匹配真实 id)。
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
  selectableForNew: true,
);
const _defective = WarehouseDictEntry(
  id: 'defective',
  name: '成品不良品仓',
  code: 'C0401',
  parentId: 'main',
  isDefective: true,
);
const _hierarchy = [_main, _finished, _defective];

void main() {
  const lineSide = WarehouseDictEntry(
    id: 'line-side',
    name: '车间流转位置',
    parentId: 'main',
    isLineSide: true,
  );
  testWidgets(
    'technical child keeps a standalone physical warehouse directly selectable',
    (tester) async {
      // 只有车间内料仓挂在下面的普通仓仍是作业叶仓: 服务端给它 selectableForNew。
      const standalone = WarehouseDictEntry(
        id: 'main',
        name: '仓库（14年版）',
        selectableForNew: true,
      );
      final entries = [standalone, lineSide];
      expect(
        WarehouseSelection(entries, use: WarehouseUse.goodIn).selectableIds,
        {'main'},
      );
      WarehousePickerResult? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    picked = await showUtenWarehousePickerPanel(
                      context,
                      use: WarehouseUse.goodIn,
                      hierarchy: entries,
                    ),
                child: const Text('选仓'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选仓'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-main')));
      await tester.pumpAndSettle();
      expect(picked?.id, 'main');
    },
  );
  test(
    'workshop locations remain identifiable but cannot be newly selected',
    () {
      final entries = [..._hierarchy, lineSide];
      expect(
        WarehouseSelection(entries, use: WarehouseUse.goodIn).selectableIds,
        isNot(contains('line-side')),
      );
      final items = warehouseHierarchyItems(
        entries,
        currentValue: 'line-side',
        use: WarehouseUse.goodIn,
      );
      final historical = items.singleWhere((item) => item.value == 'line-side');
      expect(historical.label, '车间流转位置');
      expect(historical.enabled, isFalse);
      expect(historical.visible, isFalse);
      expect(warehouseFullLabel(entries, 'line-side'), '仓库（14年版）-车间流转位置');
      expect(
        WarehouseDictEntry.fromJson({
          'id': 'line-side',
          'name': '车间流转位置',
          'lineSide': true,
        }).isLineSide,
        isTrue,
      );
    },
  );

  test('dictionary carries the server-computed use and selectability', () {
    final defective = WarehouseDictEntry.fromJson({
      'id': 'c0401',
      'name': '成品不良品仓',
      'defective': true,
      'selectableForNew': false,
    });
    expect(defective.isDefective, isTrue);
    expect(defective.selectableForNew, isFalse);
    final good = WarehouseDictEntry.fromJson({
      'id': 'xw01',
      'name': '塑胶仓库',
      'parentId': 'main',
      'selectableForNew': true,
    });
    expect(good.isDefective, isFalse);
    expect(good.selectableForNew, isTrue);
    // 旧服务端没有这个字段: 一律按不可选(失败关闭), 前端不再自己推算。
    expect(
      WarehouseDictEntry.fromJson({
        'id': 'old',
        'name': '旧字典',
        'accountable': true,
        'status': '使用',
      }).selectableForNew,
      isFalse,
    );
  });

  test('defective-stock warehouses are not good-stock choices', () {
    final selection = WarehouseSelection(_hierarchy, use: WarehouseUse.goodIn);
    expect(selection.selectableIds, {'finished'});
    expect(selection.visibleIds, {'main', 'finished'});
    final items = warehouseHierarchyItems(_hierarchy, use: WarehouseUse.goodIn);
    expect(items.map((item) => item.value), ['main', 'finished']);
    // 查询口径看库存: 不良品仓照常可选(W2b 再加「不良品」标签与用途细分)。
    final query = WarehouseSelection(_hierarchy, use: WarehouseUse.query);
    expect(query.selectableIds, {'main', 'finished', 'defective'});
  });

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
  const realMain = WarehouseDictEntry(
    id: 'main',
    name: '主仓库',
    isAccountable: false,
  );
  const choices = [realMain, _finished, disabled, unaccountable];

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

  test('new selections only trust the server flag; history stays named', () {
    final selection = WarehouseSelection(choices, use: WarehouseUse.goodIn);
    expect(selection.selectableIds, {'finished'});
    expect(selection.visibleIds, {'main', 'finished'});
    final items = warehouseHierarchyItems(
      choices,
      currentValue: 'hardware',
      use: WarehouseUse.goodIn,
    );
    final history = items.singleWhere((item) => item.value == 'hardware');
    expect(history.label, '五金仓库');
    expect(history.enabled, isFalse);
    expect(history.visible, isFalse);
    expect(warehouseFullLabel(choices, 'hardware'), '主仓库-五金仓库');
    // 查询口径: 停用仓不列(当前值除外), 其余任意层级可选。
    final query = warehouseHierarchyItems(choices, use: WarehouseUse.query);
    expect(query.map((item) => item.value), ['main', 'finished', 'no-ledger']);
    expect(query.every((item) => item.enabled && item.visible), isTrue);
    final current = warehouseHierarchyItems(
      choices,
      use: WarehouseUse.query,
      currentValue: 'hardware',
    ).singleWhere((item) => item.value == 'hardware');
    expect(current.enabled, isFalse);
    expect(current.visible, isFalse);
  });

  test('entries without the server flag never become new choices', () {
    expect(
      WarehouseSelection(const [
        WarehouseDictEntry(id: 'top', name: '看似可选的顶层仓'),
        WarehouseDictEntry(id: 'leaf', name: '看似可选的子仓', parentId: 'top'),
      ], use: WarehouseUse.goodIn).selectableIds,
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
              items: warehouseHierarchyItems(
                choices,
                currentValue: 'hardware',
                use: WarehouseUse.goodIn,
              ),
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
      expect(find.text('不记账仓'), findsNothing);
    },
  );

  testWidgets(
    'panel keeps main navigation and hides disabled stock as new choices',
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
                    use: WarehouseUse.goodIn,
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
          use: WarehouseUse.goodIn,
          entries: _hierarchy,
          value: null,
          onChanged: (_) {},
        ),
      ),
    );
    // 2026-09-16 下拉统一：内部改 UtenDropdownField，断言转到其 items 契约。
    final field = tester.widget<UtenDropdownField>(
      find.descendant(
        of: find.byType(WarehouseHierarchyDropdown),
        matching: find.byType(UtenDropdownField),
      ),
    );
    // 主仓条目存在但禁用；子仓条目可选且带缩进(视觉分组)；不良品仓不是新选项。
    final mainItem = field.items.singleWhere((i) => i.value == 'main');
    expect(mainItem.enabled, isFalse);
    expect(mainItem.visible, isTrue);
    final finishedItem = field.items.singleWhere((i) => i.value == 'finished');
    expect(finishedItem.enabled, isTrue);
    expect(finishedItem.indent, 16);
    expect(field.items.any((i) => i.value == 'defective'), isFalse);
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
            use: WarehouseUse.query,
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
      ),
    );
    final fieldFinder = find.descendant(
      of: find.byType(WarehouseHierarchyDropdown),
      matching: find.byType(UtenDropdownField),
    );
    final field = tester.widget<UtenDropdownField>(fieldFinder);
    final mainItem = field.items.singleWhere((i) => i.value == 'main');
    expect(mainItem.enabled, isTrue);

    await tester.tap(fieldFinder);
    await tester.pumpAndSettle();
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
          use: WarehouseUse.goodIn,
          entries: _hierarchy,
          value: 'main',
          onChanged: (_) {},
        ),
      ),
    );
    // 闭态字段显示主仓名(历史单据回显)，不显示空值占位。
    expect(find.text('仓库（14年版）'), findsOneWidget);
  });

  testWidgets(
    'native historical value stays named without reappearing as a choice',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          WarehouseHierarchyDropdown(
            use: WarehouseUse.goodIn,
            entries: choices,
            value: 'hardware',
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('五金仓库'), findsOneWidget);
      final fieldFinder = find.descendant(
        of: find.byType(WarehouseHierarchyDropdown),
        matching: find.byType(UtenDropdownField),
      );
      await tester.tap(fieldFinder);
      await tester.pumpAndSettle();
      // 历史值条目不再作为新选项出现（visible=false 由弹层过滤），
      // 可选条目照常渲染。
      final field = tester.widget<UtenDropdownField>(fieldFinder);
      expect(field.items.any((i) => i.label == '五金仓库' && i.visible), isFalse);
      expect(find.text('成品仓库'), findsWidgets);
    },
  );

  test('warehouseHierarchyItems mirrors the grouping semantics', () {
    final items = warehouseHierarchyItems(_hierarchy, use: WarehouseUse.goodIn);
    expect(items, hasLength(2));
    // 主仓=禁选标题；子仓可选并缩进。
    expect(items[0].value, 'main');
    expect(items[0].enabled, isFalse);
    expect(items[0].indent, 0);
    expect(items[1].value, 'finished');
    expect(items[1].enabled, isTrue);
    expect(items[1].indent, 16);

    // 查询口径：主仓可选。
    final aggregate = warehouseHierarchyItems(
      _hierarchy,
      use: WarehouseUse.query,
    );
    expect(aggregate[0].enabled, isTrue);
    expect(aggregate, hasLength(3));
  });

  // ---- 查询口径侧滑面板(即时库存/货架目视化统一入口)------------
  Future<void> pumpQueryPanel(
    WidgetTester tester,
    void Function(WarehousePickerResult?) onPicked, {
    String? initialWarehouseId,
    List<WarehouseDictEntry> hierarchy = _hierarchy,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onPicked(
                await showUtenWarehousePickerPanel(
                  context,
                  hierarchy: hierarchy,
                  initialWarehouseId: initialWarehouseId,
                  title: '选择仓库',
                  includeAll: true,
                  use: WarehouseUse.query,
                ),
              ),
              child: const Text('选择仓库'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择仓库'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'query panel lists the whole hierarchy at once and picks a parent',
    (tester) async {
      WarehousePickerResult? result;
      await pumpQueryPanel(tester, (value) => result = value);

      // 不钻层：主仓与子仓同屏；顶部多一行「全部」。
      expect(find.byKey(const Key('warehouse-picker-all')), findsOneWidget);
      expect(
        find.byKey(const Key('warehouse-picker-entry-main')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-finished')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('warehouse-picker-entry-defective')),
        findsOneWidget,
      );

      // 主仓可选 = 自身 + 全部子仓聚合（运营口径下主仓只能钻层）。
      await tester.tap(find.byKey(const Key('warehouse-picker-entry-main')));
      await tester.pumpAndSettle();
      expect(result?.id, 'main');
      expect(result?.isAll, isFalse);
    },
  );

  testWidgets('query panel does not list disabled warehouses', (tester) async {
    await pumpQueryPanel(tester, (_) {}, hierarchy: [..._hierarchy, disabled]);
    expect(
      find.byKey(const Key('warehouse-picker-entry-hardware')),
      findsNothing,
    );
  });

  testWidgets('query panel still shows a disabled current filter', (
    tester,
  ) async {
    await pumpQueryPanel(
      tester,
      (_) {},
      hierarchy: [..._hierarchy, disabled],
      initialWarehouseId: 'hardware',
    );
    // 当前筛选值是停用仓时仍列出来, 让人看见自己选的是谁。
    expect(
      find.byKey(const Key('warehouse-picker-entry-hardware')),
      findsOneWidget,
    );
  });

  testWidgets('query panel 全部 clears the filter', (tester) async {
    WarehousePickerResult? result;
    await pumpQueryPanel(
      tester,
      (value) => result = value,
      initialWarehouseId: 'finished',
    );

    await tester.tap(find.byKey(const Key('warehouse-picker-all')));
    await tester.pumpAndSettle();
    expect(result?.isAll, isTrue);
    expect(result?.id, isEmpty);
  });

  testWidgets('query panel search narrows to matches plus ancestors', (
    tester,
  ) async {
    await pumpQueryPanel(tester, (_) {});

    await tester.enterText(
      find.byKey(const Key('warehouse-picker-search')),
      '不良',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('warehouse-picker-entry-defective')),
      findsOneWidget,
    );
    // 祖先留作层级上下文，同级未命中的兄弟收起。
    expect(
      find.byKey(const Key('warehouse-picker-entry-main')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-picker-entry-finished')),
      findsNothing,
    );
  });
}
