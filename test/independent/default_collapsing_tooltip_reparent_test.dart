import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';

void main() {
  for (final inHeader in [true, false]) {
    for (final visible in [false, true]) {
      testWidgets(
        'default retained ${inHeader ? 'header' : 'body'} ${visible ? 'visible' : 'closed'} Tooltip crosses compact both ways with semantics',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            expect(SemanticsBinding.instance.semanticsEnabled, true);
            tester.view.physicalSize = const Size(1600, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final extent = ValueNotifier(const Size(320, 700));
            final input = TextEditingController(text: 'unchanged exact 7.125');
            final focus = FocusNode();
            final outer = ScrollController();
            final tooltip = GlobalKey<TooltipState>();
            addTearDown(extent.dispose);
            addTearDown(input.dispose);
            addTearDown(focus.dispose);
            addTearDown(outer.dispose);
            Widget hint() => Tooltip(
              key: tooltip,
              message: 'default viewport owned tooltip',
              child: const Text('source'),
            );
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(platform: TargetPlatform.windows),
                home: Scaffold(
                  body: ValueListenableBuilder<Size>(
                    valueListenable: extent,
                    builder: (_, size, child) => Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox.fromSize(size: size, child: child),
                    ),
                    child: UtenCollapsingHeaderScrollView(
                      controller: outer,
                      collapsingHeader: SizedBox(
                        height: 96,
                        child: inHeader ? hint() : const Text('header'),
                      ),
                      body: Column(
                        children: [
                          if (!inHeader) hint(),
                          TextField(controller: input, focusNode: focus),
                          const Expanded(
                            child: ListTile(title: Text('retained result')),
                          ),
                        ],
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
            final semanticId = tester
                .getSemantics(find.byType(EditableText))
                .id;
            if (visible) {
              expect(tooltip.currentState!.ensureTooltipVisible(), true);
              await tester.pumpAndSettle();
            }
            for (final size in [
              const Size(1280, 900),
              const Size(714, 420),
              const Size(1280, 900),
            ]) {
              extent.value = size;
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(input.text, 'unchanged exact 7.125');
              expect(input.value.composing, const TextRange(start: 0, end: 2));
              expect(tester.element(find.byType(EditableText)), same(editor));
              expect(
                tester.getSemantics(find.byType(EditableText)).id,
                semanticId,
              );
              expect(outer.positions, hasLength(1));
            }
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'retained viewport keeps pinned tab at the original extent while header and rows coordinate',
    (tester) async {
      final outer = ScrollController();
      addTearDown(outer.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 700,
              child: UtenCollapsingHeaderScrollView(
                controller: outer,
                wheelGateDistance: 0,
                wheelHoldWindow: Duration.zero,
                collapsingHeader: const SizedBox(
                  height: 120,
                  child: Text('collapsing banner'),
                ),
                pinnedHeader: const SizedBox(
                  key: ValueKey('retained-tabs'),
                  height: 48,
                  child: Text('pinned tabs'),
                ),
                pinnedHeaderExtent: 48,
                body: ListView.builder(
                  primary: true,
                  itemExtent: 48,
                  itemCount: 80,
                  itemBuilder: (_, i) => Text('row $i'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final point = tester.getCenter(find.text('row 0'));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 120)),
      );
      await tester.pumpAndSettle();
      expect(outer.offset, 120);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('retained-tabs'))).dy,
        0,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('retained-tabs'))).height,
        48,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
