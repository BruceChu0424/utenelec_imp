import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(768, 560)]) {
    for (final count in [2, 100]) {
      testWidgets(
        'touch from table collapses header before rows $size count $count',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final outer = ScrollController();
          addTearDown(outer.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: UtenCollapsingHeaderScrollView(
                  controller: outer,
                  collapsingHeader: const SizedBox(
                    height: 180,
                    child: Text('信息卡'),
                  ),
                  body: MasterDataTableView<String>(
                    primary: true,
                    showColumnChooser: false,
                    showFullscreenToggle: false,
                    columns: [
                      MasterColumnDef<String>(
                        key: 'value',
                        label: '名称',
                        width: 840,
                        value: (s) => s,
                      ),
                    ],
                    items: List.generate(count, (i) => '货品$i'),
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final innerState = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.dragFrom(const Offset(220, 350), const Offset(-100, 0));
          await tester.pumpAndSettle();
          expect(
            outer.offset,
            0,
            reason: 'horizontal table scrolling must not collapse the page',
          );
          expect(innerState.position.pixels, 0);
          final gesture = await tester.startGesture(const Offset(120, 350));
          await gesture.moveBy(const Offset(0, -20));
          await tester.pump();
          await gesture.moveBy(const Offset(0, -90));
          await tester.pump();
          expect(outer.offset, greaterThan(0));
          expect(innerState.position.pixels, 0);
          await gesture.moveBy(const Offset(0, -240));
          await tester.pump();
          expect(outer.offset, closeTo(outer.position.maxScrollExtent, .01));
          expect(
            tester.getTopLeft(find.byType(MasterDataTableView<String>)).dy,
            closeTo(0, .01),
          );
          if (count > 2) expect(innerState.position.pixels, greaterThan(0));
          await tester.pump(const Duration(seconds: 1));
          await gesture.up();
          await tester.pumpAndSettle();
          await tester.dragFrom(const Offset(120, 250), const Offset(0, 450));
          await tester.pumpAndSettle();
          expect(innerState.position.pixels, closeTo(0, .01));
          expect(outer.offset, lessThan(outer.position.maxScrollExtent));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('touch momentum crosses the pin boundary and reverses in order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final outer = ScrollController();
    addTearDown(outer.dispose);
    late ScrollController inner;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenCollapsingHeaderScrollView(
            controller: outer,
            collapsingHeader: const SizedBox(
              height: 240,
              child: Text('可收起信息卡'),
            ),
            body: Builder(
              builder: (context) {
                inner = PrimaryScrollController.of(context);
                return ListView.builder(
                  primary: true,
                  itemExtent: 48,
                  itemCount: 100,
                  itemBuilder: (_, i) => Text('行$i'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.flingFrom(const Offset(140, 450), const Offset(0, -100), 1600);
    await tester.pumpAndSettle();
    expect(outer.offset, closeTo(240, .01));
    expect(inner.offset, greaterThan(0));
    await tester.flingFrom(const Offset(140, 250), const Offset(0, 180), 2400);
    await tester.pumpAndSettle();
    expect(inner.offset, closeTo(0, .01));
    expect(outer.offset, lessThan(240));
    expect(tester.takeException(), isNull);
  });
}
