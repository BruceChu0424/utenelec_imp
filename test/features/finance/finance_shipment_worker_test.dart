import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import '../../support/print_test_font.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'shared native/web worker keeps optional original paper headers and actor footer while UI remains responsive',
    () async {
      final font = await loadPrintTestFontBytes();
      final rows = [
        for (int i = 0; i < 1001; i++) ['source-$i', '10.0001'],
      ];
      final generator = IsolatedPrintPdfGenerator();
      addTearDown(generator.dispose);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 2),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final baseline = await generator.generate(
        PrintPdfRequest(
          title: 'Original paper',
          headers: const ['Source', 'Quantity'],
          rows: rows,
          fontBytes: font,
        ),
      );
      final withActor = await generator.generate(
        PrintPdfRequest(
          title: 'Original paper',
          headers: const ['Source', 'Quantity'],
          rows: rows,
          fontBytes: font,
          pageHeader: 'ORIGINAL-SHIPMENT-ID-001',
          pageFooter:
              'Finance actor: ORIGINAL-ACTOR; Maker: ORIGINAL-MAKER; customer signature:',
        ),
      );
      timer.cancel();
      expect(withActor.take(5), '%PDF-'.codeUnits);
      expect(withActor.length, greaterThan(baseline.length + 500));
      expect(ticks, greaterThan(10));
      final pages = RegExp(
        r'/Count\s+(\d+)',
      ).allMatches(latin1.decode(withActor)).map((m) => int.parse(m[1]!));
      expect(pages.any((n) => n > 20), isTrue);
      debugPrint(
        'shipment-worker web=$kIsWeb rows=1001 bytes=${withActor.length} ticks=$ticks',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
