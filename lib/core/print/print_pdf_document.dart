import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../performance/ui_work_budget.dart';

/// Authorised, already formatted data. No credentials, repository or UI state
/// cross the worker boundary. Null font bytes are only for Latin test fixtures.
class PrintPdfRequest {
  const PrintPdfRequest({
    required this.title,
    required this.headers,
    required this.rows,
    this.subtitle,
    this.columnWidths,
    this.fontBytes,
  }) : orgChartLines = null,
       binaryKind = null,
       binaryPayload = null,
       binaryRenderer = null;

  const PrintPdfRequest.orgChart({
    required this.title,
    required List<OrgChartPrintLine> lines,
    this.subtitle,
    this.fontBytes,
  }) : orgChartLines = lines,
       headers = const [],
       rows = const [],
       columnWidths = null,
       binaryKind = null,
       binaryPayload = null,
       binaryRenderer = null;

  /// An authorised, bounded feature payload. The web composition root owns the
  /// renderer whitelist; the native callback must be a pure top-level function.
  const PrintPdfRequest.binary({
    required String kind,
    required String payload,
    required Future<Uint8List> Function(String, Uint8List?) renderer,
    this.fontBytes,
  }) : binaryKind = kind,
       binaryPayload = payload,
       binaryRenderer = renderer,
       title = '',
       subtitle = null,
       headers = const [],
       rows = const [],
       columnWidths = null,
       orgChartLines = null;

  final String title;
  final String? subtitle;
  final List<String> headers;
  final List<List<String>> rows;
  final List<double>? columnWidths;
  final Uint8List? fontBytes;
  final List<OrgChartPrintLine>? orgChartLines;
  final String? binaryKind;
  final String? binaryPayload;
  final Future<Uint8List> Function(String, Uint8List?)? binaryRenderer;
}

/// Authorised display facts only; no repository, principal or widget enters a
/// worker. A flat ordered outline also avoids recursive worker input copying.
class OrgChartPrintLine {
  const OrgChartPrintLine({
    required this.kind,
    required this.depth,
    required this.text,
    this.detail,
    this.bold = false,
  });
  final String kind; // department | manager | member
  final int depth;
  final String text;
  final String? detail;
  final bool bold;
}

/// Runs completely in a native isolate or dedicated same-origin Web Worker.
/// Keep the existing paper, typography, natural PDF pagination and raw strings.
Future<Uint8List> renderPrintPdf(PrintPdfRequest request) async {
  final font = request.fontBytes == null
      ? pw.Font.helvetica()
      : pw.Font.ttf(ByteData.sublistView(request.fontBytes!));
  if (request.orgChartLines != null) return _renderOrgChartPdf(request, font);
  final rows = await buildPrintPdfRows(request, font);
  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      maxPages: (request.rows.length + 2).clamp(20, 1 << 30),
      build: (_) => [
        pw.Center(
          child: pw.Text(
            request.title,
            style: pw.TextStyle(
              font: font,
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),
        if (request.subtitle != null && request.subtitle!.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              request.subtitle!,
              style: pw.TextStyle(font: font, fontSize: 9),
            ),
          ),
        ],
        pw.SizedBox(height: 10),
        pw.Table(
          columnWidths: {
            for (var i = 0; i < request.headers.length; i++)
              i: pw.FlexColumnWidth(request.columnWidths?[i] ?? 1),
          },
          border: pw.TableBorder.all(width: 0.5),
          children: rows,
        ),
      ],
    ),
  );
  return doc.save(enableEventLoopBalancing: true);
}

Future<Uint8List> _renderOrgChartPdf(
  PrintPdfRequest request,
  pw.Font font,
) async {
  final work = UiWorkBudget();
  final widgets = <pw.Widget>[];
  for (final line in request.orgChartLines!) {
    if (line.depth < 0 ||
        !{'department', 'manager', 'member'}.contains(line.kind)) {
      throw const FormatException('Invalid organization chart snapshot');
    }
    if (line.kind == 'department') {
      widgets.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(left: line.depth * 18.0, bottom: 4),
          child: pw.Container(
            width: double.infinity,
            color: PdfColor.fromInt(line.depth == 0 ? 0xFFDDE7F5 : 0xFFF1F1F1),
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  line.text,
                  style: pw.TextStyle(
                    font: font,
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  line.detail ?? '',
                  style: pw.TextStyle(font: font, fontSize: 9),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      widgets.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(left: line.depth * 18.0 + 14, bottom: 2),
          child: pw.Text(
            line.text,
            style: pw.TextStyle(
              font: font,
              fontSize: 9,
              fontWeight: line.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ),
      );
    }
    await work.checkpoint();
  }
  final document = pw.Document();
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      maxPages: (widgets.length + 2).clamp(20, 1 << 30),
      build: (_) => [
        pw.Center(
          child: pw.Text(
            request.title,
            style: pw.TextStyle(
              font: font,
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),
        pw.SizedBox(height: 4),
        if (request.subtitle != null)
          pw.Center(
            child: pw.Text(
              request.subtitle!,
              style: pw.TextStyle(font: font, fontSize: 9),
            ),
          ),
        pw.SizedBox(height: 12),
        ...widgets,
      ],
    ),
  );
  return document.save(enableEventLoopBalancing: true);
}

Future<List<pw.TableRow>> buildPrintPdfRows(
  PrintPdfRequest request,
  pw.Font font, {
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget();
  work.ensureCurrent();
  pw.Widget cell(String text, {bool header = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    child: pw.Text(
      text,
      textAlign: header ? pw.TextAlign.center : null,
      style: pw.TextStyle(
        font: font,
        fontSize: 8,
        fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );
  final header = <pw.Widget>[];
  for (final value in request.headers) {
    header.add(cell(value, header: true));
    await work.checkpoint();
  }
  final rows = <pw.TableRow>[
    pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFEFEF)),
      children: header,
    ),
  ];
  for (final row in request.rows) {
    final cells = <pw.Widget>[];
    for (final value in row) {
      cells.add(cell(value));
      await work.checkpoint();
    }
    rows.add(pw.TableRow(children: cells));
  }
  work.ensureCurrent();
  return rows;
}
