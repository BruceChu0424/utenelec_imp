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
  });

  final String title;
  final String? subtitle;
  final List<String> headers;
  final List<List<String>> rows;
  final List<double>? columnWidths;
  final Uint8List? fontBytes;
}

/// Runs completely in a native isolate or dedicated same-origin Web Worker.
/// Keep the existing paper, typography, natural PDF pagination and raw strings.
Future<Uint8List> renderPrintPdf(PrintPdfRequest request) async {
  final font = request.fontBytes == null
      ? pw.Font.helvetica()
      : pw.Font.ttf(ByteData.sublistView(request.fontBytes!));
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
