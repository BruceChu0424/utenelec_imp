import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/core/theme/uten_typography.dart';

const _longAmount = '12345678901234567890.123456789012345678901234';

Widget _app({required Widget child, double scale = 1, double width = 1200}) =>
    MaterialApp(
      theme: ThemeData(
        textTheme: buildUtenTextTheme(
          primary: Colors.black,
          secondary: Colors.black87,
          tertiary: Colors.black54,
        ),
      ),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

void main() {
  for (final density in [false, true]) {
    testWidgets('圆角红底、白字，金额大于标签，紧凑=$density', (tester) async {
      await tester.pumpWidget(
        _app(
          child: UtenTotalsSummaryBar(
            density: density,
            rowCount: 5,
            entries: const [UtenTotalEntry('本次收款金额', '100.00', danger: true)],
          ),
        ),
      );
      final label = tester.widget<Text>(find.text('本次收款金额: '));
      final amount = tester.widget<Text>(find.text('100.00'));
      expect(label.style!.fontSize, 14);
      expect(amount.style!.fontSize, 16);
      expect(label.style!.color, Colors.white);
      expect(label.style!.fontWeight, FontWeight.w700);
      expect(amount.style!.color, Colors.white);
      expect(amount.style!.fontWeight, FontWeight.w800);
      expect(
        find.ancestor(
          of: find.text('100.00'),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration ==
                    const BoxDecoration(
                      color: UtenColors.errorText,
                      borderRadius: UtenRadius.smAll,
                    ),
          ),
        ),
        findsOneWidget,
      );
      expect(
        amount.style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(find.text('5 行'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窄屏和两倍字体完整显示多币种长精度金额，不裁切或缩字', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        width: 390,
        scale: 2,
        child: const UtenTotalsSummaryBar(
          compact: true,
          rowCount: 1000,
          entries: [
            UtenTotalEntry('人民币收款金额', _longAmount),
            UtenTotalEntry('美元收款金额', '9999999999999999.99999999'),
            UtenTotalEntry('空值', '—'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_longAmount), findsOneWidget);
    expect(find.text('9999999999999999.99999999'), findsOneWidget);
    expect(find.text('空值: '), findsNothing);
    for (final text in find.byType(Text).evaluate()) {
      final box = text.renderObject! as RenderBox;
      final left = box.localToGlobal(Offset.zero).dx;
      expect(left, greaterThanOrEqualTo(0));
      expect(left + box.size.width, lessThanOrEqualTo(390));
      expect((text.widget as Text).overflow, isNot(TextOverflow.ellipsis));
    }
    expect(tester.takeException(), isNull);
  });
}
