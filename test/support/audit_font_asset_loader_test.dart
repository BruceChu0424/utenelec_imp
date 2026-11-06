import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_font_asset_loader_io.dart'
    if (dart.library.js_interop) 'audit_font_asset_loader_web.dart';
import 'audit_screenshot_support.dart' show loadAuditScreenshotFonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const testFamily = kIsWeb ? 'FlutterTest' : 'Ahem';
  double width(String family) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'iiiiiiii',
        style: TextStyle(fontFamily: family, fontSize: 20),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    try {
      return painter.width;
    } finally {
      painter.dispose();
    }
  }

  test('audit fonts read the actual bundled font bytes', () async {
    final bytes = await loadAuditFontAsset('assets/fonts/NotoSansSCFull.ttf');
    expect(bytes.lengthInBytes, greaterThan(4));
  });

  testWidgets('a missing audit font remains a real asset failure', (
    tester,
  ) async {
    enableAuditFontMetrics();
    const missing = 'fonts/__uten_missing_font_fixture__.ttf';
    await tester.runAsync(
      () => expectLater(
        () => loadAuditFontAsset(missing),
        throwsA(
          kIsWeb
              ? isA<StateError>().having(
                  (error) => error.message,
                  'HTTP failure',
                  contains('HTTP 404'),
                )
              : isA<FlutterError>().having(
                  (error) => error.toString(),
                  'missing asset',
                  contains(missing),
                ),
        ),
      ),
    );
  });

  for (final round in [1, 2]) {
    testWidgets(
      'audit font registration restores each test and repeats safely $round',
      (tester) async {
        if (kIsWeb) {
          expect(
            width('NotoSansSC'),
            width(testFamily),
            reason: 'The previous test restored its exact font policy',
          );
        }
        await loadAuditScreenshotFonts(tester);
        final measured = width('NotoSansSC');
        expect(measured, greaterThan(0));
        expect(measured, lessThan(width(testFamily)));
        await loadAuditScreenshotFonts(tester);
        expect(
          width('NotoSansSC'),
          measured,
          reason: 'A repeated call keeps the same actual glyphs',
        );
      },
    );
  }
  testWidgets('audit font policy is restored after consecutive tests', (
    tester,
  ) async {
    if (kIsWeb) {
      expect(width('NotoSansSC'), width(testFamily));
    } else {
      expect(width('NotoSansSC'), lessThan(width(testFamily)));
    }
  });
}
