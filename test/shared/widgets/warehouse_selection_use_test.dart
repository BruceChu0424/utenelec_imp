// ADR-146 选仓用途：良品/不良品两类仓按用途过滤，只认服务端字典算好的两个可选标记；
// 良品用途下不良品仓照常列出但置灰带标签；普通调拨调入仓收窄到与调出仓同类。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/widgets/warehouse_hierarchy_dropdown.dart';
import 'package:uten_imp/shared/widgets/warehouse_picker_panel.dart';
import 'package:uten_imp/shared/widgets/warehouse_selection.dart';

const _hierarchy = [
  WarehouseDictEntry(id: 'root', name: '仓库(14年版)'),
  WarehouseDictEntry(
    id: 'good',
    name: '包材仓库',
    parentId: 'root',
    selectableForNew: true,
  ),
  WarehouseDictEntry(
    id: 'bad',
    name: '成品不良品仓',
    parentId: 'root',
    isDefective: true,
    selectableDefective: true,
  ),
  WarehouseDictEntry(
    id: 'bad-disabled',
    name: '停用不良仓',
    parentId: 'root',
    isDefective: true,
    status: '禁用',
  ),
  WarehouseDictEntry(
    id: 'bin',
    name: '注塑车间内料仓',
    parentId: 'root',
    isLineSide: true,
  ),
];

void main() {
  test('each use only trusts the matching server flag', () {
    Set<String> ids(WarehouseUse use) =>
        WarehouseSelection(_hierarchy, use: use).selectableIds;
    expect(ids(WarehouseUse.goodIn), {'good'});
    expect(ids(WarehouseUse.goodOut), {'good'});
    expect(ids(WarehouseUse.defectiveIn), {'bad'});
    expect(ids(WarehouseUse.defectiveOut), {'bad'});
    for (final use in [
      WarehouseUse.disposalOut,
      WarehouseUse.transfer,
      WarehouseUse.count,
    ]) {
      expect(ids(use), {'good', 'bad'}, reason: '$use');
    }
    // 查询口径不看可选标记：任何层级可选，只是不列停用的仓。
    expect(ids(WarehouseUse.query), {'root', 'good', 'bad', 'bin'});
  });

  test('good uses show defective warehouses as blocked, not hidden', () {
    final selection = WarehouseSelection(_hierarchy, use: WarehouseUse.goodIn);
    expect(selection.visibleIds, {'root', 'good', 'bad'});
    expect(selection.selectableIds, isNot(contains('bad')));
    // 不能用的不良品仓(停用)不出现。
    expect(selection.visibleIds, isNot(contains('bad-disabled')));
    final defectiveOnly = WarehouseSelection(
      _hierarchy,
      use: WarehouseUse.defectiveIn,
    );
    expect(defectiveOnly.visibleIds, {'root', 'bad'});
  });

  test('a normal transfer target narrows to the source class', () {
    expect(
      WarehouseSelection(
        _hierarchy,
        use: WarehouseUse.transfer,
        sameClassAs: 'bad',
      ).selectableIds,
      {'bad'},
    );
    expect(
      WarehouseSelection(
        _hierarchy,
        use: WarehouseUse.transfer,
        sameClassAs: 'good',
      ).selectableIds,
      {'good'},
    );
  });

  test('dictionary parses the defective selectability flag', () {
    final entry = WarehouseDictEntry.fromJson({
      'id': 'bad',
      'name': '成品不良品仓',
      'defective': true,
      'selectableForNew': false,
      'selectableDefective': true,
    });
    expect(entry.isDefective, isTrue);
    expect(entry.selectableDefective, isTrue);
    expect(
      WarehouseDictEntry.fromJson({
        'id': 'old',
        'name': '旧字典',
      }).selectableDefective,
      isFalse,
    );
  });

  test('dropdown items tag defective warehouses and disable them for good', () {
    final items = warehouseHierarchyItems(
      _hierarchy,
      use: WarehouseUse.goodOut,
      defectiveTag: '不良品',
    );
    final bad = items.singleWhere((item) => item.value == 'bad');
    expect(bad.label, '成品不良品仓 (不良品)');
    expect(bad.enabled, isFalse);
    final good = items.singleWhere((item) => item.value == 'good');
    expect(good.enabled, isTrue);
    final disposal = warehouseHierarchyItems(
      _hierarchy,
      use: WarehouseUse.disposalOut,
      defectiveTag: '不良品',
    );
    expect(disposal.singleWhere((item) => item.value == 'bad').enabled, isTrue);
  });

  testWidgets('panel tags defective entries and refuses them for good uses', (
    tester,
  ) async {
    WarehousePickerResult? picked;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  picked = await showUtenWarehousePickerPanel(
                    context,
                    hierarchy: _hierarchy,
                    use: WarehouseUse.goodIn,
                  ),
              child: const Text('选仓'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选仓'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-root')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('warehouse-picker-defective-bad')),
      findsOneWidget,
    );
    expect(find.text('不良品仓, 这里不能选'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.byKey(const Key('warehouse-picker-entry-bad')),
    );
    expect(tile.enabled, isFalse);
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-bad')));
    await tester.pumpAndSettle();
    expect(picked, isNull, reason: '置灰的不良品仓点了不选中');
    await tester.tap(find.byKey(const Key('warehouse-picker-entry-good')));
    await tester.pumpAndSettle();
    expect(picked?.id, 'good');
  });
}
