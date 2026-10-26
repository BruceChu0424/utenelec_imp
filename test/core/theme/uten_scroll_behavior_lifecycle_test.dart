import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Widget _app(Widget child) => MaterialApp(
  scrollBehavior: const UtenScrollBehavior(),
  theme: ThemeData(platform: TargetPlatform.windows),
  home: Scaffold(body: child),
);

Future<void> _drag(WidgetTester tester, Finder view) async {
  final rect = tester.getRect(view);
  final gesture = await tester.startGesture(
    Offset(rect.right - 5, rect.top + 32),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(0, 20));
  await tester.pump();
  await gesture.moveBy(const Offset(0, 130));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'table body keeps one custom bar while a cell scroll view gets its independent bar',
    (tester) async {
      await tester.pumpWidget(
        _app(
          MasterDataTableView<String>(
            columns: [
              MasterColumnDef<String>(
                key: 'detail',
                label: 'Detail',
                width: 280,
                value: (row) => row,
                cellBuilder: (_, row) => const SizedBox(
                  width: 260,
                  height: 80,
                  child: SingleChildScrollView(
                    key: Key('cell-scroll'),
                    primary: false,
                    child: SizedBox(height: 1400),
                  ),
                ),
              ),
            ],
            items: const ['row'],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cellView = find.byKey(const Key('cell-scroll')).hitTestable();
      final bars = find.descendant(
        of: cellView,
        matching: find.byType(Scrollbar),
      );
      expect(
        bars,
        findsOneWidget,
        reason: 'The cell owns an independent vertical viewport',
      );
      final bodyList = tester.widget<ListView>(find.byType(ListView).first);
      final cellBar = tester.widget<Scrollbar>(bars);
      expect(
        tester.getRect(bars),
        tester.getRect(cellView),
        reason:
            'The independent SDK thumb must paint at the real cell viewport edge',
      );
      expect(cellBar.controller, isNot(same(bodyList.controller)));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Scrollbar &&
              identical(widget.controller, bodyList.controller),
        ),
        findsNothing,
      );
      final cellPosition = tester
          .state<ScrollableState>(
            find.descendant(of: cellView, matching: find.byType(Scrollable)),
          )
          .position;
      await _drag(tester, cellView);
      expect(cellPosition.pixels, greaterThan(200));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'position proxy follows controller and physics replacement and detaches on removal',
    (tester) async {
      final first = ScrollController();
      final second = ScrollController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      Widget page(ScrollController controller, ScrollPhysics physics) => _app(
        SizedBox(
          width: 320,
          height: 320,
          child: ListView.builder(
            key: const Key('changing-scroll'),
            controller: controller,
            physics: physics,
            itemCount: 100,
            itemExtent: 40,
            itemBuilder: (_, index) => Text('row $index'),
          ),
        ),
      );
      await tester.pumpWidget(page(first, const ClampingScrollPhysics()));
      await tester.pumpAndSettle();
      final firstPosition = first.position;
      await _drag(tester, find.byKey(const Key('changing-scroll')));
      expect(first.offset, greaterThan(600));
      await tester.pumpWidget(page(second, const ClampingScrollPhysics()));
      await tester.pumpAndSettle();
      expect(first.hasClients, isFalse);
      expect(second.hasClients, isTrue);
      final beforePhysics = second.position;
      await tester.pumpWidget(page(second, const BouncingScrollPhysics()));
      await tester.pumpAndSettle();
      expect(second.position, isNot(same(beforePhysics)));
      expect(second.position, isNot(same(firstPosition)));
      second.jumpTo(0);
      await tester.pumpAndSettle();
      await _drag(tester, find.byKey(const Key('changing-scroll')));
      expect(second.offset, greaterThan(600));
      await tester.pumpWidget(_app(const SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(second.hasClients, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nested horizontal metrics do not alter the vertical thumb geometry',
    (tester) async {
      final vertical = ScrollController();
      final horizontal = ScrollController();
      addTearDown(vertical.dispose);
      addTearDown(horizontal.dispose);
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 320,
            height: 320,
            child: SingleChildScrollView(
              key: const Key('vertical-view'),
              controller: vertical,
              child: Column(
                children: [
                  SizedBox(
                    height: 100,
                    child: SingleChildScrollView(
                      controller: horizontal,
                      scrollDirection: Axis.horizontal,
                      child: const SizedBox(width: 6000, height: 100),
                    ),
                  ),
                  const SizedBox(height: 2800),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scrollbar), findsOneWidget);
      final view = find.byKey(const Key('vertical-view'));
      await _drag(tester, view);
      final expected = vertical.offset;
      vertical.jumpTo(0);
      horizontal.jumpTo(5000);
      await tester.pumpAndSettle();
      await _drag(tester, view);
      expect(vertical.offset, closeTo(expected, 1));
      expect(horizontal.offset, 5000);
      expect(tester.takeException(), isNull);
    },
  );
}
