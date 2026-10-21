import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Row extends EditableGridRow {
  _Row(this.id, this.name, this.color);
  final String id;
  final String name;
  final String color;
}

class _Layout extends PlatformTableLayoutNotifier {
  _Layout(super.tableKey);

  @override
  PlatformTableLayout build() {
    super.build();
    return const PlatformTableLayout(
      order: ['id', 'name', 'color'],
      widths: {'name': 260},
      sortColumn: 'id',
      sortAscending: false,
      hasQueryPreferences: true,
    );
  }

  @override
  void persist() {}
}

void main() {
  for (final editable in [false, true]) {
    testWidgets(
      '${editable ? 'editable' : 'master'} table clears keywords and exact values after returning to its kept page',
      (tester) async {
        const tableKey = 'search-page-return';
        final rows = UtenEditableGridController<_Row>(
          initial: [
            _Row('A', 'light switch', 'white'),
            _Row('B', 'double switch', 'grey'),
            _Row('C', 'socket', 'white'),
          ],
        );
        addTearDown(rows.dispose);
        Widget table() => editable
            ? ListView(
                children: [
                  UtenEditableGrid<_Row>(
                    tableKey: tableKey,
                    controller: rows,
                    showAddRow: false,
                    showRowDelete: false,
                    stickyHeader: false,
                    columns: [
                      for (final field in ['id', 'name', 'color'])
                        EditableGridColumn(
                          key: field,
                          label: field,
                          width: 180,
                          textOf: (row) => switch (field) {
                            'id' => row.id,
                            'name' => row.name,
                            _ => row.color,
                          },
                          filterValueOf: (row) => switch (field) {
                            'id' => row.id,
                            'name' => row.name,
                            _ => row.color,
                          },
                          cellBuilder: (_, row) => Text(
                            field == 'name' ? row.name : '',
                            key: ValueKey('$field-${row.id}'),
                          ),
                        ),
                    ],
                  ),
                ],
              )
            : MasterDataTableView<_Row>(
                tableKey: tableKey,
                columns: [
                  for (final field in ['id', 'name', 'color'])
                    MasterColumnDef(
                      key: field,
                      label: field,
                      width: 180,
                      sortable: field == 'id',
                      filterFromRows: true,
                      value: (row) => switch (field) {
                        'id' => row.id,
                        'name' => row.name,
                        _ => row.color,
                      },
                    ),
                ],
                items: rows.rows,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              );
        final rebuild = ValueNotifier(0);
        addTearDown(rebuild.dispose);
        final router = GoRouter(
          initialLocation: '/table',
          routes: [
            GoRoute(
              path: '/table',
              builder: (_, _) => Scaffold(
                body: ValueListenableBuilder(
                  valueListenable: rebuild,
                  builder: (_, _, _) => table(),
                ),
              ),
              routes: [
                GoRoute(
                  path: 'detail',
                  builder: (_, _) => const Scaffold(body: Text('detail')),
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        final container = ProviderContainer(
          overrides: [
            authenticatedScopeProvider.overrideWithValue(null),
            apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
            platformTableLayoutProvider(
              tableKey,
            ).overrideWith(() => _Layout(tableKey)),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('name').first);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          'switch',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        await tester.tap(find.text('color').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(editable ? 'white（1）' : 'white (2)'));
        await tester.pumpAndSettle();
        expect(find.text('light switch'), findsOneWidget);
        expect(find.text('double switch'), findsNothing);
        expect(find.text('socket'), findsNothing);
        rebuild.value++;
        await tester.pumpAndSettle();
        expect(find.text('double switch'), findsNothing);
        expect(find.text('socket'), findsNothing);
        router.push('/table/detail');
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('light switch'), findsOneWidget);
        expect(find.text('double switch'), findsOneWidget);
        expect(find.text('socket'), findsOneWidget);
        await tester.tap(find.text('name').first);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          'unsubmitted',
        );
        final oldSubmit = tester
            .widget<TextField>(
              find.byKey(const Key('uten-column-keyword-input')),
            )
            .onSubmitted!;
        router.push('/table/detail');
        await tester.pumpAndSettle();
        oldSubmit('unsubmitted');
        router.pop();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('uten-column-keyword-input')),
          findsNothing,
        );
        expect(find.text('light switch'), findsOneWidget);
        expect(find.text('double switch'), findsOneWidget);
        expect(find.text('socket'), findsOneWidget);
        expect(rows.rows.map((row) => row.id), ['A', 'B', 'C']);
        final layout = container.read(platformTableLayoutProvider(tableKey));
        expect(layout.filters, isEmpty);
        expect(layout.widths['name'], 260);
        expect(layout.sortColumn, 'id');
        expect(layout.sortAscending, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
