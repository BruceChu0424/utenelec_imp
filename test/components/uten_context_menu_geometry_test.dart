import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';

void main() {
  for (final scenario in [
    (canvas: const Size(1600, 1000), media: const Size(800, 600)),
    (canvas: const Size(320, 240), media: const Size(1200, 900)),
  ]) {
    testWidgets(
      'popup follows the actual overlay when media is ${scenario.media}',
      (tester) async {
        await tester.binding.setSurfaceSize(scenario.canvas);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final anchor = Offset(
          scenario.canvas.width - 16,
          scenario.canvas.height - 16,
        );
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: scenario.media),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showUtenContextMenu(
                    context,
                    globalPosition: anchor,
                    entries: [UtenMenuItem(label: '菜单操作', onTap: () {})],
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final menu = tester.getRect(
          find
              .ancestor(of: find.text('菜单操作'), matching: find.byType(Material))
              .first,
        );
        expect(menu.right, closeTo(anchor.dx, .1));
        expect(menu.bottom, closeTo(anchor.dy, .1));
        expect(menu.left, greaterThanOrEqualTo(8));
        expect(menu.top, greaterThanOrEqualTo(8));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
