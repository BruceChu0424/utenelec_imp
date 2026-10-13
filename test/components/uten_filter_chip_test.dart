import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_filter_chip.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double fontSize) => fontSize * (fontSize < 24 ? 2 : 1.4);
  @override
  double get textScaleFactor => 2;
}

void main() {
  for (final factor in [0.85, 1.0, 2.0]) {
    testWidgets(
      '$factor: full filter labels, intrinsic sizing and edge toggles',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final changed = <bool>[];
        var selected = true;
        const text = '参考线及完整重量调整';
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme().copyWith(platform: TargetPlatform.android),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: factor == 2
                    ? const _NonlinearScaler()
                    : TextScaler.noScaling,
              ),
              child: UtenDisplayZoomBox(
                fontFactor: factor,
                child: UtenControlTheme(child: child!),
              ),
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 132,
                  child: StatefulBuilder(
                    builder: (context, setState) => IntrinsicHeight(
                      child: Row(
                        children: [
                          Expanded(
                            child: UtenFilterChip(
                              key: const ValueKey('filter'),
                              label: const Text(text),
                              selected: selected,
                              onSelected: (value) => setState(() {
                                selected = value;
                                changed.add(value);
                              }),
                            ),
                          ),
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
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        expect(paragraph.text.toPlainText(), text);
        expect(paragraph.maxLines, isNull);
        for (final box in paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: text.length),
        )) {
          expect(box.right, lessThanOrEqualTo(paragraph.size.width + 1e-6));
          expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 1e-6));
        }
        final target = find.byKey(const ValueKey('filter'));
        final rect = tester.getRect(target);
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.right, lessThanOrEqualTo(320));
        expect(rect.bottom, lessThanOrEqualTo(640));
        await tester.tapAt(rect.bottomRight - const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(changed, [false]);
        expect(tester.widget<FilterChip>(target).selected, isFalse);
        await tester.tapAt(
          tester.getRect(target).centerRight - const Offset(2, 0),
        );
        await tester.pumpAndSettle();
        expect(changed, [false, true]);
        expect(tester.widget<FilterChip>(target).selected, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
