import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_action_overflow.dart';

void main() {
  for (final tooltipVisible in [false, true]) {
    testWidgets('overflow real semantics menu close tooltip=$tooltipVisible', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  child: UtenActionOverflow(
                    forceCompact: true,
                    label: '表格操作',
                    children: [
                      UtenButton(onPressed: () {}, child: const Text('打印')),
                      UtenButton(onPressed: () {}, child: const Text('导出')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final trigger = find.byTooltip('表格操作').hitTestable();
        expect(trigger, findsOneWidget);
        await mouse.addPointer(location: const Offset(500, 500));
        if (tooltipVisible) {
          await mouse.moveTo(tester.getCenter(trigger));
          await tester.pump(const Duration(milliseconds: 900));
          await tester.pumpAndSettle();
          expect(find.text('表格操作'), findsWidgets);
        }
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        expect(find.text('打印').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('表格操作').hitTestable(), findsOneWidget);
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      } finally {
        semantics.dispose();
      }
    });
  }
}
