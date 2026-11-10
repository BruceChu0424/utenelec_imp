import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/core/theme/uten_typography.dart';
import '../support/audit_screenshot_support.dart';

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
          matching: find.byKey(const ValueKey('uten-totals-runs')),
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

  testWidgets('换行合计仅在每行实际内容后铺红底，不铺满第二行空白', (tester) async {
    final capture = GlobalKey();
    final summary = RepaintBoundary(
      key: capture,
      child: const UtenTotalsSummaryBar(
        entries: [
          UtenTotalEntry('应收金额', '999999999'),
          UtenTotalEntry('扣款', '123'),
          UtenTotalEntry('尾款', '5'),
        ],
      ),
    );
    await tester.pumpWidget(_app(child: summary));
    await tester.pumpAndSettle();
    final firstRunWidth =
        tester.getRect(find.text('999999999')).right -
        tester.getRect(find.text('应收金额: ')).left;
    await tester.pumpWidget(_app(width: firstRunWidth + 24, child: summary));
    await tester.pumpAndSettle();
    final first = tester.getRect(find.text('999999999'));
    final second = tester.getRect(find.text('123'));
    final firstLabel = tester.getRect(find.text('应收金额: '));
    final secondLabel = tester.getRect(find.text('扣款: '));
    expect(second.top, greaterThan(first.bottom));
    expect(secondLabel.left, greaterThan(firstLabel.left + 8));
    final origin = tester.getTopLeft(find.byKey(capture));
    final probeX = ((firstLabel.left + secondLabel.left) / 2 - origin.dx)
        .floor();
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final rendered = await boundary.toImage();
      final bytes = (await rendered.toByteData())!;
      Color pixel(int x, int y) {
        final index = (y * rendered.width + x) * 4;
        return Color.fromARGB(
          bytes.getUint8(index + 3),
          bytes.getUint8(index),
          bytes.getUint8(index + 1),
          bytes.getUint8(index + 2),
        );
      }

      expect(
        pixel(probeX, (first.bottom + 1 - origin.dy).floor()),
        UtenColors.errorText,
      );
      expect(
        pixel(probeX, (second.bottom + 1 - origin.dy).floor()),
        isNot(UtenColors.errorText),
      );
      expect(
        pixel(
          (second.right - 1 - origin.dx).floor(),
          (second.bottom + 1 - origin.dy).floor(),
        ),
        UtenColors.errorText,
      );
      rendered.dispose();
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('条目内部换行与旁侧短条目不把两行背景连成卡片', (tester) async {
    await loadAuditScreenshotFonts(tester);
    final capture = GlobalKey();
    const amount = '9999999999999999999999';
    await tester.pumpWidget(
      _app(
        width: 300,
        child: RepaintBoundary(
          key: capture,
          child: const UtenTotalsSummaryBar(
            entries: [
              UtenTotalEntry('合计应收人民币金额', amount),
              UtenTotalEntry('尾款', '5'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final value = tester.getRect(find.text(amount));
    final label = tester.getRect(find.text('合计应收人民币金额: '));
    final neighbour = tester.getRect(find.text('5'));
    expect(value.top, greaterThanOrEqualTo(label.bottom - 1));
    expect(neighbour.left, greaterThan(value.right));
    expect(neighbour.top, lessThan(value.top));
    final origin = tester.getTopLeft(find.byKey(capture));
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final rendered = await boundary.toImage();
      final bytes = (await rendered.toByteData())!;
      Color pixel(double x, double y) {
        final index =
            ((y - origin.dy).floor() * rendered.width +
                (x - origin.dx).floor()) *
            4;
        return Color.fromARGB(
          bytes.getUint8(index + 3),
          bytes.getUint8(index),
          bytes.getUint8(index + 1),
          bytes.getUint8(index + 2),
        );
      }

      expect(pixel(value.center.dx, value.bottom + 1), UtenColors.errorText);
      expect(
        pixel(neighbour.center.dx, value.bottom + 1),
        isNot(UtenColors.errorText),
      );
      rendered.dispose();
    });
    if (!kIsWeb && const bool.fromEnvironment('FEEDBACK_SCREENSHOTS')) {
      await saveAuditScreenshot(tester, capture, 'totals-inner-wrap');
    }
    expect(tester.takeException(), isNull);
  });

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
