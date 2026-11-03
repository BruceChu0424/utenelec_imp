import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {
  _Row(this.index);

  final int index;
  final note = TextEditingController(text: 'unsaved business input');
  bool includedInSubmission = true;

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }
}

void main() {
  for (final external in [false, true]) {
    testWidgets(
      'return clears operation targets and preserves business rows (external=$external)',
      (tester) async {
        final rows = List.generate(1000, (i) => _Row(i));
        final controller = UtenEditableGridController<_Row>(initial: rows);
        final router = GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => Scaffold(
                body: ListView(
                  children: [
                    UtenEditableGrid<_Row>(
                      controller: controller,
                      stickyHeader: false,
                      showAddRow: false,
                      showRowDelete: false,
                      selectable: true,
                      selectedOf: external
                          ? (row) => row.includedInSubmission
                          : null,
                      onRowSelect: external
                          ? (row, next) => row.includedInSubmission = next
                          : null,
                      columns: [
                        EditableGridColumn<_Row>(
                          key: 'name',
                          label: 'Name',
                          width: 200,
                          textOf: (row) => 'row-${row.index}',
                          cellBuilder: (_, row) => Text('row-${row.index}'),
                        ),
                        EditableGridColumn<_Row>(
                          key: 'note',
                          label: 'Note',
                          width: 240,
                          textOf: (row) => row.note.text,
                          cellBuilder: (_, row) =>
                              TextField(controller: row.note),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            GoRoute(
              path: '/detail',
              builder: (_, _) => const Scaffold(body: Text('detail')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        final table = tester.state(find.byType(UtenEditableGrid<_Row>));
        for (var visit = 0; visit < 6; visit++) {
          controller.selectAll();
          rows.first.note.text = '未保存的业务输入 $visit';
          await tester.pump();
          router.push<void>('/detail');
          await tester.pumpAndSettle();
          router.pop();
          await tester.pumpAndSettle();
          expect(
            tester.state(find.byType(UtenEditableGrid<_Row>)),
            same(table),
          );
          expect(controller.selectedCount, external && visit.isEven ? 1000 : 0);
          expect(rows.every((row) => row.includedInSubmission), isTrue);
          expect(rows.first.note.text, '未保存的业务输入 $visit');
          expect(controller.length, 1000);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
