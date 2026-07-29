// 通用「预览 → 打印」组件（所有表格页共用，对齐货品资料 BOM 预览体验）。
//
// 用法：AppBar 放 UtenPrintPreviewButton（通常在 UtenExportButton 旁），点击弹 A4 纸面预览：
// - 预览：标题 + 副标题（筛选口径/日期范围）+ 表格（灰底 + 白纸，A4 横版自动分页，
//   每页重复表头 + 页码，列等宽撑满纸宽保证横向显示全）；
// - 打印：pdf 包生成 A4 横版 PDF（NotoSansSC 内置中文字体）→ printing 系统打印对话框；
// - 下载 Excel：可选，复用 UtenExportButton（加密 xlsx 走后端导出，与页内导出口径一致）；
// - 数据：loader 返回"显示就绪"的表头 + 行（报表页用 formatReportCell 格式化，与页面表格同口径）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../buttons/uten_button.dart';
import '../buttons/uten_export_button.dart';

/// 打印表格数据：表头 + 行（均为显示就绪字符串）。
class UtenPrintTable {
  const UtenPrintTable({required this.headers, required this.rows});

  final List<String> headers;
  final List<List<String>> rows;
}

/// 弹出通用 A4 打印预览。
Future<void> showUtenPrintPreview({
  required BuildContext context,
  required String title,
  String? subtitle,
  required Future<UtenPrintTable> Function() loader,
  String? exportEndpoint,
  String? exportReport,
  Map<String, dynamic>? exportQuery,
  String? exportFilename,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _UtenPrintPreviewDialog(
      title: title,
      subtitle: subtitle,
      loader: loader,
      exportEndpoint: exportEndpoint,
      exportReport: exportReport,
      exportQuery: exportQuery,
      exportFilename: exportFilename,
    ),
  );
}

/// AppBar「预览打印」按钮（与 UtenExportButton 同款紧凑文字按钮）。
class UtenPrintPreviewButton extends StatelessWidget {
  const UtenPrintPreviewButton({
    super.key,
    required this.title,
    this.subtitle,
    required this.loader,
    this.exportEndpoint,
    this.exportReport,
    this.exportQuery,
    this.exportFilename,
    this.label = '预览打印',
    this.type = UtenButtonType.tonal,
    this.size = UtenButtonSize.small,
  });

  final String title;
  final String? subtitle;
  final Future<UtenPrintTable> Function() loader;
  final String? exportEndpoint;
  final String? exportReport;
  final Map<String, dynamic>? exportQuery;
  final String? exportFilename;

  /// 按钮文字（默认"预览打印"）。
  final String label;

  /// 按钮样式/尺寸：默认 tonal/small（AppBar 紧凑款）；
  /// 表格工具条场景传 primary/large（实心深绿 + 白字白 icon 大按钮）。
  final UtenButtonType type;
  final UtenButtonSize size;

  @override
  Widget build(BuildContext context) {
    return UtenButton(
      type: type,
      size: size,
      icon: Icons.print_outlined,
      onPressed: () => showUtenPrintPreview(
        context: context,
        title: title,
        subtitle: subtitle,
        loader: loader,
        exportEndpoint: exportEndpoint,
        exportReport: exportReport,
        exportQuery: exportQuery,
        exportFilename: exportFilename,
      ),
      child: Text(label),
    );
  }
}

class _UtenPrintPreviewDialog extends StatefulWidget {
  const _UtenPrintPreviewDialog({
    required this.title,
    this.subtitle,
    required this.loader,
    this.exportEndpoint,
    this.exportReport,
    this.exportQuery,
    this.exportFilename,
  });

  final String title;
  final String? subtitle;
  final Future<UtenPrintTable> Function() loader;
  final String? exportEndpoint;
  final String? exportReport;
  final Map<String, dynamic>? exportQuery;
  final String? exportFilename;

  @override
  State<_UtenPrintPreviewDialog> createState() =>
      _UtenPrintPreviewDialogState();
}

class _UtenPrintPreviewDialogState extends State<_UtenPrintPreviewDialog> {
  UtenPrintTable? _table;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await widget.loader();
      if (!mounted) return;
      setState(() => _table = t);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '加载数据失败'); // TODO(l10n): 补 arb
    }
  }

  // ---- 打印（pdf 包生成 A4 横版，NotoSansSC 中文字体） ----------------------

  Future<void> _print() async {
    final t = _table;
    if (t == null) return;
    try {
      final fontData = await rootBundle.load('assets/fonts/NotoSansSC.ttf');
      final font = pw.Font.ttf(fontData);
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(28),
          build: (ctx) => [
            pw.Center(
              child: pw.Text(
                widget.title,
                style: pw.TextStyle(
                    font: font, fontSize: 16, fontWeight: pw.FontWeight.bold),
              ),
            ),
            if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
              pw.SizedBox(height: 4),
              pw.Center(
                child: pw.Text(widget.subtitle!,
                    style: pw.TextStyle(font: font, fontSize: 9)),
              ),
            ],
            pw.SizedBox(height: 10),
            pw.Table(
              border: pw.TableBorder.all(width: 0.5),
              children: [
                pw.TableRow(
                  decoration:
                      const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFEFEF)),
                  children: [
                    for (final h in t.headers)
                      _pdfCell(font, h, bold: true, center: true),
                  ],
                ),
                for (final row in t.rows)
                  pw.TableRow(children: [
                    for (final c in row) _pdfCell(font, c),
                  ]),
              ],
            ),
          ],
        ),
      );
      await Printing.layoutPdf(
        onLayout: (_) async => doc.save(),
        name: '${widget.title}.pdf',
      );
    } catch (_) {
      if (!mounted) return;
      context.appError('生成打印件失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  pw.Widget _pdfCell(pw.Font font, String text,
      {bool bold = false, bool center = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        text,
        textAlign: center ? pw.TextAlign.center : null,
        style: pw.TextStyle(
          font: font,
          fontSize: 8,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  // ---- 渲染 ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = _table;
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1080,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头部：标题 + 操作
              Padding(
                padding: const EdgeInsets.fromLTRB(UtenSpacing.s16,
                    UtenSpacing.s12, UtenSpacing.s8, UtenSpacing.s12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '预览 · ${widget.title}', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      size: UtenButtonSize.small,
                      icon: Icons.print_outlined,
                      onPressed: (t == null || t.rows.isEmpty) ? null : _print,
                      child: const Text('打印'), // TODO(l10n): 补 arb
                    ),
                    if (widget.exportEndpoint != null) ...[
                      const SizedBox(width: UtenSpacing.s8),
                      UtenExportButton(
                        endpoint: widget.exportEndpoint!,
                        report: widget.exportReport ?? '',
                        queryParams: widget.exportQuery ?? const {},
                        filename: widget.exportFilename ?? widget.title,
                        label: '下载Excel', // TODO(l10n): 补 arb
                      ),
                    ],
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // A4 纸面（灰底 + 白纸卡片，横向可滚动保证窄屏可看全）
              Expanded(
                child: Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: _error != null
                      ? Center(child: Text(_error!))
                      : t == null
                          ? const Center(child: CircularProgressIndicator())
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(UtenSpacing.s16),
                              child: Center(child: _a4Pages(theme, t)),
                            ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A4 横版分页纸面（宽 1000，297:210 横版比例）：
  /// - 行多一页放不下 → 自动分多页，每页重复表头、右下角页码；
  /// - 表格列等宽撑满纸宽、文字自动换行 → 横向也显示全，无需左右滚动。
  static const int _rowsPerPage = 20;

  Widget _a4Pages(ThemeData theme, UtenPrintTable t) {
    const paperWidth = 1000.0;
    final pages = <List<List<String>>>[];
    for (var i = 0; i < t.rows.length; i += _rowsPerPage) {
      final end =
          i + _rowsPerPage > t.rows.length ? t.rows.length : i + _rowsPerPage;
      pages.add(t.rows.sublist(i, end));
    }
    if (pages.isEmpty) pages.add(const []);
    return Column(
      children: [
        for (var p = 0; p < pages.length; p++) ...[
          if (p > 0) const SizedBox(height: UtenSpacing.s16),
          _a4Page(theme, t, pages[p], p, pages.length, paperWidth),
        ],
      ],
    );
  }

  /// 单页纸面：标题（仅第 1 页）+ 表头（每页重复）+ 本页行 + 页码。
  Widget _a4Page(ThemeData theme, UtenPrintTable t, List<List<String>> rows,
      int pageIndex, int pageCount, double paperWidth) {
    return Container(
      width: paperWidth,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: const [
          BoxShadow(blurRadius: 12, color: Colors.black26),
        ],
      ),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pageIndex == 0) ...[
            Center(
              child: Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
            if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Center(
                child: Text(
                  widget.subtitle!,
                  style: const TextStyle(fontSize: 10, color: Colors.black87),
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
          Table(
            columnWidths: {
              for (var i = 0; i < t.headers.length; i++)
                i: const FlexColumnWidth(),
            },
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFEFEFEF)),
                children: [
                  for (final h in t.headers) _paperCell(h, bold: true, center: true),
                ],
              ),
              for (final row in rows)
                TableRow(children: [
                  for (final c in row) _paperCell(c),
                ]),
            ],
          ),
          if (rows.isEmpty && pageIndex == 0)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text('暂无数据', // TODO(l10n): 补 arb
                    style: TextStyle(color: Colors.black54)),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '第 ${pageIndex + 1} / $pageCount 页 · 共 ${t.rows.length} 行',
              style: const TextStyle(fontSize: 9, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paperCell(String text, {bool bold = false, bool center = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: Text(
        text,
        textAlign: center ? TextAlign.center : null,
        style: TextStyle(
          fontSize: 10,
          color: Colors.black,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
