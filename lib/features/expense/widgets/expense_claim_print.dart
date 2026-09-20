// 公司内部费用报销展示及打印件：A4、多页明细、准确金额及真实流转历史。
// 电子文件数与纸质张数分开呈现；付款信息只说明系统已登记事实。
// 本件不替代原始凭证、税务查验、有效电子签名或法定电子档案。

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/print/pdf_printer.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../providers/expense_settings_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/rmb_amount.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';

/// 弹出报销单打印预览（A4 纸面 + 打印按钮）。
Future<void> showExpenseClaimPrintPreview(
  BuildContext context,
  ExpenseClaim claim,
) async {
  String companyName = '';
  try {
    companyName = (await ProviderScope.containerOf(
      context,
    ).read(expenseSettingsProvider.future)).companyName;
  } catch (_) {
    // Printing a readable claim remains possible when optional company settings cannot be loaded.
  }
  if (!context.mounted) return;
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _ExpenseClaimPrintDialog(claim: claim, companyName: companyName),
  );
}

class _ExpenseClaimPrintDialog extends StatefulWidget {
  const _ExpenseClaimPrintDialog({
    required this.claim,
    required this.companyName,
  });
  final ExpenseClaim claim;
  final String companyName;
  @override
  State<_ExpenseClaimPrintDialog> createState() =>
      _ExpenseClaimPrintDialogState();
}

class _ExpenseClaimPrintDialogState extends State<_ExpenseClaimPrintDialog> {
  ExpenseClaim get claim => widget.claim;
  bool _printing = false;

  Future<void> _print(BuildContext context) async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      final bytes = await buildExpenseClaimPdf(
        claim,
        companyName: widget.companyName,
        disclaimer: AppLocalizations.of(context).expenseFlowPrintDisclaimer,
      );
      await printPdfBytes(bytes, '费用报销单-${claim.claimNo}.pdf');
    } catch (_) {
      if (context.mounted) {
        context.appError('生成打印件失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  // ---- PDF 版面（与预览纸面同构，字号按 A4 实寸） ----------------------------

  // ---- 预览纸面（Flutter 白纸卡片，与 PDF 同构） -------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 980,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s12,
                  UtenSpacing.s8,
                  UtenSpacing.s12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '预览 · 费用报销单 ${claim.claimNo}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    UtenButton(
                      isLoading: _printing,
                      icon: Icons.print_outlined,
                      onPressed: _printing ? null : () => _print(context),
                      child: const Text('打印'),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('关闭'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: _paper(theme),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _paper(ThemeData theme) {
    return Container(
      width: 794,
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)],
      ),
      child: _PaperSheet(claim: claim, companyName: widget.companyName),
    );
  }
}

/// 纸面内容（Flutter 版）：与 PDF 同构，供预览与测试直接复用。
class _PaperSheet extends StatelessWidget {
  const _PaperSheet({required this.claim, required this.companyName});
  final String companyName;

  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context) {
    final black = Colors.black.withValues(alpha: 0.87);
    const grey = Colors.black54;
    return DefaultTextStyle(
      style: TextStyle(color: black, fontSize: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (companyName.isNotEmpty)
            Text(
              companyName,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Expanded(
                child: Center(
                  child: Text(
                    '费用报销单',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 170,
                child: Text(
                  '单号：${claim.claimNo}',
                  style: const TextStyle(fontSize: 9, color: Colors.black54),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Table(
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            columnWidths: const {0: FlexColumnWidth(), 1: FlexColumnWidth(1.4)},
            children: [
              TableRow(
                children: [
                  _kv('报销日期', _fmtDate(claim.submittedAt ?? claim.createdAt)),
                  _kv('报销人', claim.applicantName),
                ],
              ),
              TableRow(
                children: [
                  _kv('部门', claim.departmentName ?? '—'),
                  _kv('状态', claim.status.label),
                ],
              ),
              TableRow(
                children: [
                  _kv('事由', claim.title, bold: true),
                  _kv(
                    '附件',
                    '${claim.attachments.length} 个电子文件 / ${claim.invoices.length} 份登记凭证 / 纸质____张(核实后填)',
                  ),
                ],
              ),
              if (claim.remark != null && claim.remark!.trim().isNotEmpty)
                TableRow(
                  children: [_kv('说明', claim.remark!), const SizedBox.shrink()],
                ),
            ],
          ),
          const SizedBox(height: 8),
          _itemsTable(),
          const SizedBox(height: 8),
          Table(
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            children: [
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      '合计（${claim.items.length} 项）　小写：¥ '
                      '${claim.totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      '大写：${rmbCapital(claim.totalAmount)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          _paymentTable(),
          const SizedBox(height: 8),
          Table(
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            children: [
              TableRow(
                children: [
                  for (final role in const [
                    '报销人',
                    '部门负责人',
                    '财务审核',
                    '批准人',
                    '出纳',
                  ])
                    SizedBox(
                      height: 56,
                      child: Center(
                        child: Text(
                          role,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          _auditTrail(grey),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).expenseFlowPrintDisclaimer,
            style: const TextStyle(fontSize: 8, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label：'),
            TextSpan(
              text: value,
              style: TextStyle(fontWeight: bold ? FontWeight.w700 : null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemsTable() {
    return Table(
      border: TableBorder.all(color: Colors.black54, width: 0.6),
      columnWidths: const {
        0: FixedColumnWidth(40),
        1: FixedColumnWidth(86),
        2: FixedColumnWidth(100),
        3: FlexColumnWidth(),
        4: FixedColumnWidth(100),
      },
      children: [
        TableRow(
          decoration: const BoxDecoration(color: Color(0xFFEFEFEF)),
          children: [
            _head('序号'),
            _head('日期'),
            _head('费用科目'),
            _head('说明'),
            _head('金额（元）'),
          ],
        ),
        for (var i = 0; i < claim.items.length; i++)
          TableRow(
            children: [
              _cell('${i + 1}', center: true),
              _cell(_fmtDate(claim.items[i].date), center: true),
              _cell(claim.items[i].category.label),
              _cell(claim.items[i].description ?? ''),
              _cell(
                claim.items[i].amount.toStringAsFixed(2),
                center: true,
                tabular: true,
              ),
            ],
          ),
      ],
    );
  }

  Widget _paymentTable() {
    final paid = claim.status == ExpenseClaimStatus.paid;
    return Table(
      border: TableBorder.all(color: Colors.black54, width: 0.6),
      children: [
        TableRow(
          children: [
            _kv('付款证明', '${claim.paymentProofs.length} 个电子文件'),
            const SizedBox.shrink(),
          ],
        ),
        TableRow(
          children: [
            _kv('付款账户', paid ? claim.paymentAccountName ?? '—' : '尚未登记付款'),
            _kv(
              '费用类别',
              paid ? claim.paymentExpenseStyleName ?? '—' : '登记付款后回填',
            ),
          ],
        ),
        TableRow(
          children: [
            _kv(
              '付款日期',
              claim.paymentDate == null ? '—' : _fmtDate(claim.paymentDate!),
            ),
            _kv('出纳', paid ? claim.paidByName ?? '—' : '登记付款后回填'),
          ],
        ),
      ],
    );
  }

  Widget _auditTrail(Color grey) {
    final lines = expensePrintAuditLines(claim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Text(line, style: TextStyle(fontSize: 8, color: grey, height: 1.6)),
      ],
    );
  }

  Widget _head(String text) => Padding(
    padding: const EdgeInsets.all(4),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontWeight: FontWeight.w600),
    ),
  );

  Widget _cell(String text, {bool center = false, bool tabular = false}) =>
      Padding(
        padding: const EdgeInsets.all(4),
        child: Text(
          text,
          textAlign: center ? TextAlign.center : null,
          style: tabular
              ? const TextStyle(fontFeatures: [FontFeature.tabularFigures()])
              : null,
        ),
      );
}

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _fmtDateTime(DateTime t) =>
    '${_fmtDate(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Every submission, correction, rejection and payment stays visible on the printed claim.
List<String> expensePrintAuditLines(ExpenseClaim claim) => [
  '系统流转记录 (${claim.claimNo})',
  if (claim.events.isEmpty) '暂无系统流转记录',
  for (final event in claim.events)
    '${event.type.label} · ${event.actorName} · ${_fmtDateTime(event.occurredAt)}${event.remark?.isNotEmpty == true ? ' · ${event.remark}' : ''}',
];

/// Build the same complete claim shown in preview. Tables split naturally over A4 pages.
Future<Uint8List> buildExpenseClaimPdf(
  ExpenseClaim claim, {
  String companyName = '',
  String disclaimer = '内部报销审批展示单；不替代原始凭证、税务查验或法定电子档案。',
}) async {
  final data = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
  final font = pw.Font.ttf(data);
  final builder = _ExpenseClaimPdf(claim, companyName, disclaimer);
  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 100,
      margin: const pw.EdgeInsets.all(36),
      header: (_) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(
              child: builder._pdfText(font, '$companyName · 费用报销单', size: 8),
            ),
            builder._pdfText(font, claim.claimNo, size: 8),
          ],
        ),
      ),
      build: (_) => builder._buildPdf(font),
      footer: (ctx) => builder._pdfText(
        font,
        '${ctx.pageNumber} / ${ctx.pagesCount}',
        size: 8,
      ),
    ),
  );
  return doc.save();
}

class _ExpenseClaimPdf {
  const _ExpenseClaimPdf(this.claim, this.companyName, this.disclaimer);
  final ExpenseClaim claim;
  final String companyName;
  final String disclaimer;
  List<pw.Widget> _buildPdf(pw.Font font) {
    final rows = claim.items;
    final attachmentCount = claim.attachments.length;
    return [
      if (companyName.isNotEmpty)
        _pdfText(font, companyName, size: 12, bold: true),
      _pdfTitleRow(font),
      _pdfHeaderTable(font, attachmentCount),
      pw.SizedBox(height: 6),
      _pdfReasonTable(font),
      pw.SizedBox(height: 6),
      _pdfItemsTable(font, rows),
      pw.SizedBox(height: 6),
      _pdfTotalTable(font),
      pw.SizedBox(height: 6),
      pw.Inseparable(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            _pdfPaymentTable(font),
            pw.SizedBox(height: 6),
            _pdfSignTable(font),
          ],
        ),
      ),
      pw.SizedBox(height: 10),
      ...expensePrintAuditLines(
        claim,
      ).map((line) => _pdfText(font, line, size: 8)),
      pw.SizedBox(height: 8),
      _pdfText(font, disclaimer, size: 8),
    ];
  }

  pw.Widget _pdfBox(pw.Font font, List<pw.Widget> children) {
    final pw.TableBorder border = pw.TableBorder.all(width: 0.5);
    return pw.Inseparable(
      child: pw.Container(
        width: double.infinity,
        decoration: pw.BoxDecoration(border: border),
        padding: const pw.EdgeInsets.all(8),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  pw.Widget _pdfText(
    pw.Font font,
    String text, {
    double size = 9,
    bool bold = false,
  }) => pw.Text(
    text,
    style: pw.TextStyle(
      font: font,
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    ),
  );

  pw.Widget _pdfTitleRow(pw.Font font) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(
          child: pw.Container(
            alignment: pw.Alignment.center,
            child: _pdfText(font, '费用报销单', size: 16, bold: true),
          ),
        ),
        pw.SizedBox(
          width: 150,
          child: _pdfText(font, '单号：${claim.claimNo}', size: 8),
        ),
      ],
    );
  }

  pw.Widget _pdfHeaderTable(pw.Font font, int attachmentCount) {
    return _pdfBox(font, [
      pw.Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          _pdfText(
            font,
            '报销日期：${_fmtDate(claim.submittedAt ?? claim.createdAt)}',
          ),
          pw.SizedBox(width: 18),
          _pdfText(font, '报销人：${claim.applicantName}'),
          pw.SizedBox(width: 18),
          _pdfText(font, '部门：${claim.departmentName ?? '—'}'),
          pw.SizedBox(width: 18),
          _pdfText(font, '状态：${claim.status.label}'),
        ],
      ),
      pw.SizedBox(height: 4),
      _pdfText(
        font,
        '电子附件：$attachmentCount 个文件；登记凭证：${claim.invoices.length} 份；纸质附件：____ 张(人工核实)',
      ),
    ]);
  }

  pw.Widget _pdfReasonTable(pw.Font font) {
    return _pdfBox(font, [
      _pdfText(font, '事由：${claim.title}', bold: true),
      if (claim.remark != null && claim.remark!.trim().isNotEmpty) ...[
        pw.SizedBox(height: 2),
        _pdfText(font, '说明：${claim.remark}'),
      ],
    ]);
  }

  pw.Widget _pdfItemsTable(pw.Font font, List<ExpenseItem> rows) {
    return pw.Table(
      border: pw.TableBorder.all(width: 0.5),
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFEFEFEF),
          ),
          children: [
            _pdfCell(font, '序号', center: true, bold: true),
            _pdfCell(font, '日期', center: true, bold: true),
            _pdfCell(font, '费用科目', center: true, bold: true),
            _pdfCell(font, '说明', center: true, bold: true),
            _pdfCell(font, '金额（元）', center: true, bold: true),
          ],
        ),
        for (var i = 0; i < rows.length; i++)
          pw.TableRow(
            children: [
              _pdfCell(font, '${i + 1}', center: true),
              _pdfCell(font, _fmtDate(rows[i].date), center: true),
              _pdfCell(font, rows[i].category.label),
              _pdfCell(font, rows[i].description ?? ''),
              _pdfCell(font, rows[i].amount.toStringAsFixed(2), center: true),
            ],
          ),
      ],
      columnWidths: const {
        0: pw.FixedColumnWidth(36),
        1: pw.FixedColumnWidth(76),
        2: pw.FixedColumnWidth(90),
        3: pw.FlexColumnWidth(),
        4: pw.FixedColumnWidth(90),
      },
    );
  }

  pw.Widget _pdfCell(
    pw.Font font,
    String text, {
    bool center = false,
    bool bold = false,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        text,
        textAlign: center ? pw.TextAlign.center : null,
        style: pw.TextStyle(
          font: font,
          fontSize: 9,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  pw.Widget _pdfTotalTable(pw.Font font) {
    return _pdfBox(font, [
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          _pdfText(font, '合计（${claim.items.length} 项）', bold: true),
          _pdfText(
            font,
            '小写：¥ ${claim.totalAmount.toStringAsFixed(2)}',
            bold: true,
          ),
        ],
      ),
      pw.SizedBox(height: 2),
      _pdfText(font, '大写：${rmbCapital(claim.totalAmount)}', bold: true),
    ]);
  }

  pw.Widget _pdfPaymentTable(pw.Font font) {
    final paid = claim.status == ExpenseClaimStatus.paid;
    return _pdfBox(font, [
      _pdfText(
        font,
        paid ? '已登记付款账户：${claim.paymentAccountName ?? '—'}' : '付款状态：尚未登记付款',
      ),
      pw.SizedBox(height: 2),
      _pdfText(font, '付款证明：${claim.paymentProofs.length} 个电子文件'),
      _pdfText(
        font,
        paid
            ? '费用类别：${claim.paymentExpenseStyleName ?? '—'} · '
                  '付款日期：${claim.paymentDate == null ? '—' : _fmtDate(claim.paymentDate!)} · '
                  '出纳：${claim.paidByName ?? '—'}'
            : '费用类别 / 付款日期 / 经办人：登记付款后回填',
      ),
    ]);
  }

  pw.Widget _pdfSignTable(pw.Font font) {
    const roles = ['报销人', '部门负责人', '财务审核', '批准人', '出纳'];
    return pw.Table(
      border: pw.TableBorder.all(width: 0.5),
      children: [
        pw.TableRow(
          children: [
            for (final role in roles)
              pw.Container(
                height: 56,
                alignment: pw.Alignment.topCenter,
                padding: const pw.EdgeInsets.only(top: 4),
                child: _pdfText(font, role, size: 8),
              ),
          ],
        ),
      ],
    );
  }
}
