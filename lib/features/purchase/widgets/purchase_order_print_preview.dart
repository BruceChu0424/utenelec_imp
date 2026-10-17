import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/purchase_order_print_document.dart';

Future<void> showPurchaseOrderPrintPreview(
  BuildContext context,
  PurchaseOrderPrintDocument document, {
  required Future<PurchaseOrderPrintDocument> Function() loader,
  Future<bool> Function(Uint8List, String)? printer,
}) => showDialog<void>(
  context: context,
  builder: (_) => _PurchaseOrderPrintDialog(
    document: document,
    loader: loader,
    printer: printer ?? printPdfBytes,
  ),
);

class _PurchaseOrderPrintDialog extends StatefulWidget {
  const _PurchaseOrderPrintDialog({
    required this.document,
    required this.loader,
    required this.printer,
  });
  final PurchaseOrderPrintDocument document;
  final Future<PurchaseOrderPrintDocument> Function() loader;
  final Future<bool> Function(Uint8List, String) printer;
  @override
  State<_PurchaseOrderPrintDialog> createState() =>
      _PurchaseOrderPrintDialogState();
}

class _PurchaseOrderPrintDialogState extends State<_PurchaseOrderPrintDialog> {
  bool _printing = false;
  late PurchaseOrderPrintDocument _document = widget.document;
  Future<void> _print() async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      final current = await widget.loader();
      if (!mounted) return;
      if (current.signature != _document.signature) {
        setState(() => _document = current);
        context.appInfo('单据已变化，已刷新预览，请核对后再打印');
        return;
      }
      final bytes = await buildPurchaseOrderPdf(current);
      await widget.printer(bytes, '采购单-${current.billNo}.pdf');
    } catch (_) {
      if (mounted) context.appError('生成采购单失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: UtenAppBar(
        title: '预览采购单 ${_document.billNo}',
        showPagePermissionAction: false,
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          UtenButton(
            key: const Key('purchase-print-preview-print'),
            icon: Icons.print_outlined,
            isLoading: _printing,
            onPressed: _printing ? null : _print,
            child: const Text('打印'),
          ),
        ],
      ),
      body: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: PurchaseOrderPrintPaper(document: _document),
          ),
        ),
      ),
    ),
  );
}

/// Paper dimensions and type are fixed independently of the application's UI zoom.
class PurchaseOrderPrintPaper extends StatelessWidget {
  const PurchaseOrderPrintPaper({super.key, required this.document});
  final PurchaseOrderPrintDocument document;

  @override
  Widget build(BuildContext context) {
    final d = document;
    Widget text(String value, {double size = 12, bool bold = false}) => Text(
      value,
      style: TextStyle(
        fontSize: size,
        height: 1.4,
        color: const Color(0xFF18232A),
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      ),
    );
    Widget pair(String left, String right) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: text(left)),
          const SizedBox(width: 16),
          Expanded(child: text(right)),
        ],
      ),
    );
    final rows = d.rows;
    return MediaQuery.withNoTextScaling(
      child: Container(
        width: 794,
        constraints: const BoxConstraints(minHeight: 1123),
        color: Colors.white,
        padding: const EdgeInsets.all(40),
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 11, color: Color(0xFF18232A)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: text(_shown(d.companyName), size: 20, bold: true)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: text('采 购 单', size: 24, bold: true)),
                  text('单号：${d.billNo}', bold: true),
                ],
              ),
              const SizedBox(height: 8),
              Container(height: 2, color: const Color(0xFF0F766E)),
              const SizedBox(height: 10),
              pair(
                '供应商：${_shown(d.supplierName)}',
                '订货日期：${_shown(d.billDate)}',
              ),
              pair(
                '联系人：${_shown(d.supplierContact)}',
                '交货日期：${_shown(d.deliverDate)}',
              ),
              pair(
                '供应商电话：${_shown(d.supplierPhone)}',
                '公司电话：${_shown(d.companyPhone)}',
              ),
              if (!d.financeApproved)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: text('单据状态：${_shown(d.statusLabel)}', bold: true),
                ),
              const SizedBox(height: 10),
              Table(
                border: TableBorder.all(
                  color: const Color(0xFF8B979D),
                  width: 0.6,
                ),
                columnWidths: {
                  for (
                    var i = 0;
                    i < PurchaseOrderPrintDocument.widths.length;
                    i++
                  )
                    i: FlexColumnWidth(PurchaseOrderPrintDocument.widths[i]),
                },
                children: [
                  for (final row in [
                    PurchaseOrderPrintDocument.headers,
                    ...rows,
                  ])
                    TableRow(
                      decoration: row == PurchaseOrderPrintDocument.headers
                          ? const BoxDecoration(color: Color(0xFFEDF2F4))
                          : null,
                      children: [
                        for (final value in row)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 7,
                            ),
                            child: text(
                              value,
                              size: row == PurchaseOrderPrintDocument.headers
                                  ? 11
                                  : 12,
                              bold: row == PurchaseOrderPrintDocument.headers,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 12),
              pair('金额大写：${d.capitalLabel}', '合计：${d.amountLabel}'),
              pair(
                '付款方式：${d.priceMasked ? '***' : _shown(d.settlementMethod)}',
                '交货地点：${_shown(d.deliveryPlace)}',
              ),
              const Divider(color: Color(0xFF8B979D)),
              text('备注：${_shown(d.remark)}'),
              const SizedBox(height: 44),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: text('供应商签章：')),
                  Expanded(child: text('制单：${_shown(d.makerName)}')),
                  Expanded(child: text('审核：${_shown(d.reviewerName)}')),
                ],
              ),
              const SizedBox(height: 20),
              text('共 ${d.lines.length} 项', size: 9),
            ],
          ),
        ),
      ),
    );
  }
}

String _shown(String value) => value.isEmpty ? '—' : value;

Future<Uint8List> buildPurchaseOrderPdf(
  PurchaseOrderPrintDocument document,
) async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/NotoSansSCFull.ttf'),
  );
  final pdf = pw.Document(
    theme: pw.ThemeData.withFont(base: font, bold: font),
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
          if (!d.financeApproved)
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
