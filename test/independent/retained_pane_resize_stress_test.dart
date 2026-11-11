import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';

void main() {
  for (final direction in TextDirection.values) {
    for (final leadingTooltip in [true, false]) {
      testWidgets(
        'retained pane ${direction.name} tooltip leading=$leadingTooltip survives 24 immediate resizes',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = const Size(1600, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final size = ValueNotifier(const Size(1280, 800));
          final input = TextEditingController(text: 'unsaved exact 7.125');
          final focus = FocusNode();
          final tooltip = GlobalKey<TooltipState>();
          final selected = ValueNotifier(41);
          addTearDown(size.dispose);
          addTearDown(input.dispose);
          addTearDown(focus.dispose);
          addTearDown(selected.dispose);
          Widget hint() => Tooltip(
            key: tooltip,
            message: 'retained active hint',
            child: const Text('source'),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: TargetPlatform.windows),
              home: Directionality(
                textDirection: direction,
                child: Scaffold(
                  body: ValueListenableBuilder<Size>(
                    valueListenable: size,
                    builder: (context, value, child) => Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox.fromSize(size: value, child: child),
                    ),
                    child: UtenSplitView(
                      minTwoPaneWidth: 840,
                      leading: Column(
                        children: [
                          if (leadingTooltip) hint(),
                          const Expanded(child: SizedBox()),
                        ],
                      ),
                      trailing: Column(
                        children: [
                          if (!leadingTooltip) hint(),
                          TextField(controller: input, focusNode: focus),
                          Expanded(
                            child: ValueListenableBuilder<int>(
                              valueListenable: selected,
                              builder: (_, value, _) =>
                                  Text('selection $value'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          focus.requestFocus();
          await tester.pumpAndSettle();
          input.value = input.value.copyWith(
            composing: const TextRange(start: 0, end: 2),
          );
          await tester.pump();
          expect(input.value.composing, const TextRange(start: 0, end: 2));
          final editor = tester.element(find.byType(EditableText));
          expect(tooltip.currentState!.ensureTooltipVisible(), true);
          await tester.pumpAndSettle();
          const sizes = [
            Size(714, 320),
            Size(1280, 800),
            Size(540, 650),
            Size(714, 420),
            Size(1280, 900),
            Size(714, 764),
          ];
          for (var i = 0; i < 24; i++) {
            size.value = sizes[i % sizes.length];
            selected.value = 41 + i;
            await tester.pump();
            expect(tester.takeException(), isNull, reason: 'resize $i');
            expect(input.text, 'unsaved exact 7.125');
            expect(input.value.composing, const TextRange(start: 0, end: 2));
            expect(tester.element(find.byType(EditableText)), same(editor));
            expect(focus.hasFocus, true);
            expect(find.text('selection ${41 + i}'), findsOneWidget);
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
