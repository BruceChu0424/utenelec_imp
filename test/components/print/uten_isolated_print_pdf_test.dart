import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import '../../support/print_test_font.dart';

late Uint8List _fontBytes;

PrintPdfRequest _request() => PrintPdfRequest(
  title: 'Large table',
  fontBytes: _fontBytes,
  headers: const ['Item', 'Exact amount'],
  rows: [
    for (var i = 0; i < 2800; i++) ['item-$i', '$i.12345678'],
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => _fontBytes = await loadPrintTestFontBytes());
  test(
    'complete 94-page PDF generation leaves the UI event loop running',
    () async {
      final generator = IsolatedPrintPdfGenerator();
      addTearDown(generator.dispose);
      final clock = Stopwatch()..start();
      var ticks = 0;
      var previous = 0;
      var maxGap = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
        final now = clock.elapsedMilliseconds;
        final gap = now - previous;
        previous = now;
        if (gap > maxGap) maxGap = gap;
        ticks++;
      });
      addTearDown(timer.cancel);
      final bytes = await generator.generate(_request());
      timer.cancel();
      expect(bytes.take(5), '%PDF-'.codeUnits);
      final counts = RegExp(
        r'/Count\s+(\d+)',
      ).allMatches(latin1.decode(bytes)).map((match) => int.parse(match[1]!));
      expect(counts, contains(94));
      expect(ticks, greaterThan(10));
      expect(
        maxGap,
        lessThan(clock.elapsedMilliseconds ~/ 2),
        reason: 'complete document layout must run outside the UI isolate',
      );
      debugPrint(
        'isolated-print-heartbeat ${jsonEncode({'web': kIsWeb, 'rows': 2800, 'pages': 94, 'bytes': bytes.length, 'totalMs': clock.elapsedMilliseconds, 'uiTicks': ticks, 'uiMaxGapMs': maxGap})}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'disposing the owner never delivers generated PDF bytes',
    () async {
      final generator = IsolatedPrintPdfGenerator();
      final future = generator.generate(_request());
      final checked = expectLater(future, throwsA(isA<UiWorkCancelled>()));
      Timer.run(generator.dispose);
      await checked;
      await expectLater(
        generator.generate(_request()),
        throwsA(isA<UiWorkCancelled>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
