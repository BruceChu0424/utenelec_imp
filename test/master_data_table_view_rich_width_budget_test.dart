import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  testWidgets(
    'background width scan reaches its complete tail without a frame per slice',
    (tester) async {
      final seen = <int>{};
      final rows = List.generate(5001, (index) => index);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 400,
              child: MasterDataTableView<int>(
                virtualized: true,
                columns: [
                  MasterColumnDef<int>(
                    key: 'name',
                    label: '名称',
                    width: 72,
                    value: (row) => '$row',
                    measureWidthOf: (_, row, _) {
                      seen.add(row);
                      return row == rows.last ? 410 : 80;
                    },
                  ),
                ],
                items: rows,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                showFullscreenToggle: false,
              ),
            ),
          ),
        ),
      );
      final frames = await tester.pumpAndSettle();
      expect(seen, containsAll(rows));
      final header = tester
          .widgetList<Container>(
            find.ancestor(
              of: find.text('名称'),
              matching: find.byType(Container),
            ),
          )
          .firstWhere(
            (container) =>
                container.constraints?.hasBoundedWidth == true &&
                container.constraints!.minWidth ==
                    container.constraints!.maxWidth,
          );
      expect(header.constraints!.maxWidth, greaterThanOrEqualTo(410));
      expect(
        frames,
        lessThan(12),
        reason:
            'unchanged widths must not require a render frame for every '
            'background measurement slice',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('slow shaping respects elapsed budget and still reaches the tail', (
    tester,
  ) async {
    var calls = 0;
    final seen = <int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 400,
            child: MasterDataTableView<int>(
              virtualized: true,
              columns: [
                MasterColumnDef<int>(
                  key: 'name',
                  label: '名称',
                  width: 72,
                  value: (row) => '$row',
                  measureWidthOf: (_, row, _) {
                    calls++;
                    seen.add(row);
                    final clock = Stopwatch()..start();
                    while (clock.elapsedMicroseconds < 2200) {}
                    return row == 39 ? 410 : 80;
                  },
                ),
              ],
              items: List.generate(40, (index) => index),
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              showFullscreenToggle: false,
            ),
          ),
        ),
      ),
    );
    expect(
      calls,
      lessThan(8),
      reason:
          'a cell-count limit alone would shape all 40 slow cells in this frame',
    );
    await tester.pumpAndSettle();
    expect(seen.length, 40);
    expect(seen, contains(39));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rich width callback and inherited geometry retire cached widths for unchanged rows',
    (tester) async {
      var calls = 0;
      final rows = [1, 2, 3];
      double first(BuildContext context, int row, TextScaler scaler) {
        calls++;
        return 100;
      }

      double second(BuildContext context, int row, TextScaler scaler) {
        calls++;
        return Theme.of(context).textTheme.bodyMedium!.fontSize! * 10;
      }

      Widget app({
        required double Function(BuildContext, int, TextScaler) measure,
        double fontSize = 20,
        bool rtl = false,
        Color color = Colors.black,
      }) => MaterialApp(
        theme: ThemeData(
          textTheme: TextTheme(
            bodyMedium: TextStyle(fontSize: fontSize, color: color),
          ),
        ),
        home: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Scaffold(
            body: MasterDataTableView<int>(
              columns: [
                MasterColumnDef<int>(
                  key: 'name',
                  label: '名称',
                  width: 72,
                  minimumWidthOf: (_) => 72,
                  value: (row) => '$row',
                  measureWidthOf: measure,
                  measureWidthScope: (fontSize, rtl),
                ),
              ],
              items: rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              showFullscreenToggle: false,
            ),
          ),
        ),
      );
      double width() => tester
          .widgetList<Container>(
            find.ancestor(
              of: find.text('名称'),
              matching: find.byType(Container),
            ),
          )
          .firstWhere(
            (container) =>
                container.constraints?.hasBoundedWidth == true &&
                container.constraints!.minWidth ==
                    container.constraints!.maxWidth,
          )
          .constraints!
          .maxWidth;
      await tester.pumpWidget(app(measure: first));
      await tester.pumpAndSettle();
      final before = calls;
      final narrow = width();
      await tester.pumpWidget(app(measure: second));
      await tester.pumpAndSettle();
      expect(calls, before + rows.length);
      expect(width(), greaterThan(narrow));
      final medium = width();
      await tester.pumpWidget(app(measure: second, fontSize: 30, rtl: true));
      await tester.pumpAndSettle();
      expect(calls, greaterThanOrEqualTo(before + rows.length * 2));
      expect(width(), greaterThan(medium));
      final beforePaint = calls;
      await tester.pumpWidget(
        app(measure: second, fontSize: 30, rtl: true, color: Colors.red),
      );
      await tester.pumpAndSettle();
      expect(
        calls,
        beforePaint,
        reason: 'paint-only theme animation does not reshape rich cells',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'rich width hooks keep frame budget and late geometry without changing values',
    (tester) async {
      var calls = 0;
      final seenScales = <double>{};
      final column = MasterColumnDef<int>(
        key: 'name',
        label: '名称',
        width: 72,
        minimumWidthOf: (_) => 72,
        value: (row) => '$row',
        exactValueOf: (row) => '$row',
        measureValueOf: (row) => 'depth:$row',
        measureWidthOf: (_, row, scaler) {
          calls++;
          seenScales.add(scaler.scale(14));
          return (row == 1200 ? 400.0 : 80.0) * scaler.scale(14) / 14;
        },
      );
      Widget app(List<int> rows, {double scale = 1}) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 400,
            child: MasterDataTableView<int>(
              virtualized: true,
              columns: [column],
              items: rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              showFullscreenToggle: false,
            ),
          ),
        ),
      );
      double width() => tester
          .widgetList<Container>(
            find.ancestor(
              of: find.text('名称'),
              matching: find.byType(Container),
            ),
          )
          .firstWhere(
            (container) =>
                container.constraints?.hasBoundedWidth == true &&
                container.constraints!.minWidth ==
                    container.constraints!.maxWidth,
          )
          .constraints!
          .maxWidth;

      final rows = [for (var i = 0; i <= 1200; i++) i];
      await tester.pumpWidget(app(rows));
      expect(calls, lessThanOrEqualTo(512));
      expect(calls, lessThan(rows.length));
      await tester.pumpAndSettle();
      expect(calls, rows.length);
      expect(width(), greaterThanOrEqualTo(400));
      final beforeBusinessRead = calls;
      expect(column.value(1200), '1200');
      expect(column.exactValueOf!(1200), '1200');
      expect(calls, beforeBusinessRead);
      expect(find.text('depth:1200'), findsNothing);
      await tester.pumpWidget(app(List.of(rows)));
      await tester.pumpAndSettle();
      expect(calls, beforeBusinessRead);
      await tester.pumpWidget(app(rows, scale: 1.6));
      await tester.pumpAndSettle();
      expect(calls, beforeBusinessRead + rows.length);
      expect(seenScales, contains(14.0));
      expect(seenScales.any((scale) => (scale - 22.4).abs() < 0.0001), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
