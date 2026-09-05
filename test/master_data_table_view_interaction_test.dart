import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _rowText = 'ROW-WITHOUT-DETAIL';

Widget _table({
  ValueChanged<String>? onRowTap,
  bool Function(String)? canOpenRow,
  List<UtenContextMenuEntry> Function(String)? rowMenuBuilder,
  bool Function(String)? canShowRowMenu,
  ValueChanged<String>? onSelectionChanged,
  VoidCallback? onSelectionCleared,
  bool selectable = false,
  Set<String> selectedIds = const <String>{},
  ValueChanged<Set<String>>? onSelectedIdsChanged,
  List<MasterColumnDef<String>>? columns,
  List<String> items = const [_rowText],
  List<Widget>? toolbarActions,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        child: MasterDataTableView<String>(
          columns:
              columns ??
              const [
                MasterColumnDef<String>(
                  key: 'value',
                  label: '值',
                  width: 240,
                  value: _identity,
                ),
              ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: onRowTap,
          canOpenRow: canOpenRow,
          onSelectionChanged: onSelectionChanged,
          onSelectionCleared: onSelectionCleared,
          rowMenuBuilder: rowMenuBuilder,
          canShowRowMenu: canShowRowMenu,
          selectable: selectable,
          idOf: selectable ? _identity : null,
          selectedIds: selectedIds,
          onSelectedIdsChanged: onSelectedIdsChanged,
          toolbarActions: toolbarActions,
          embedded: !selectable,
        ),
      ),
    ),
  );
}

String _identity(String value) => value;

Finder _rowInkWell() =>
    find.ancestor(of: find.text(_rowText), matching: find.byType(InkWell));

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('row without callback has no tap widget or tap semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_table());
      await tester.pumpAndSettle();

      expect(find.text(_rowText), findsOneWidget);
      expect(_rowInkWell(), findsNothing);
      expect(
        tester
            .getSemantics(find.text(_rowText))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('row with callback remains tappable and exposes tap semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    try {
      await tester.pumpWidget(_table(onRowTap: (_) => taps++));
      await tester.pumpAndSettle();

      expect(_rowInkWell(), findsOneWidget);
      expect(
        tester
            .getSemantics(find.text(_rowText))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );

      await tester.tap(find.text(_rowText));
      await tester.pump();
      expect(taps, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('selection-only row remains tappable without an open callback', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      _table(onSelectionChanged: (item) => selected = item),
    );
    await tester.pumpAndSettle();

    expect(_rowInkWell(), findsOneWidget);
    await tester.tap(find.text(_rowText));
    await tester.pump();
    expect(selected, _rowText);
  });

  testWidgets(
    'row denied by canOpenRow exposes no fake tap or open semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var taps = 0;
      try {
        await tester.pumpWidget(
          _table(
            onRowTap: (_) => taps++,
            canOpenRow: (_) => false,
            rowMenuBuilder: (_) => const [],
            canShowRowMenu: (_) => false,
          ),
        );
        await tester.pumpAndSettle();

        expect(_rowInkWell(), findsNothing);
        expect(
          tester
              .getSemantics(find.text(_rowText))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );
        expect(taps, 0);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'row menu action clears selection only after async action completes',
    (tester) async {
      final actionGate = Completer<void>();
      String? selected;
      var clearCount = 0;
      var actionStarted = false;
      await tester.pumpWidget(
        _table(
          onSelectionChanged: (item) => selected = item,
          onSelectionCleared: () {
            selected = null;
            clearCount++;
          },
          rowMenuBuilder: (_) => [
            UtenMenuItem(
              label: '异步操作',
              onTap: () async {
                actionStarted = true;
                await actionGate.future;
              },
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await _rightClick(tester, find.text(_rowText));
      expect(selected, _rowText);
      await tester.tap(find.text('异步操作'));
      await tester.pump();
      expect(actionStarted, isTrue);
      expect(selected, _rowText);
      expect(clearCount, 0);

      actionGate.complete();
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(clearCount, 1);
    },
  );

  testWidgets('dismissing row menu keeps the current selection', (
    tester,
  ) async {
    String? selected;
    var clearCount = 0;
    await tester.pumpWidget(
      _table(
        onSelectionChanged: (item) => selected = item,
        onSelectionCleared: () => clearCount++,
        rowMenuBuilder: (_) => [UtenMenuItem(label: '查看', onTap: () {})],
      ),
    );
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text(_rowText));
    expect(selected, _rowText);
    await tester.tapAt(const Offset(8, 8));
    await tester.pump();
    expect(selected, _rowText);
    expect(clearCount, 0);
  });

  testWidgets('row menu action clears controlled multi-selection', (
    tester,
  ) async {
    final changes = <Set<String>>[];
    await tester.pumpWidget(
      _table(
        selectable: true,
        onSelectedIdsChanged: (ids) => changes.add(Set<String>.of(ids)),
        rowMenuBuilder: (_) => [UtenMenuItem(label: '执行', onTap: () {})],
      ),
    );
    await tester.pumpAndSettle();

    await _rightClick(tester, find.text(_rowText));
    expect(changes, [
      {_rowText},
    ]);
    await tester.tap(find.text('执行'));
    await tester.pumpAndSettle();
    expect(changes.last, isEmpty);
  });

  testWidgets('custom cell builder keeps value as accessibility fallback', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var presses = 0;
    try {
      await tester.pumpWidget(
        _table(
          columns: [
            MasterColumnDef<String>(
              key: 'action',
              label: '操作',
              width: 240,
              value: _identity,
              cellBuilder: (_, _) => TextButton(
                key: const Key('custom-cell-action'),
                onPressed: () => presses++,
                child: const Text('报工'),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('custom-cell-action')), findsOneWidget);
      expect(find.bySemanticsLabel('操作: $_rowText'), findsOneWidget);
      await tester.tap(find.byKey(const Key('custom-cell-action')));
      await tester.pump();
      expect(presses, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('successful empty state keeps business toolbar actions visible', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(
      _table(
        items: const [],
        toolbarActions: [
          TextButton(
            key: const Key('empty-create-action'),
            onPressed: () => presses++,
            child: const Text('新增'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无数据'), findsOneWidget);
    expect(find.byKey(const Key('empty-create-action')), findsOneWidget);
    await tester.tap(find.byKey(const Key('empty-create-action')));
    await tester.pump();
    expect(presses, 1);
  });

  testWidgets('context menu can reopen an async dialog after cancellation', (
    tester,
  ) async {
    late BuildContext hostContext;
    var openings = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return UtenContextMenuRegion(
                entriesBuilder: () => [
                  UtenMenuItem(
                    label: '删除动作',
                    onTap: () async {
                      openings++;
                      await showDialog<void>(
                        context: hostContext,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('确认删除'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: const Text('取消'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
                child: const SizedBox(
                  width: 120,
                  height: 60,
                  child: Center(child: Text('目标行')),
                ),
              );
            },
          ),
        ),
      ),
    );

    for (var i = 1; i <= 2; i++) {
      await _rightClick(tester, find.text('目标行'));
      await tester.tap(find.text('删除动作'));
      await tester.pumpAndSettle();
      expect(find.text('确认删除'), findsOneWidget);
      expect(openings, i);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    }
  });
}
