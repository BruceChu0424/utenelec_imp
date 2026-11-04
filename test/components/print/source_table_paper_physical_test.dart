@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/print/source_table_paper.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> fixtures;
  late Uint8List font;
  setUpAll(() async {
    fixtures = Map<String, dynamic>.from(
      jsonDecode(
            await File('contracts/finance-paper-layout/v2.json').readAsString(),
          )
          as Map,
    );
    font = await File('assets/fonts/NotoSansSCFull.ttf').readAsBytes();
  });
  test('new source paper requires matching source and geometry versions', () {
    final fixture = Map<String, dynamic>.from(
      fixtures['subcontractStatement'] as Map,
    );
    final layout = Map<String, dynamic>.from(fixture['layout'] as Map);
    expect(
      SourceTablePaper.parse(layout, expectedColumns: 19).raw['version'],
      2,
    );
    layout['geometrySha256'] = '0' * 64;
    expect(
      () => SourceTablePaper.parse(layout, expectedColumns: 19),
      throwsFormatException,
    );
    layout['version'] = 3;
    expect(
      () => SourceTablePaper.parse(layout, expectedColumns: 19),
      throwsFormatException,
    );
  });
  test(
    'the production Java frozen codec packet renders decimal-text geometry without changing facts',
    () async {
      final frozen = Map<String, dynamic>.from(
        jsonDecode(
              await File(
                'contracts/finance-paper-layout/v2-frozen.json',
              ).readAsString(),
            )
            as Map,
      );
      for (final entry in frozen.entries) {
        final packet = Map<String, dynamic>.from(entry.value as Map),
            layout = Map<String, dynamic>.from(packet['layout'] as Map),
            source = Map<String, dynamic>.from(layout['sourcePrint'] as Map);
        expect(layout['version'], 2);
        expect(layout['headerRow'], isA<int>());
        expect((layout['widths'] as List).first, isA<String>());
        expect((source['columnWidthsPoints'] as List).first, isA<String>());
        expect((source['marginsPoints'] as Map)['left'], '54.0');
        final before = jsonEncode(packet);
        final bytes = await renderSourceTablePaper(before, font);
        expect(jsonEncode(packet), before);
        if (Platform.environment['FINANCE_CAPTURE_PAPER'] == 'true') {
          final file = File(
            'tmp/pdfs/finance-paper-v2/frozen-${entry.key}.pdf',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
        }
      }
    },
  );
  test(
    'new originals render full physical column bands without changing facts',
    () async {
      for (final entry in fixtures.entries) {
        final fixture = Map<String, dynamic>.from(entry.value as Map);
        final before = jsonEncode(fixture['rows']);
        final bytes = await renderSourceTablePaper(jsonEncode(fixture), font);
        expect(bytes.take(5), '%PDF-'.codeUnits);
        expect(jsonEncode(fixture['rows']), before);
        if (Platform.environment['FINANCE_CAPTURE_PAPER'] == 'true') {
          final output = File('tmp/pdfs/finance-paper-v2/${entry.key}.pdf');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'unproved fit settings cannot silently replace the physical source',
    () async {
      final fixture = Map<String, dynamic>.from(
        fixtures['supplierStatement'] as Map,
      );
      final layout = Map<String, dynamic>.from(fixture['layout'] as Map);
      final setup = Map<String, dynamic>.from(layout['sourcePrint'] as Map);
      setup['fitToPage'] = true;
      layout['sourcePrint'] = setup;
      await expectLater(
        renderSourceTablePaper(
          jsonEncode({...fixture, 'layout': layout}),
          font,
        ),
        throwsFormatException,
      );
    },
  );
  test('a physical original rejects a number taller than a page', () async {
    final fixture = Map<String, dynamic>.from(
      fixtures['supplierStatement'] as Map,
    );
    final rows = [
      for (final row in fixture['rows'] as List) List<String>.from(row as List),
    ];
    rows.single[4] = '9' * 12000;
    await expectLater(
      renderSourceTablePaper(jsonEncode({...fixture, 'rows': rows}), font),
      throwsFormatException,
    );
  });
  test(
    'complete item code and date tails wrap without lowering their source font',
    () async {
      final fixture = Map<String, dynamic>.from(
        fixtures['supplierStatement'] as Map,
      );
      final rows = [
        for (final row in fixture['rows'] as List)
          List<String>.from(row as List),
      ];
      rows.single[0] = '2026-09-08T12:34:56+08:00';
      rows.single[1] = 'BODY-CODE-ORIGINAL-TAIL-1234567890';
      rows.single[2] = '原产品完整名称图号-ORIGINAL-GOODS-END-1234567890';
      final original = jsonEncode(rows);
      final bytes = await renderSourceTablePaper(
        jsonEncode({...fixture, 'rows': rows}),
        font,
      );
      expect(jsonEncode(rows), original);
      if (Platform.environment['FINANCE_CAPTURE_PAPER'] == 'true') {
        final file = File('tmp/pdfs/finance-paper-v2/complete-body-values.pdf');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
    },
  );
  test(
    '2501 physical rows remain complete and cancellable in the actual isolate',
    () async {
      final fixture = Map<String, dynamic>.from(
        fixtures['subcontractStatement'] as Map,
      );
      final original = List<String>.from(
        (fixture['rows'] as List).single as List,
      );
      final rows = [for (int i = 0; i < 2501; i++) List<String>.from(original)];
      rows.last[2] = 'LAST-PHYSICAL-2501';
      rows.last[18] = '99887766.000000000000000000000001';
      final layout = Map<String, dynamic>.from(fixture['layout'] as Map),
          footer = Map<String, dynamic>.from(layout['footer'] as Map),
          footerCells = [
            for (final cell in footer['cells'] as List)
              Map<String, dynamic>.from(cell as Map),
          ];
      footerCells.lastWhere(
        (cell) => cell['type'] == 'money' && cell['column'] == 16,
      )['value'] = '11223344.000000000000000000000009';
      layout['footer'] = {...footer, 'cells': footerCells};
      final payload = await encodeSourceTablePaper(
        layout: layout,
        headers: List<String>.from(fixture['headers'] as List),
        rows: rows,
      );
      final request = PrintPdfRequest.binary(
        kind: sourceTablePaperRendererKind,
        payload: payload,
        renderer: renderSourceTablePaper,
        fontBytes: font,
      );
      final generator = IsolatedPrintPdfGenerator();
      addTearDown(generator.dispose);
      var ticks = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 4),
        (_) => ticks++,
      );
      addTearDown(heartbeat.cancel);
      final bytes = await generator.generate(request);
      heartbeat.cancel();
      expect(ticks, greaterThan(10));
      expect(bytes.take(5), '%PDF-'.codeUnits);
      if (Platform.environment['FINANCE_CAPTURE_PAPER'] == 'true') {
        final output = File(
          'tmp/pdfs/finance-paper-v2/complete-2501-physical.pdf',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes);
      }
      final cancelled = IsolatedPrintPdfGenerator();
      final pending = cancelled.generate(request);
      final checked = expectLater(pending, throwsA(isA<UiWorkCancelled>()));
      Timer.run(cancelled.dispose);
      await checked;
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'a merged financial footer moves intact across a vertical page boundary',
    () async {
      final fixture = Map<String, dynamic>.from(
        fixtures['subcontractStatement'] as Map,
      );
      final rows = [
        for (int i = 0; i < 287; i++)
          List<String>.from((fixture['rows'] as List).single as List),
      ];
      final layout = Map<String, dynamic>.from(fixture['layout'] as Map),
          footer = Map<String, dynamic>.from(layout['footer'] as Map),
          cells = [
            for (final cell in footer['cells'] as List)
              Map<String, dynamic>.from(cell as Map),
          ];
      cells.firstWhere(
        (cell) => cell['type'] == 'money' && cell['column'] == 16,
      )['value'] = '12345678901234.000000000000000000000001';
      cells.lastWhere(
        (cell) => cell['type'] == 'money' && cell['column'] == 16,
      )['value'] = '887766.000000000000000000000006';
      layout['footer'] = {...footer, 'cells': cells};
      final bytes = await renderSourceTablePaper(
        jsonEncode({...fixture, 'layout': layout, 'rows': rows}),
        font,
      );
      if (Platform.environment['FINANCE_CAPTURE_PAPER'] == 'true') {
        final file = File('tmp/pdfs/finance-paper-v2/boundary-footer.pdf');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
    },
  );
}
