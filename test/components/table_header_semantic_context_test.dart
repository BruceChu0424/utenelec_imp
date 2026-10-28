import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/shared/search/calendar_column_query.dart';
import 'package:uten_imp/shared/search/retain_hierarchy_filter_context.dart';
import '../support/field_hint_support.dart';

class _Row extends EditableGridRow {
  _Row(this.id, this.quantity);
  final String id;
  final String quantity;
}

Future<void> _search(WidgetTester tester, String label, String query) async {
  await tester.tap(find.text(label).hitTestable().first);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('uten-column-keyword-input')),
    query,
  );
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'an open candidate menu refreshes background data without losing the pending search',
    (tester) async {
      var refreshed = false;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) {
                change = update;
                return MasterDataTableView<String>(
                  tableKey: 'live-facets',
                  columns: [
                    MasterColumnDef(
                      key: 'supplier',
                      label: '供应商',
                      width: 220,
                      columnSearchEnabled: false,
                      value: (row) => row,
                    ),
                  ],
                  items: const ['服务端记录'],
                  onPageChange: (_) async {},
                  facets: {
                    'supplier': [
                      MasterFacetBucket(
                        value: refreshed ? 'B' : 'A',
                        label: refreshed ? 'Beta' : 'Alpha',
                        count: 1,
                      ),
                    ],
                  },
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('供应商'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        'B',
      );
      await tester.pump();
      change(() => refreshed = true);
      await tester.pumpAndSettle();
      expect(find.text('Beta (1)'), findsOneWidget);
      expect(find.text('Alpha (1)'), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('uten-column-keyword-input')),
            )
            .controller!
            .text,
        'B',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an active server choice stays visible and clearable when candidates become empty',
    (tester) async {
      String? selected;
      final changes = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => MasterDataTableView<String>(
                tableKey: 'facet-caption-owner',
                columns: [
                  MasterColumnDef(
                    key: 'supplier',
                    label: '供应商',
                    width: 200,
                    columnSearchEnabled: false,
                    value: (row) => row,
                  ),
                ],
                items: const ['服务端记录'],
                onPageChange: (_) async {},
                facets: {
                  'supplier': selected == null
                      ? const [
                          MasterFacetBucket(
                            value: 'uuid-A',
                            label: '供应商甲',
                            count: 1,
                          ),
                        ]
                      : const [],
                },
                nullCounts: const {},
                filters: {'supplier': selected},
                onFilterChanged: (_, value) {
                  changes.add(value);
                  update(() => selected = value);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('供应商'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('供应商甲 (1)'));
      await tester.pumpAndSettle();
      expect(selected, 'uuid-A');
      expect(find.text('供应商甲'), findsOneWidget);
      await tester.tap(find.text('供应商甲'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('uten-column-keyword-input')),
        findsOneWidget,
      );
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      expect(changes, ['uuid-A', null]);
      expect(find.text('供应商'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'calendar prefixes and inclusive ranges retain leap days and reject guessed dates',
    () {
      expect(
        CalendarColumnQuery.tryParse('2024-02')!.matches('2024-02-29 23:59'),
        isTrue,
      );
      expect(
        CalendarColumnQuery.tryParse('2024-02')!.matches('2024-03-01 00:00'),
        isFalse,
      );
      expect(
        CalendarColumnQuery.tryParse(
          '2024-02-29..2024-03-01',
        )!.matches('2024-03-01'),
        isTrue,
      );
      expect(
        CalendarColumnQuery.tryParse('2024')!.matches('2024-12-31'),
        isTrue,
      );
      for (final invalid in [
        '2026-02-29',
        '2024-04-31',
        '2024-2',
        '2024-03..2024-02',
        '2024-02-01..',
        '..2024',
        '2024..2025..2026',
      ]) {
        expect(CalendarColumnQuery.tryParse(invalid), isNull, reason: invalid);
      }
      for (final unknown in [null, '未记录', '3天前', '2024-02', '2024-02-30']) {
        expect(CalendarColumnQuery.tryParse('2024')!.matches(unknown), isFalse);
      }
    },
  );

  testWidgets(
    'local dates apply a real calendar range and leave invalid conditions editable',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<(String, String)>(
              columns: [
                MasterColumnDef(
                  key: 'id',
                  label: '单号',
                  width: 90,
                  value: (row) => row.$1,
                ),
                MasterColumnDef(
                  key: 'date',
                  label: '日期',
                  width: 220,
                  type: 'date',
                  sortable: true,
                  filterFromRows: true,
                  value: (row) => row.$2,
                ),
              ],
              items: const [
                ('A', '2024-02-29 23:59'),
                ('B', '2024-03-01 00:00'),
                ('U', '未记录'),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _search(tester, '日期', '2024-02-30');
      await readFieldHint(tester, CalendarColumnQuery.error);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '2024-02..2024-02',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsNothing);
      expect(find.text('U'), findsNothing);
      await tester.tap(find.text('日期：2024-02..2024-02'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      expect(find.text('U'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'integer report metadata sorts numerically and supports typed conditions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<(String, String)>(
              columns: [
                MasterColumnDef(
                  key: 'id',
                  label: '编号',
                  width: 90,
                  value: (row) => row.$1,
                ),
                MasterColumnDef(
                  key: 'count',
                  label: '记录数',
                  width: 150,
                  type: 'int',
                  sortable: true,
                  exactValueOf: (row) => row.$2,
                  value: (row) => row.$2,
                ),
              ],
              items: const [('A', '12'), ('B', '2')],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录数'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从小到大'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('B')).dy,
        lessThan(tester.getTopLeft(find.text('A')).dy),
      );
      await _search(tester, '记录数', '>=10');
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsNothing);
    },
  );

  for (final editor in [false, true]) {
    testWidgets(
      '${editor ? 'editable' : 'master'} numeric matching restores business group context without changing source rows',
      (tester) async {
        final rows = [
          _Row('P1', '0'),
          _Row('C1', '5'),
          _Row('C2', '1'),
          _Row('P2', '0'),
          _Row('C3', '9'),
        ];
        final controller = UtenEditableGridController<_Row>(initial: rows);
        addTearDown(controller.dispose);
        List<_Row> context(List<_Row> all, List<_Row> matched) =>
            retainMatchedPreorderGroups(
              all,
              matched,
              isGroupStart: (row) => row.id.startsWith('P'),
            );
        final table = editor
            ? UtenEditableGrid<_Row>(
                controller: controller,
                showAddRow: false,
                showRowDelete: false,
                showColumnSettings: false,
                filterContextRows: context,
                headerFilterScopeDescription: '按产品组保留父子上下文',
                columns: [
                  EditableGridColumn(
                    key: 'id',
                    label: '编号',
                    width: 100,
                    textOf: (row) => row.id,
                    cellBuilder: (_, row) => Text(row.id),
                  ),
                  EditableGridColumn(
                    key: 'qty',
                    label: '数量',
                    width: 200,
                    numeric: true,
                    textOf: (row) => row.quantity,
                    exactValueOf: (row) => row.quantity,
                    cellBuilder: (_, row) => Text(row.quantity),
                  ),
                ],
              )
            : MasterDataTableView<_Row>(
                embedded: true,
                filterContextRows: context,
                headerFilterScopeDescription: '按产品组保留父子上下文',
                columns: [
                  MasterColumnDef(
                    key: 'id',
                    label: '编号',
                    width: 100,
                    value: (row) => row.id,
                  ),
                  MasterColumnDef(
                    key: 'qty',
                    label: '数量',
                    width: 200,
                    type: 'number',
                    value: (row) => row.quantity,
                    exactValueOf: (row) => row.quantity,
                  ),
                ],
                items: rows,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ListView(children: [table])),
          ),
        );
        await tester.pumpAndSettle();
        await _search(tester, '数量', '=5');
        for (final id in ['P1', 'C1', 'C2']) {
          expect(find.text(id), findsOneWidget);
        }
        for (final id in ['P2', 'C3']) {
          expect(find.text(id), findsNothing);
        }
        expect(controller.rows.length, 5);
        for (var i = 0; i < rows.length; i++) {
          expect(identical(controller.rows[i], rows[i]), isTrue);
        }
        await tester.tap(find.text('数量：=5'));
        await tester.pumpAndSettle();
        expect(find.textContaining('按产品组保留父子上下文'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Tooltip &&
                (widget.message?.contains('按产品组保留父子上下文') ?? false),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('所有'));
        await tester.pumpAndSettle();
        expect(find.text('P2'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'matching one revision side keeps its full old and new comparison',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenRevisionTable<String>(
              columns: [
                MasterColumnDef(
                  key: 'amount',
                  label: '金额',
                  width: 220,
                  type: 'money',
                  value: (value) => value,
                  exactValueOf: (value) => value,
                ),
              ],
              rows: const [
                UtenRevisionRow(value: '1', kind: UtenRevisionKind.removed),
                UtenRevisionRow(
                  value: '2',
                  kind: UtenRevisionKind.added,
                  changedKeys: {'amount'},
                ),
                UtenRevisionRow(value: '9', kind: UtenRevisionKind.unchanged),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _search(tester, '金额', '=2');
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('9'), findsNothing);
      expect(
        tester.getTopLeft(find.text('1')).dy,
        lessThan(tester.getTopLeft(find.text('2')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
