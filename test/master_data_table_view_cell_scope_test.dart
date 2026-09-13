import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final selectable in [false, true]) {
    testWidgets(
      'custom cells receive actual ${selectable ? "checkbox" : "single-row"} selection',
      (tester) async {
        Set<String> selectedIds = {};
        final scopes = <String, MasterDataTableCellScope>{};
        final textColors = <String, Color?>{};
        final iconColors = <String, Color?>{};
        final theme = ThemeData(brightness: Brightness.light);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => SizedBox(
                  width: 640,
                  height: 300,
                  child: MasterDataTableView<String>(
                    columns: [
                      MasterColumnDef<String>(
                        key: 'custom',
                        label: 'Custom',
                        width: 200,
                        value: (item) => item,
                        cellBuilder: (cellContext, item) {
                          scopes[item] = MasterDataTableCellScope.maybeOf(
                            cellContext,
                          )!;
                          textColors[item] = DefaultTextStyle.of(
                            cellContext,
                          ).style.color;
                          iconColors[item] = IconTheme.of(cellContext).color;
                          return Text(item);
                        },
                      ),
                    ],
                    items: const ['First', 'Second'],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: selectable,
                    idOf: (item) => item,
                    selectedIds: selectedIds,
                    onSelectedIdsChanged: (next) =>
                        setState(() => selectedIds = next),
                    onRowTap: (_) {},
                    showFullscreenToggle: false,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(scopes['First']!.selected, isFalse);
        await tester.tap(find.text('First'));
        await tester.pumpAndSettle();
        expect(scopes['First']!.selected, isTrue);
        // 2026-09-13 全站表格选中口径：选中行淡绿底（primaryContainer 35%，
        // 与新建销售出货单的编辑网格同款）+ 常态字色——不再深绿底白字，
        // 行内自绘内容无需随选中态变色。
        final bodyColor = theme.textTheme.bodySmall!.color;
        expect(scopes['First']!.foregroundColor, bodyColor);
        expect(textColors['First'], bodyColor);
        expect(iconColors['First'], bodyColor);
        final selectedTint = theme.colorScheme.primaryContainer.withValues(
          alpha: 0.35,
        );
        expect(
          find.byWidgetPredicate(
            (widget) => widget is ColoredBox && widget.color == selectedTint,
          ),
          findsOneWidget,
        );
        expect(scopes['Second']!.selected, isFalse);
        expect(selectedIds, selectable ? {'First'} : isEmpty);
        // 选中/未选中字色一致（对比度不再依赖选中态翻转）。
        expect(textColors['Second'], bodyColor);

        await tester.tap(find.text('Second'));
        await tester.pumpAndSettle();
        expect(scopes['Second']!.selected, isTrue);
        expect(scopes['First']!.selected, selectable);
        expect(textColors['Second'], bodyColor);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
