import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import '../../support/print_test_font.dart';

late Uint8List _fontBytes;

PrintPdfRequest _request() => PrintPdfRequest.orgChart(
  title: 'Organization chart',
  fontBytes: _fontBytes,
  subtitle: 'Synthetic authorized snapshot',
  lines: [
    const OrgChartPrintLine(
      kind: 'department',
      depth: 0,
      text: 'Department',
      detail: '1800 people',
    ),
    const OrgChartPrintLine(
      kind: 'manager',
      depth: 0,
      text: 'Manager (direct)',
      bold: true,
    ),
    for (var index = 0; index < 1800; index++)
      OrgChartPrintLine(
        kind: 'member',
        depth: 0,
        text: 'Original member $index - original position',
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => _fontBytes = await loadPrintTestFontBytes());
  test(
    'organization chart uses the shared worker and complete A4 portrait pages',
    () async {
      final generator = IsolatedPrintPdfGenerator();
      addTearDown(generator.dispose);
      var ticks = 0;
      final clock = Stopwatch()..start();
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final bytes = await generator.generate(_request());
      timer.cancel();
      expect(bytes.take(5), '%PDF-'.codeUnits);
      final pdf = latin1.decode(bytes);
      final mediaBox = RegExp(
        r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]',
      ).firstMatch(pdf)!;
      expect(double.parse(mediaBox[1]!), closeTo(595.28, .1));
      expect(double.parse(mediaBox[2]!), closeTo(841.89, .1));
      final pageCounts = RegExp(
        r'/Count\s+(\d+)',
      ).allMatches(pdf).map((match) => int.parse(match[1]!));
      expect(pageCounts.any((count) => count > 20), isTrue);
      expect(
        ticks,
        greaterThan(1),
        reason: 'layout must not execute on the UI isolate',
      );
      debugPrint(
        'org-chart-worker ${jsonEncode({'web': kIsWeb, 'people': 1800, 'bytes': bytes.length, 'elapsedMs': clock.elapsedMilliseconds, 'uiTicks': ticks, 'pages': pageCounts.toList()})}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'retiring the owner prevents organization-chart bytes from being delivered',
    () async {
      final generator = IsolatedPrintPdfGenerator();
      addTearDown(generator.dispose);
      final pending = generator.generate(_request());
      final refused = expectLater(pending, throwsA(isA<UiWorkCancelled>()));
      Timer.run(generator.dispose);
      await refused;
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
