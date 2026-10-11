import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final primary in [false, true]) {
    testWidgets('selection mode can change both ways with primary=$primary', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final mode = ValueNotifier((multi: false, text: true));
      addTearDown(mode.dispose);
      final selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SelectionArea(
              child: ValueListenableBuilder(
                valueListenable: mode,
                builder: (context, current, _) {
                  final table = MasterDataTableView<String>(
                    primary: primary,
                    columns: [
                      MasterColumnDef(
                        key: 'name',
                        label: '名称',
                        width: 180,
                        value: (item) => item,
                      ),
                    ],
                    items: const ['row-a', 'row-b'],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: current.multi,
                    enableTextSelection: current.text,
                    idOf: (item) => item,
                    rowKeyOf: (item) => item,
                    selectedIds: selected,
                    onSelectedIdsChanged: (ids) {
                      selected
                        ..clear()
                        ..addAll(ids);
                    },
                    batchActionsBuilder: (_, _) => const [Text('批量操作')],
                  );
                  return primary
                      ? UtenCollapsingHeaderScrollView(
                          collapsingHeader: const SizedBox(height: 60),
                          body: table,
                        )
                      : table;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tableState = tester.state(find.byType(MasterDataTableView<String>));

      // Both row-selection changes and explicit text-copy opt-out used to
      // detach ListView's registrar before its old children unregistered.
      for (final current in [
        (multi: false, text: true),
        (multi: true, text: true),
        (multi: false, text: true),
        (multi: false, text: false),
        (multi: false, text: true),
      ]) {
        mode.value = current;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.state(find.byType(MasterDataTableView<String>)),
          same(tableState),
        );
        final registrar = SelectionContainer.maybeOf(
          tester.element(find.text('row-a')),
        );
        expect(
          registrar,
          current.multi || !current.text ? isNull : isNotNull,
          reason: '多选时只禁用行内文字复制，普通浏览恢复文字选择',
        );
        if (current.multi) {
          await tester.tap(find.text('row-a'));
          await tester.pumpAndSettle();
          expect(selected, {'row-a'});
          expect(tester.takeException(), isNull);
        }
      }
    });
  }

  testWidgets(
    'showSelectionColumn=false keeps row-click selection without checkbox column',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // 选中集由宿主持有并 setState 回交（与真实页面同款）；组件只回交新集合。
      var selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MasterDataTableView<String>(
                columns: [
                  MasterColumnDef(
                    key: 'name',
                    label: '名称',
                    width: 180,
                    value: (item) => item,
                  ),
                ],
                items: const ['row-a', 'row-b'],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: true,
                showSelectionColumn: false,
                idOf: (item) => item,
                selectedIds: selected,
                onSelectedIdsChanged: (ids) =>
                    setState(() => selected = Set<String>.of(ids)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 2026-10-10 审核页防看岔口径「最前面的多选不要显示」：勾选框列与
      // 表头全选格都不渲染，选中交互（行单击切换）与选中高亮照旧。
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.byKey(const Key('master-data-table-select-all')),
        findsNothing,
      );

      await tester.tap(find.text('row-a'));
      await tester.pumpAndSettle();
      expect(selected, {'row-a'});

      // 再点一次取消；另一行单击独立选中。
      await tester.tap(find.text('row-a'));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      await tester.tap(find.text('row-b'));
      await tester.pumpAndSettle();
      expect(selected, {'row-b'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'singleSelection replaces the previous row instead of accumulating',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MasterDataTableView<String>(
                columns: [
                  MasterColumnDef(
                    key: 'name',
                    label: '名称',
                    width: 180,
                    value: (item) => item,
                  ),
                ],
                items: const ['row-a', 'row-b', 'row-c'],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: true,
                showSelectionColumn: false,
                singleSelection: true,
                showSelectionSummary: false,
                idOf: (item) => item,
                selectedIds: selected,
                onSelectedIdsChanged: (ids) =>
                    setState(() => selected = Set<String>.of(ids)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 2026-10-10 口径「默认不要多选」：单选互斥——点其他行自动换选，
      // 集合恒为空或单元素；再点同一行取消。
      await tester.tap(find.text('row-a'));
      await tester.pumpAndSettle();
      expect(selected, {'row-a'});

      await tester.tap(find.text('row-b'));
      await tester.pumpAndSettle();
      expect(selected, {'row-b'}, reason: '点另一行 = 换选，row-a 自动失选');

      await tester.tap(find.text('row-b'));
      await tester.pumpAndSettle();
      expect(selected, isEmpty, reason: '再点同一行 = 取消');

      // 单选下不驻「已选 N」胶囊（调用方 showSelectionSummary:false）。
      expect(find.textContaining('已选'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
