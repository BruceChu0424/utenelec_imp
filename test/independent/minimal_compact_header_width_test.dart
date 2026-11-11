import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_adaptive_hierarchy_pane.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/responsive/compact_presentation.dart';

void main() {
  for (final globalEditor in [true, false]) {
    for (final visible in [false, true]) {
      testWidgets(
        'retained compact header ${visible ? 'visible' : 'closed'} tooltip survives icon width global=$globalEditor',
        (tester) async {
          tester.view.physicalSize = const Size(900, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final input = TextEditingController(text: '7.125');
          final focus = FocusNode();
          addTearDown(input.dispose);
          addTearDown(focus.dispose);
          final Key editor = globalEditor
              ? GlobalKey()
              : const ValueKey('retained-header-editor');
          final tooltip = GlobalKey<TooltipState>();
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => UtenControlTheme(child: child!),
              home: Scaffold(
                body: UtenAdaptiveHierarchyPane(
                  canSplit: false,
                  leading: const Text('directory'),
                  trailing: const Text('result'),
                  compactHeader: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      key: editor,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Tooltip(
                          key: tooltip,
                          message: 'active header tooltip',
                          child: const Text('source'),
                        ),
                        TextField(controller: input, focusNode: focus),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<UtenCompactPresentationScope>(
                  find.byType(UtenCompactPresentationScope),
                )
                .iconSearch,
            false,
          );
          focus.requestFocus();
          await tester.pumpAndSettle();
          input.value = input.value.copyWith(
            composing: const TextRange(start: 0, end: 2),
          );
          await tester.pump();
          expect(input.value.composing, const TextRange(start: 0, end: 2));
          final element = tester.element(find.byType(EditableText));
          if (visible) {
            expect(tooltip.currentState!.ensureTooltipVisible(), isTrue);
            await tester.pumpAndSettle();
          }
          tester.view.physicalSize = const Size(500, 900);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<UtenCompactPresentationScope>(
                  find.byType(UtenCompactPresentationScope),
                )
                .iconSearch,
            true,
          );
          expect(tester.takeException(), isNull);
          expect(input.text, '7.125');
          expect(input.value.composing, const TextRange(start: 0, end: 2));
          expect(tester.element(find.byType(EditableText)), same(element));
          expect(focus.hasFocus, true);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
