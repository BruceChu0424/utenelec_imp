@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import 'package:uten_imp/core/print/source_table_paper.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

late Map<String, dynamic> _fixtures;
late Uint8List _font;
Map<String, dynamic> _fixture(String key) =>
    Map<String, dynamic>.from(_fixtures[key] as Map);
List<List<String>> _rows(Map<String, dynamic> value) => [
  for (final row in value['rows'] as List) List<String>.from(row as List),
];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    _fixtures = Map<String, dynamic>.from(
      jsonDecode(
            await File('contracts/finance-paper-layout/v1.json').readAsString(),
          )
          as Map,
    );
    _font = await File('assets/fonts/NotoSansSCFull.ttf').readAsBytes();
  });
  test(
    'source positions drive the four original paper layouts and preserve exact footer strings',
    () {
      for (final entry in {
        'subcontractStatement': 3,
        'supplierStatement': 5,
        'otherReceivableStatement': 2,
        'clientStatement': 3,
      }.entries) {
        final fixture = _fixture(entry.key),
            layout = SourceTablePaper.parse(
              fixture['layout'],
              expectedColumns: (fixture['headers'] as List).length,
            );
        expect(layout.headerRow, entry.value);
        expect(layout.landscape, isFalse);
        expect(
          layout.footer
              .where((cell) => cell['type'] == 'money')
              .every(
                (cell) => cell['value'] == null || cell['value'] is String,
              ),
          isTrue,
        );
      }
      final material = SourceTablePaper.parse(
        _fixture('otherReceivableStatement')['layout'],
        expectedColumns: 10,
      );
      expect(material.headerRow + 1 + material.minimumRows, 40);
      expect(material.hidden, containsAll([11, 12, 13, 14, 15, 16]));
      expect(
        material.footer.singleWhere(
          (cell) => cell['rowOffset'] == 0 && cell['column'] == 3,
        )['value'],
        '100.123456789012345678901234',
      );
    },
  );
  test(
    'frozen geometry may be text while monetary cells must remain exact decimal text',
    () {
      final fixture = _fixture('otherReceivableStatement'),
          layout = Map<String, dynamic>.from(fixture['layout'] as Map);
      layout['widths'] = [
        for (final width in layout['widths'] as List) width.toString(),
      ];
      layout['rowHeight'] = layout['rowHeight'].toString();
      layout['headingRowHeights'] = {
        for (final entry in (layout['headingRowHeights'] as Map).entries)
          entry.key.toString(): entry.value.toString(),
      };
      expect(
        SourceTablePaper.parse(layout, expectedColumns: 10).widths,
        hasLength(17),
      );
      final footer = Map<String, dynamic>.from(layout['footer'] as Map),
          cells = [
            for (final cell in footer['cells'] as List)
              Map<String, dynamic>.from(cell as Map),
          ];
      cells.firstWhere((cell) => cell['type'] == 'money')['value'] =
          100.123456789;
      layout['footer'] = {...footer, 'cells': cells};
      expect(
        () => SourceTablePaper.parse(layout, expectedColumns: 10),
        throwsFormatException,
      );
    },
  );
  test(
    'public print builder selects the source worker contract without changing any amount',
    () async {
      final fixture = _fixture('supplierStatement'),
          headers = List<String>.from(fixture['headers'] as List),
          rows = _rows(fixture);
      final request = await buildUtenPrintPdfRequest(
        UtenPrintTable(
          headers: headers,
          rows: rows,
          documentMetadata: {'paperLayout': fixture['layout']},
        ),
        title: 'same-source',
        fontBytes: _font,
      );
      expect(request.binaryKind, sourceTablePaperRendererKind);
      final packet = jsonDecode(request.binaryPayload!) as Map;
      expect((packet['rows'] as List).single, rows.single);
      expect((packet['layout'] as Map)['headerRow'], 5);
      final plain = await buildUtenPrintPdfRequest(
        const UtenPrintTable(
          headers: ['item'],
          rows: [
            ['original'],
          ],
        ),
        title: 'plain',
        fontBytes: _font,
      );
      expect(plain.binaryKind, isNull);
    },
  );
  test(
    'four anonymous PDFs render through the actual source renderer',
    () async {
      for (final key in _fixtures.keys) {
        final fixture = _fixture(key),
            bytes = await renderSourceTablePaper(jsonEncode(fixture), _font);
        expect(bytes.take(5), '%PDF-'.codeUnits);
        if (Platform.environment['FINANCE_CAPTURE_PAPER'] == 'true') {
          final file = File('tmp/pdfs/finance-original-paper/$key.pdf');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'an exact number taller than a page is rejected instead of clipped',
    () async {
      final fixture = _fixture('supplierStatement');
      final rows = _rows(fixture);
      rows.single[4] = List.filled(12000, '9').join();
      await expectLater(
        renderSourceTablePaper(jsonEncode({...fixture, 'rows': rows}), _font),
        throwsFormatException,
      );
    },
  );
  test(
    'a large original remains isolated and disposal cannot publish old paper bytes',
    () async {
      final fixture = _fixture('subcontractStatement'),
          rows = [
            for (int index = 0; index < 2501; index++)
              List<String>.from(_rows(fixture).single),
          ],
          headers = List<String>.from(fixture['headers'] as List);
      rows.last[0] = 'LAST-ORIGINAL-2501';
      final encoded = await encodeSourceTablePaper(
        layout: Map<String, dynamic>.from(fixture['layout'] as Map),
        headers: headers,
        rows: rows,
      );
      expect((jsonDecode(encoded) as Map)['rows'], hasLength(2501));
      expect(
        (((jsonDecode(encoded) as Map)['rows'] as List).last as List).first,
        'LAST-ORIGINAL-2501',
      );
      final request = PrintPdfRequest.binary(
        kind: sourceTablePaperRendererKind,
        payload: encoded,
        renderer: renderSourceTablePaper,
        fontBytes: _font,
      );
      final generator = IsolatedPrintPdfGenerator();
      addTearDown(generator.dispose);
      final clock = Stopwatch()..start();
      var ticks = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 4),
        (_) => ticks++,
      );
      addTearDown(heartbeat.cancel);
      final bytes = await generator.generate(request);
      heartbeat.cancel();
      expect(bytes.take(5), '%PDF-'.codeUnits);
      if (Platform.environment['FINANCE_CAPTURE_PAPER'] == 'true') {
        final output = File(
          'tmp/pdfs/finance-original-paper/complete-2501-original.pdf',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes);
      }
      expect(ticks, greaterThan(10));
      final retired = IsolatedPrintPdfGenerator();
      final work = retired.generate(request);
      final checked = expectLater(work, throwsA(isA<UiWorkCancelled>()));
      Timer.run(retired.dispose);
      await checked;
      expect(clock.elapsed, lessThan(const Duration(minutes: 2)));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
