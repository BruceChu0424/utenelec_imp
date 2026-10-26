import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/network/api_exception.dart';
import 'purchase_order_print_document.dart';

String _shown(String value) => value.isEmpty ? '—' : value;

Future<Uint8List> renderPurchaseOrderPdf(
  PurchaseOrderPrintDocument document, {
  required pw.Font font,
}) async {
  if (!document.financeApproved) {
    throw ApiException('FINANCE_APPROVAL_REQUIRED', '采购单须财务审核通过后才能导出或打印');
  }
  final typeface = font;
  final pdf = pw.Document(
    theme: pw.ThemeData.withFont(base: typeface, bold: typeface),
  );
  final d = document;
  pw.Widget text(String value, {double size = 9, bool bold = false}) => pw.Text(
    value,
    style: pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    ),
  );
  pw.Widget pair(String left, String right) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(child: text(left)),
        pw.SizedBox(width: 12),
        pw.Expanded(child: text(right)),
      ],
    ),
  );
  pdf.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(30),
      maxPages: 1000,
      header: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(child: text(_shown(d.companyName), size: 15, bold: true)),
          pw.SizedBox(height: 10),
          pw.Row(
            children: [
              pw.Expanded(child: text('采 购 单', size: 19, bold: true)),
              text('单号：${d.billNo}', bold: true),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.Divider(color: PdfColor.fromHex('#0F766E'), thickness: 1.5),
          if (!d.financeApproved || d.statusLabel != '财务已通过')
            text('单据状态：${_shown(d.statusLabel)}', bold: true),
          pw.SizedBox(height: 6),
        ],
      ),
      footer: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 10),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            text('采购单 ${d.billNo} · 共 ${d.lines.length} 项', size: 7),
            text('第 ${context.pageNumber} / ${context.pagesCount} 页', size: 7),
          ],
        ),
      ),
      build: (_) => [
        pair('供应商：${_shown(d.supplierName)}', '订货日期：${_shown(d.billDate)}'),
        pair(
          '联系人：${_shown(d.supplierContact)}',
          '交货日期：${_shown(d.deliverDate)}',
        ),
        pair(
          '供应商电话：${_shown(d.supplierPhone)}',
          '公司电话：${_shown(d.companyPhone)}',
        ),
        pw.SizedBox(height: 8),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
          columnWidths: {
            for (var i = 0; i < PurchaseOrderPrintDocument.widths.length; i++)
              i: pw.FlexColumnWidth(PurchaseOrderPrintDocument.widths[i]),
          },
          children: [
            pw.TableRow(
              repeat: true,
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: [
                for (final value in PurchaseOrderPrintDocument.headers)
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 6,
                    ),
                    child: text(value, size: 8, bold: true),
                  ),
              ],
            ),
            for (final row in d.rows)
              pw.TableRow(
                children: [
                  for (var i = 0; i < row.length; i++)
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 3,
                      ),
                      child: pw.Align(
                        alignment: i == 7
                            ? pw.Alignment.centerRight
                            : pw.Alignment.centerLeft,
                        child: text(row[i]),
                      ),
                    ),
                ],
              ),
          ],
        ),
        pw.SizedBox(height: 8),
        pair('金额大写：${d.capitalLabel}', '合计：${d.amountLabel}'),
        pair(
          '付款方式：${d.priceMasked ? '***' : _shown(d.settlementMethod)}',
          '交货地点：${_shown(d.deliveryPlace)}',
        ),
        pw.Divider(color: PdfColors.grey500),
        text('备注：${_shown(d.remark)}'),
        pw.SizedBox(height: 30),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: text('供应商签章：')),
            pw.Expanded(child: text('制单：${_shown(d.makerName)}')),
            pw.Expanded(child: text('审核：${_shown(d.reviewerName)}')),
          ],
        ),
      ],
    ),
  );
  return pdf.save();
}
