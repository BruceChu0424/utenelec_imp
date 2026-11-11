import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_adaptive_hierarchy_pane.dart';

void main() {
  for (final header in [true, false]) {
    for (final visible in [false, true]) {
      testWidgets(
        'compact ${header ? 'header' : 'body'} ${visible ? 'visible' : 'closed'} tooltip survives real height boundary',
        (tester) async {
          tester.view.physicalSize = const Size(1600, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final height = ValueNotifier<double>(800);
          final input = TextEditingController(text: 'unsaved exact 7.125');
          addTearDown(height.dispose);
          addTearDown(input.dispose);
          final tooltip = GlobalKey<TooltipState>();
          Widget hint() => Tooltip(
            key: tooltip,
            message: 'same owned tooltip',
            child: const Text('source'),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<double>(
                  valueListenable: height,
                  builder: (context, value, _) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 714,
                      height: value,
                      child: UtenAdaptiveHierarchyPane(
                        canSplit: false,
                        compactHeader: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [if (header) hint(), const Text('query')],
                        ),
                        leading: const Text('directory'),
                        trailing: Column(
                          children: [
                            if (!header) hint(),
                            TextField(controller: input),
                            const Expanded(child: SizedBox()),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final editable = tester.element(find.byType(EditableText));
          if (visible) {
            expect(tooltip.currentState!.ensureTooltipVisible(), isTrue);
            await tester.pumpAndSettle();
          }
          height.value = 300;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(input.text, 'unsaved exact 7.125');
          expect(tester.element(find.byType(EditableText)), same(editable));
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
