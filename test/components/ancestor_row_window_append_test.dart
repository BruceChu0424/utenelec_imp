import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart';
import 'package:uten_imp/shared/models/immutable_paged_rows.dart';

class _Row {
  const _Row(this.id, {this.height = 52});
  final int id;
  final double height;
}

typedef _Input = ({List<_Row> rows, double estimate});

Widget _app(
  ValueNotifier<_Input> source,
  UtenAncestorRowWindowController<_Row> window,
  ScrollController scroll,
) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      height: 350,
      child: SingleChildScrollView(
        controller: scroll,
        child: ValueListenableBuilder<_Input>(
          valueListenable: source,
          builder: (_, input, _) => UtenAncestorRowWindow<_Row>(
            controller: window,
            rows: input.rows,
            viewportOnly: true,
            expensiveRows: false,
            deferRowMounts: false,
            estimatedRowExtent: input.estimate,
            rowBuilder: (_, row, index) => SizedBox(
              height: row.height,
              child: Text('row-${row.id} at $index'),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final total in [35000, 100000]) {
    testWidgets('$total appended rows and moving two-slot suffix index once', (
      tester,
    ) async {
      final source = ValueNotifier<_Input>((rows: const [], estimate: 52));
      final window = UtenAncestorRowWindowController<_Row>();
      final scroll = ScrollController();
      final builder = ImmutablePagedRowsBuilder<_Row>();
      const footer = _Row(-1, height: 80);
      const summary = _Row(-2, height: 36);
      var indexed = 0, offsetRows = 0;
      debugAncestorRowWindowWorkObserver = (operation, count) {
        if (operation == 'indexRows') indexed += count;
        if (operation == 'offsetRows') offsetRows += count;
      };
      addTearDown(() {
        debugAncestorRowWindowWorkObserver = null;
        source.dispose();
        scroll.dispose();
      });
      await tester.pumpWidget(_app(source, window, scroll));
      await tester.pumpAndSettle();
      var batches = 0;
      for (var start = 0; start < total; start += 1000) {
        for (var row = start; row < start + 1000 && row < total; row++) {
          builder.add(_Row(row));
        }
        source.value = (
          rows: immutablePagedRowsWithTail(builder.snapshot(), [
            footer,
            summary,
          ]),
          estimate: 52,
        );
        batches++;
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(indexed, total + 2 * batches);
      expect(
        offsetRows,
        total + 2 * batches,
        reason: 'measured visible rows must not trigger a full offset scan',
      );
      final reveal = window.reveal(summary);
      await tester.pumpAndSettle();
      expect(await reveal, isTrue);
      expect(find.text('row--2 at ${total + 1}'), findsOneWidget);
      source.value = (
        rows: immutablePagedRowsWithTail(builder.snapshot(), [summary]),
        estimate: 52,
      );
      await tester.pumpAndSettle();
      expect(find.text('row--2 at $total'), findsOneWidget);
      expect(indexed, total + 2 * batches + 1);
      expect(offsetRows, total + 2 * batches + 1);
      final first = source.value.rows.first;
      window.retain(first, true);
      final back = window.reveal(first);
      await tester.pumpAndSettle();
      expect(await back, isTrue);
      expect(find.text('row-0 at 0'), findsOneWidget);
      window.retain(first, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'estimate changes and mutable same-list replacements force full indexing',
    (tester) async {
      final builder = ImmutablePagedRowsBuilder<_Row>();
      for (var i = 0; i < 300; i++) {
        builder.add(_Row(i));
      }
      final source = ValueNotifier<_Input>((
        rows: builder.snapshot(),
        estimate: 52,
      ));
      final window = UtenAncestorRowWindowController<_Row>();
      final scroll = ScrollController();
      var full = 0;
      debugAncestorRowWindowWorkObserver = (operation, count) {
        if (operation == 'fullReindexRows') full += count;
      };
      addTearDown(() {
        debugAncestorRowWindowWorkObserver = null;
        source.dispose();
        scroll.dispose();
      });
      await tester.pumpWidget(_app(source, window, scroll));
      await tester.pumpAndSettle();
      var before = full;
      source.value = (rows: source.value.rows, estimate: 80);
      await tester.pumpAndSettle();
      expect(full - before, 300);
      final mutable = List<_Row>.of(source.value.rows);
      source.value = (rows: mutable, estimate: 80);
      await tester.pumpAndSettle();
      before = full;
      mutable[0] = const _Row(999, height: 73);
      // ValueNotifier suppresses equal records, so explicitly notify this legal
      // mutable caller instead of manufacturing an immutable source identity.
      source.notifyListeners();
      await tester.pumpAndSettle();
      expect(full - before, 300);
      expect(find.text('row-999 at 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
