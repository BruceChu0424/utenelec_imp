@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/print/print_bounds.dart';
import 'package:uten_imp/core/print/source_table_paper.dart';
import 'package:uten_imp/features/report/shared/report_print_preview.dart';

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

class _Api extends ApiClient {
  _Api(this.response) : super(Dio());
  final Map<String, dynamic> response;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => response;
}

Future<UtenPrintTable> _table(Map<String, dynamic> response) =>
    loadBoundedReportPrintPreview(
      api: _Api(response),
      endpointOf: () => '/finance/reports/gl/fixture',
      queryOf: () => {'layout': 'template'},
      isCurrent: () => true,
      rowLimit: maximumCompleteOriginalPrintRows,
      useSuggestedWidths: true,
      includeValueUnits: false,
      repeatColumnHeaders: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> fixtures;
  late Uint8List font;
  setUpAll(() async {
    fixtures = Map<String, dynamic>.from(
      jsonDecode(
            await File(
              'contracts/finance-paper-layout/financial-v1.json',
            ).readAsString(),
          )
          as Map,
    );
    font = await File('assets/fonts/NotoSansSCFull.ttf').readAsBytes();
  });
  for (final key in ['balanceSheet', 'monthlyProfit', 'annualProfit']) {
    test(
      '$key production response formats once and renders the same source paper',
      () async {
        expect(
          fixtures.containsKey(key),
          isTrue,
          reason: 'Use a real production Java response fixture',
        );
        final response = Map<String, dynamic>.from(fixtures[key] as Map),
            before = jsonEncode(response),
            table = await _table(response),
            layout = Map<String, dynamic>.from(
              table.documentMetadata['paperLayout'] as Map,
            );
        final paper = SourceTablePaper.parse(
          layout,
          expectedColumns: table.headers.length,
          expectedBodyRows: table.rows.length,
        );
        expect(paper.financial, isTrue);
        expect(paper.raw['version'], 1);
        expect(paper.columnAlignments.length, table.headers.length);
        expect(paper.minimumRows, 0);
        expect(
          table.rows.length,
          {'balanceSheet': 32, 'monthlyProfit': 20, 'annualProfit': 21}[key],
        );
        if (key == 'annualProfit') {
          final headings = (layout['headings'] as List)
              .cast<Map<Object?, Object?>>();
          final unit = headings.singleWhere(
            (heading) => heading['row'] == 2 && heading['text'] == '单位：元',
          );
          expect(unit['column'], 13);
          expect(unit['fontSize'], 11);
          expect(unit['alignment'], 'CENTER');
          expect(
            (layout['merges'] as List).cast<Map<Object?, Object?>>(),
            contains(
              equals({
                'firstRow': 2,
                'lastRow': 2,
                'firstColumn': 13,
                'lastColumn': 14,
              }),
            ),
            reason: 'The source unit heading spans N3:O3 horizontally',
          );
          final sourceRows = response['rows'] as List;
          final codes = [for (final row in sourceRows) (row as Map)['lineNo']];
          expect(codes.indexOf(33), greaterThanOrEqualTo(0));
          expect(codes.indexOf(33), lessThan(codes.indexOf(32)));
          final itemColumn = table.columnKeys!.indexOf('item');
          expect(itemColumn, greaterThanOrEqualTo(0));
          expect(
            table.rows[codes.indexOf(33)][itemColumn],
            contains('以前年度损益调整'),
          );
        }
        final request = await buildUtenPrintPdfRequest(
          table,
          title: 'UNUSED_CLIENT_TITLE',
          subtitle: 'UNUSED_CLIENT_CAPTION',
          fontBytes: font,
        );
        expect(request.binaryKind, sourceTablePaperRendererKind);
        final packet = jsonDecode(request.binaryPayload!) as Map;
        expect(packet['rows'], table.rows);
        final bytes = await renderSourceTablePaper(
          request.binaryPayload!,
          font,
        );
        expect(bytes.take(5), '%PDF-'.codeUnits);
        expect(jsonEncode(response), before);
        if (Platform.environment['FINANCE_CAPTURE_FINANCIAL_PAPER'] == 'true') {
          final out = File('build/financial-paper-qa/$key.pdf');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(bytes);
          await File(
            'build/financial-paper-qa/$key.packet.json',
          ).writeAsString(request.binaryPayload!);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
  test(
    'financial styles reject malformed alignments bands ranges and legacy leakage',
    () {
      final response = Map<String, dynamic>.from(
            fixtures['balanceSheet'] as Map,
          ),
          metadata = Map<String, dynamic>.from(
            response['documentMetadata'] as Map,
          ),
          source = Map<String, dynamic>.from(metadata['paperLayout'] as Map);
      void reject(void Function(Map<String, dynamic>) change) {
        final layout = _copy(source);
        change(layout);
        expect(
          () => SourceTablePaper.parse(
            layout,
            expectedColumns: 8,
            expectedBodyRows: 32,
          ),
          throwsFormatException,
        );
      }

      reject((m) => m['version'] = 2);
      reject((m) => (m['footer'] as Map)['minimumDataRows'] = 1);
      reject(
        (m) => (m['merges'] as List).add(
          Map.of((m['merges'] as List).first as Map),
        ),
      );
      reject(
        (m) => (m['headings'] as List).add(
          Map.of((m['headings'] as List).first as Map),
        ),
      );
      reject((m) => m['protectCompleteValues'] = false);
      reject((m) => m['columnAlignments'] = ['LEFT']);
      reject((m) => m['columnAlignments'] = List.filled(8, 'JUSTIFY'));
      reject(
        (m) => m['bodyBands'] = [
          {
            'row': 32,
            'firstColumn': 0,
            'lastColumn': 0,
            'fill': null,
            'bold': false,
          },
        ],
      );
      reject(
        (m) => m['bodyBands'] = [
          {
            'row': 0,
            'firstColumn': 0,
            'lastColumn': 8,
            'fill': null,
            'bold': false,
          },
        ],
      );
      reject(
        (m) => m['bodyBands'] = [
          {
            'row': 0,
            'firstColumn': 0,
            'lastColumn': 0,
            'fill': 'GG0000',
            'bold': false,
          },
        ],
      );
      reject(
        (m) => m['bodyBands'] = [
          {
            'row': 0,
            'firstColumn': 0,
            'lastColumn': 0,
            'fill': null,
            'bold': 'false',
          },
        ],
      );
      reject(
        (m) => m['textSpans'] = [
          {'row': 0, 'column': 0, 'start': 2, 'end': 1, 'color': 'FF0000'},
        ],
      );
      reject(
        (m) => m['textSpans'] = [
          {'row': 0, 'column': 0, 'start': 0, 'end': 1, 'color': 'red'},
        ],
      );
      reject(
        (m) => m['textSpans'] = [
          {'row': 0, 'column': 0, 'start': 0, 'end': 2, 'color': 'FF0000'},
          {'row': 0, 'column': 0, 'start': 1, 'end': 3, 'color': '0000FF'},
        ],
      );
      reject((m) => m['keepWithNextRows'] = [0, 0]);
      reject((m) => m['keepWithNextRows'] = [32]);
      final old = _copy(source)..['templateKey'] = 'supplierStatement';
      expect(
        () => SourceTablePaper.parse(old, expectedColumns: 8),
        throwsFormatException,
      );
    },
  );
  test(
    'text spans bind exact original UTF16 and cannot escape a cell',
    () async {
      final table = await _table(
        Map<String, dynamic>.from(fixtures['balanceSheet'] as Map),
      );
      final source = Map<String, dynamic>.from(
        table.documentMetadata['paperLayout'] as Map,
      );
      final rows = [for (final row in table.rows) List<String>.of(row)];
      for (final span in [
        {'row': 0, 'column': 0, 'start': 0, 'end': 1000, 'color': 'FF0000'},
        {'row': 0, 'column': 0, 'start': 1, 'end': 2, 'color': 'FF0000'},
      ]) {
        final layout = _copy(source)..['textSpans'] = [span];
        rows[0][0] = '😃';
        await expectLater(
          encodeSourceTablePaper(
            layout: layout,
            headers: table.headers,
            rows: rows,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'financial full text headings digits red annotation and footnote keep source values',
    () async {
      final table = await _table(
        Map<String, dynamic>.from(fixtures['balanceSheet'] as Map),
      );
      final layout = _copy(
        Map<String, dynamic>.from(table.documentMetadata['paperLayout'] as Map),
      );
      final rows = [for (final row in table.rows) List<String>.of(row)];
      const amount =
          '1234567890123456789012345678901234567890.123456789012345678901234';
      rows[1][2] = amount;
      rows[1][0] = '匿名完整中文项目名称与原说明文本必须全部显示';
      layout['textSpans'] = [
        {'row': 1, 'column': 0, 'start': 2, 'end': 10, 'color': 'FF0000'},
      ];
      final headings = layout['headings'] as List;
      (headings.firstWhere((e) => (e as Map)['row'] == 2 && (e)['column'] == 0)
              as Map)['text'] =
          '单位名称：${List.filled(12, '匿名公司完整名称').join()}';
      final before = jsonEncode(rows);
      final packet = await encodeSourceTablePaper(
        layout: layout,
        headers: table.headers,
        rows: rows,
        notice: 'UNUSED_CLIENT_CAPTION',
      );
      final bytes = await renderSourceTablePaper(packet, font);
      expect(bytes.take(5), '%PDF-'.codeUnits);
      expect(jsonEncode(rows), before);
      expect((jsonDecode(packet) as Map)['rows'], rows);
      if (Platform.environment['FINANCE_CAPTURE_FINANCIAL_PAPER'] == 'true') {
        final out = File('build/financial-paper-qa/balanceSheet-stress.pdf');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes);
        await File(
          'build/financial-paper-qa/balanceSheet-stress.packet.json',
        ).writeAsString(packet);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'financial preparation retires before publishing an old owner packet',
    () async {
      final table = await _table(
        Map<String, dynamic>.from(fixtures['balanceSheet'] as Map),
      );
      var current = true;
      final preparing = encodeSourceTablePaper(
        layout: Map<String, dynamic>.from(
          table.documentMetadata['paperLayout'] as Map,
        ),
        headers: table.headers,
        rows: table.rows,
        isCurrent: () => current,
      );
      current = false;
      await expectLater(preparing, throwsA(isA<UiWorkCancelled>()));
    },
  );
}
