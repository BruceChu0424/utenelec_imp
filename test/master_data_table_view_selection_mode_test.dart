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
}
