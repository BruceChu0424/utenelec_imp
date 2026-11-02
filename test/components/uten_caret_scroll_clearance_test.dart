import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/ui/capsule_nav_metrics.dart';

void main() {
  for (final keyboard in [0.0, 300.0]) {
    testWidgets(
      'focused mobile cell clears floating actions with keyboard $keyboard',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scroll = ScrollController();
        final text = TextEditingController();
        final field = GlobalKey();
        final actions = GlobalKey();
        addTearDown(scroll.dispose);
        addTearDown(text.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
              child: child!,
            ),
            home: Scaffold(
              body: UtenCapsuleNavScope(
                occlusion: 76,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SingleChildScrollView(
                        controller: scroll,
                        child: Column(
                          children: [
                            const SizedBox(height: 900),
                            UtenTableCellInputTheme(
                              child: TextField(key: field, controller: text),
                            ),
                            const SizedBox(height: 600),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      right: 16,
                      bottom: 92,
                      child: SizedBox(key: actions, width: 100, height: 48),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final extent = scroll.position.maxScrollExtent;
        await tester.enterText(find.byKey(field), '2.5000');
        await tester.pumpAndSettle();
        expect(text.text, '2.5000');
        expect(
          tester.getRect(find.byKey(field)).bottom,
          lessThan(tester.getRect(find.byKey(actions)).top),
        );
        expect(
          scroll.position.maxScrollExtent,
          extent,
          reason: 'focus clearance must not reserve fixed page space',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
