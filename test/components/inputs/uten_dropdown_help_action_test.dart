import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';

void main() {
  testWidgets(
    'disabled dropdown help stays valid while cached offscreen and scrolled through viewport',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final scroll = ScrollController();
      try {
        var changes = 0;
        const message = '状态变更请使用员工详情中的专用按钮';
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 340,
                  height: 400,
                  child: ListView(
                    controller: scroll,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(800),
                    children: [
                      const SizedBox(height: 500),
                      UtenDropdownField(
                        enabled: false,
                        label: '状态',
                        info: message,
                        value: 'active',
                        items: const [
                          UtenDropdownItem(value: 'active', label: '在职'),
                          UtenDropdownItem(value: 'resigned', label: '离职'),
                        ],
                        onChanged: (_) => changes++,
                      ),
                      const SizedBox(height: 700),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final hint = find.byType(UtenFieldHintIcon, skipOffstage: false);
        scroll.jumpTo(350);
        await tester.pump();
        expect(hint, findsOneWidget);
        expect(tester.takeException(), isNull);
        final hintSemantics = find.descendant(
          of: hint,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.label == message,
          ),
        );
        final node = tester.getSemantics(hintSemantics);
        expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), true);
        tester
            .renderObject(hintSemantics)
            .owner!
            .semanticsOwner!
            .performAction(node.id, ui.SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        expect(find.text('离职'), findsNothing);
        expect(changes, 0);
        scroll.jumpTo(0);
        await tester.pump();
        expect(tester.takeException(), isNull);
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();
        for (final offset in [900.0, 0.0, 350.0]) {
          scroll.jumpTo(offset);
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      } finally {
        semantics.dispose();
        scroll.dispose();
      }
    },
  );
  for (final accessible in [false, true]) {
    testWidgets(
      'dropdown help does not open choices through ${accessible ? 'accessibility' : 'pointer'}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          var changes = 0;
          const message = '是否收费的说明仅用于核对，不会改变所选选项。';
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 320,
                  child: UtenDropdownField(
                    label: '是否收费',
                    info: message,
                    value: 'no',
                    items: const [
                      UtenDropdownItem(value: 'no', label: '不收费'),
                      UtenDropdownItem(value: 'yes', label: '收费'),
                    ],
                    onChanged: (_) => changes++,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final hint = find.byType(UtenFieldHintIcon);
          final hintSemantics = find.descendant(
            of: hint,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.label == message,
            ),
          );
          final node = tester.getSemantics(hintSemantics);
          expect(
            node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            true,
          );
          if (accessible) {
            tester
                .renderObject(hintSemantics)
                .owner!
                .semanticsOwner!
                .performAction(node.id, ui.SemanticsAction.tap);
          } else {
            await tester.tap(hint);
          }
          await tester.pumpAndSettle();
          expect(find.text(message), findsOneWidget);
          expect(find.text('收费'), findsNothing);
          expect(changes, 0);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}
