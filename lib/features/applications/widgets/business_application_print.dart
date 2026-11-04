import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/rmb_amount.dart';
import '../models/business_application.dart';
export '../models/business_application.dart'
    show businessApplicationApprovalRoles, businessApplicationStageLabel;
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/sensitive_content_boundary.dart';
import '../../../core/network/read_scope_revision.dart';

const businessApplicationFieldLabels = {
  'reason': '内容摘要 / 事由',
  'destination': '目的地',
  'startDate': '开始日期',
  'endDate': '结束日期',
  'transport': '交通方式',
  'companions': '同行人员',
  'payee': '收款人 / 单位',
  'paymentUnit': '付款单位',
  'supplierName': '收款供应商',
  'remark': '备注',
  'paymentDate': '付款日期',
  'paymentReference': '付款凭证号',
};

String businessApplicationActionLabel(String action) => switch (action) {
  'CREATED' => '创建申请',
  'EDITED' => '修改申请',
  'SUBMITTED' => '提交审批',
  'WITHDRAWN' => '撤回申请',
  'APPROVED' || 'STAGE_APPROVED' => '审批通过',
  'REJECTED' => '驳回申请',
  'RECEIVED' => '财务接收保管',
  'PAID' => '登记付款',
  'PAYMENT_CANCELLED' => '撤销付款登记',
  'FINANCE_LINKED' => '关联财务入账',
  'CANCELLED' => '作废申请',
  _ => action,
};

/// Receipt acknowledgement is a paper signature, not another approval node.
List<String> businessApplicationPrintSignatureRoles(String kind) => [
  ...businessApplicationApprovalRoles(kind),
  if (kind != 'TRAVEL') '收款人签收',
];

List<String> businessApplicationAuditLines(BusinessApplication application) => [
  for (final event in application.events)
    '${event.round > 0 ? '第${event.round}轮 ' : ''}${businessApplicationStageLabel(event.stage, kind: application.kind)} '
        '${businessApplicationActionLabel(event.action)}  ${event.actorName}  '
        '${ChinaDateTime.formatDateTime(event.occurredAt)}'
        '${event.remark?.isNotEmpty == true ? '  ${event.remark}' : ''}',
];

List<List<String>> businessApplicationPrintRows(
  BusinessApplication application,
) => [
  ['申请单号', application.applicationNo],
  ['申请人', application.applicantName],
  ['申请部门', application.departmentName ?? '—'],
  ['申请日期', ChinaDateTime.formatDateTime(application.createdAt)],
  ['申请标题', application.title],
  ['当前状态', application.statusLabel],
  if (application.kind == 'PREPAYMENT' && application.status == 'PAID')
    ['账务状态', application.postingStatus == 'POSTED' ? '已关联预付账务' : '待财务入账'],
  [
    '${application.kind == 'TRAVEL' ? '预计费用' : '申请金额'}（${application.amountUnit}）',
    application.amount.isEmpty ? '—' : application.amount,
  ],
  [
    '金额大写',
    application.amount.isEmpty
        ? '不适用'
        : application.rmbAmount
        ? rmbCapitalExact(application.amount)
        : '原币 ${application.amountLabel}',
  ],
  for (final entry in businessApplicationFieldLabels.entries)
    if (application.fields[entry.key]?.toString().trim().isNotEmpty == true)
      [entry.value, application.fields[entry.key].toString()],
];

/// PDF table rows cannot split one tall cell across pages. Bound each physical
/// segment by characters and explicit line breaks, retaining every code point.
List<List<String>> businessApplicationPrintSegments(
  BusinessApplication application,
) => [
  for (final row in businessApplicationPrintRows(application))
    ..._segments(row),
];

List<List<String>> _segments(List<String> row) {
  final result = <List<String>>[];
  var chunk = StringBuffer();
  var budget = 0;
  void flush() {
    if (chunk.isEmpty) return;
    result.add([
      result.isEmpty ? row[0] : '${row[0]} 续${result.length}',
      chunk.toString(),
    ]);
    chunk = StringBuffer();
    budget = 0;
  }

  for (final codePoint in row[1].runes) {
    final cost = codePoint == 10 || codePoint == 13 ? 36 : 1;
    if (budget + cost > 360) flush();
    chunk.writeCharCode(codePoint);
    budget += cost;
  }
  flush();
  return result;
}

Future<Uint8List> buildBusinessApplicationPdf(
  BusinessApplication application,
) async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/NotoSansSCFull.ttf'),
  );
  final doc = pw.Document();
  pw.Widget text(String value, {double size = 10, bool bold = false}) =>
      pw.Text(
        value,
        style: pw.TextStyle(
          font: font,
          fontSize: size,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      );
  pw.Widget cell(String value) => pw.Padding(
    padding: const pw.EdgeInsets.all(5),
    child: text(value, size: 9),
  );
  final rows = businessApplicationPrintSegments(application);
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 100,
      theme: pw.ThemeData.withFont(base: font),
      margin: const pw.EdgeInsets.all(36),
      header: (_) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          text(application.kindLabel, size: 8),
          text(application.applicationNo, size: 8),
        ],
      ),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: text('${context.pageNumber} / ${context.pagesCount}', size: 8),
      ),
      build: (_) => [
        pw.SizedBox(height: 12),
        pw.Center(child: text(application.kindLabel, size: 20, bold: true)),
        pw.SizedBox(height: 16),
        pw.Table(
          border: pw.TableBorder.all(width: .5),
          columnWidths: {
            0: const pw.FixedColumnWidth(105),
            1: const pw.FlexColumnWidth(),
          },
          children: [
            for (final row in rows)
              pw.TableRow(children: [cell(row[0]), cell(row[1])]),
          ],
        ),
        pw.SizedBox(height: 12), text('相关凭证：____ 张；经办人：________________'),
        pw.SizedBox(height: 12),
        // Each stage gets enough handwriting room; no electronic history is
        // rendered as a handwritten or electronic signature.
        for (final role in businessApplicationPrintSignatureRoles(
          application.kind,
        ))
          pw.Container(
            height: 44,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: .5)),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                text(role),
                text('签名：________________    日期：____________', size: 9),
              ],
            ),
          ),
        pw.SizedBox(height: 16), text('系统流转记录', bold: true),
        for (final line in businessApplicationAuditLines(application))
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 5),
            child: text(line, size: 8),
          ),
        pw.SizedBox(height: 12),
        text('本件用于内部审批与纸质签名。保留原始凭证；纸质签名不代表系统审批或财务记账已完成。', size: 8),
      ],
    ),
  );
  return doc.save();
}

Future<void> showBusinessApplicationPrintPreview(
  BuildContext context,
  BusinessApplication application,
) {
  final container = ProviderScope.containerOf(context, listen: false);
  final boundary = container.read(sensitiveReadBoundaryProvider);
  final revision = container.read(readScopeRevisionProvider);
  return showDialog<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (context, ref, _) {
        final currentRevision = ref.watch(readScopeRevisionProvider);
        return SensitiveContentBoundary(
          boundary: boundary,
          isCurrent: () => currentRevision == revision,
          child: _ApplicationPrintDialog(application: application),
          invalidatedBuilder: (context) => UtenAlertDialog(
            title: const Text('登录身份或权限已变化'),
            actions: [
              UtenButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _ApplicationPrintDialog extends StatefulWidget {
  const _ApplicationPrintDialog({required this.application});
  final BusinessApplication application;
  @override
  State<_ApplicationPrintDialog> createState() =>
      _ApplicationPrintDialogState();
}

class _ApplicationPrintDialogState extends State<_ApplicationPrintDialog> {
  bool _busy = false;
  Future<void> _print() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await buildBusinessApplicationPdf(widget.application);
      if (!mounted) return;
      await UtenBusyOverlay.yieldWhile(
        () => printPdfBytes(
          bytes,
          '${widget.application.kindLabel}-${widget.application.applicationNo}.pdf',
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        context.appApiError(error, fallback: '打印失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final application = widget.application;
    return UtenDialogFrame(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 900,
          maxHeight: MediaQuery.sizeOf(context).height * .92,
        ),
        child: Stack(
          children: [
            Column(
              children: [
                UtenDialogHeader(
                  title: Text('打印预览 · ${application.kindLabel}'),
                  showCloseButton: true,
                  onClose: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Container(
                        width: 680,
                        color: Colors.white,
                        padding: const EdgeInsets.all(UtenSpacing.s32),
                        child: DefaultTextStyle(
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                application.kindLabel,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s24),
                              for (final row in [
                                for (final values
                                    in businessApplicationPrintRows(
                                      application,
                                    ))
                                  '${values[0]}：${values[1]}',
                                '相关凭证：____ 张；经办人：________________',
                              ])
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: UtenSpacing.s8,
                                  ),
                                  child: Text(row),
                                ),
                              for (final role
                                  in businessApplicationPrintSignatureRoles(
                                    application.kind,
                                  ))
                                Container(
                                  height: 76,
                                  padding: const EdgeInsets.all(
                                    UtenSpacing.s12,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.black54),
                                  ),
                                  child: Text(
                                    '$role\n\n签名：________________    日期：____________',
                                  ),
                                ),
                              const SizedBox(height: UtenSpacing.s24),
                              const Text('系统流转记录'),
                              for (final line in businessApplicationAuditLines(
                                application,
                              ))
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: UtenSpacing.s4,
                                  ),
                                  child: Text(line),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                UtenDialogActions(
                  children: [
                    UtenButton(
                      icon: Icons.print_outlined,
                      isLoading: _busy,
                      onPressed: _busy ? null : _print,
                      child: const Text('打印'),
                    ),
                  ],
                ),
              ],
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在生成打印件',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}
