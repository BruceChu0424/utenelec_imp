import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/print/print_pdf_document.dart';

void main() {
  test(
    'large landscape PDF records allocation layout and balanced-save heartbeat separately',
    () async {
      final table = UtenPrintTable(
        headers: const ['Item', 'Exact amount'],
        rows: [
          for (var i = 0; i < 2800; i++) ['item-$i', '$i.12345678'],
        ],
      );
      final elapsed = Stopwatch()..start();
      var phase = 'rows';
      var previousBeat = 0;
      final ticks = <String, int>{};
      final maxGapMs = <String, int>{};
      final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = elapsed.elapsedMilliseconds;
        final gap = now - previousBeat;
        previousBeat = now;
        ticks[phase] = (ticks[phase] ?? 0) + 1;
        if (gap > (maxGapMs[phase] ?? 0)) maxGapMs[phase] = gap;
      });
      addTearDown(heartbeat.cancel);
      final font = pw.Font.helvetica();
      final rows = await buildPrintPdfRows(
        PrintPdfRequest(
          title: 'Large table',
          headers: table.headers,
          rows: table.rows,
        ),
        font,
      );
      final rowsMs = elapsed.elapsedMilliseconds;
      phase = 'layout';
      final layoutStarted = elapsed.elapsedMilliseconds;
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(28),
          maxPages: table.rows.length + 2,
          build: (_) => [
            pw.Center(
              child: pw.Text(
                'Large table',
                style: pw.TextStyle(
                  font: font,
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Table(border: pw.TableBorder.all(width: 0.5), children: rows),
          ],
        ),
      );
      final layoutMs = elapsed.elapsedMilliseconds - layoutStarted;
      // Let the pending heartbeat observe the complete synchronous layout span.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      phase = 'save';
      previousBeat = elapsed.elapsedMilliseconds;
      final saveStarted = elapsed.elapsedMilliseconds;
      final bytes = await doc.save(enableEventLoopBalancing: true);
      final saveMs = elapsed.elapsedMilliseconds - saveStarted;
      heartbeat.cancel();
      final pages = doc.document.pdfPageList.pages.length;
      expect(pages, greaterThanOrEqualTo(70));
      expect(bytes.take(5), '%PDF-'.codeUnits);
      expect(ticks['rows'], greaterThan(0));
      expect(ticks['save'], greaterThan(0));
      debugPrint(
        'print-pdf-heartbeat ${jsonEncode({'web': kIsWeb, 'rows': table.rows.length, 'pages': pages, 'bytes': bytes.length, 'rowsMs': rowsMs, 'layoutMs': layoutMs, 'saveMs': saveMs, 'ticks': ticks, 'maxGapMs': maxGapMs})}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
