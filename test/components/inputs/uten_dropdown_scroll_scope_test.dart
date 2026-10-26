import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_scroll_scope.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';

void main() {
  testWidgets('menu hides its scrollbar and keeps wheel scrolling local', (
    tester,
  ) async {
    final menuScroll = ScrollController();
    final pageScroll = ScrollController();
    addTearDown(menuScroll.dispose);
    addTearDown(pageScroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const UtenScrollBehavior(),
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 240,
                height: 240,
                child: UtenDropdownScrollScope(
                  child: ListView.builder(
                    controller: menuScroll,
                    itemExtent: 40,
                    itemCount: 100,
                    itemBuilder: (_, index) => Text('选项 $index'),
                  ),
                ),
              ),
              SizedBox(
                width: 240,
                height: 240,
                child: ListView.builder(
                  controller: pageScroll,
                  itemExtent: 40,
                  itemCount: 100,
                  itemBuilder: (_, index) => Text('页面 $index'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final menu = find.byType(UtenDropdownScrollScope);
    expect(
      find.descendant(of: menu, matching: find.byType(Scrollbar)),
      findsNothing,
    );
    expect(find.byType(Scrollbar), findsOneWidget);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(menu),
        scrollDelta: const Offset(0, 160),
      ),
    );
    await tester.pumpAndSettle();
    expect(menuScroll.offset, greaterThan(0));
    expect(pageScroll.offset, 0);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
    testWidgets('native dropdown is scrollbar-free on $platform and selects', (
      tester,
    ) async {
      int? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          scrollBehavior: const UtenScrollBehavior(),
          home: Scaffold(
            body: Center(
              child: UtenDropdownScrollScope(
                nativeDropdown: true,
                child: DropdownButton<int>(
                  value: 0,
                  menuMaxHeight: 180,
                  items: [
                    for (var index = 0; index < 60; index++)
                      DropdownMenuItem(value: index, child: Text('选项 $index')),
                  ],
                  onChanged: (value) => picked = value,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoScrollbar), findsNothing);
      final scrollbar = find.byType(Scrollbar);
      expect(scrollbar, findsOneWidget);
      final theme = ScrollbarTheme.of(tester.element(scrollbar));
      expect(theme.thickness?.resolve({}), 0);
      expect(theme.thumbColor?.resolve({}), Colors.transparent);
      final list = find.byType(ListView);
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(0),
      );
      final choice = find.text('选项 15');
      await tester.scrollUntilVisible(choice, 100, scrollable: scrollable);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(picked, 15);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shared dropdown keeps a long menu scrollable without a bar', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const UtenScrollBehavior(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: UtenDropdownField(
                searchable: false,
                allowClear: false,
                value: null,
                items: [
                  for (var index = 0; index < 60; index++)
                    UtenDropdownItem(value: '$index', label: '选项 $index'),
                ],
                onChanged: (value) => picked = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    expect(find.byType(Scrollbar), findsNothing);
    final option = find.text('选项 30');
    await tester.scrollUntilVisible(
      option,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(picked, '30');
    expect(tester.takeException(), isNull);
  });
}
