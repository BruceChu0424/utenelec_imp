// 货品「预览」：A4 产品配件清单（对照老系统 003.jpg）。
//
// 清单含整棵 BOM 树（子类/孙类全展开平铺）：一级组件无标记，子级编号前加 `*`，
// 孙级 `**`，依此类推（星号数 = 层级深度）；序号为级联序号并逐级缩进
// （1 / └ 3.1 / 　└ 3.1.1，层级看序号列缩进），名称列对齐不缩进（老系统 001.jpg 视感）。
// 递归展开带环路防护（当前路径上的货品不再展开）与深度上限（10 层），防止历史脏数据死循环。
//
// 弹窗内按 A4 比例渲染（标题 + 产品名称/型号/备注表头 + 序号/物料编号/物料名称/
// 规格/颜色/数量/材质/备注 表格）。底部操作：
// - 打印：pdf 包生成 A4 PDF（NotoSansSC 内置中文字体）→ printing 系统打印对话框；
// - 下载 Excel：复用 UtenExportButton（加密 xlsx，走后端 bom/export，同样整树展开）；
// - 关闭。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/goods_bom_item.dart';
import '../repositories/goods_bom_repository.dart';

/// 清单行：BOM 行 + 树深度（0=一级组件）+ 级联序号（1 / 3.1 / 3.1.1）。
class _PreviewRow {
  const _PreviewRow(this.item, this.depth, this.seq);

  final GoodsBomItem item;
  final int depth;
  final String seq;

  /// 层级标记编号：一级 = 原编号；子级 = `*编号`；孙级 = `**编号`。
  String get markedCode => '${'*' * depth}${item.componentCode ?? ''}';

  /// 层级缩进序号：一级顶格；子级退一格 + └ 分支符，孙级退两格，逐级递进
  /// （缩进体现在序号列，名称列对齐排齐——与老系统 001.jpg 树的视觉一致）。
  String get indentedSeq {
    if (depth == 0) return seq;
    return '${'　' * depth}└ $seq';
  }

  /// 物料名称（不缩进，列内对齐；层级由序号列表达）。
  String get plainName => item.componentName ?? '';
}

/// 弹出 A4 产品配件清单预览。
Future<void> showGoodsBomPreview({
  required BuildContext context,
  required String goodsId,
  String? productName,
  String? productModel,
  String? productCode,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _GoodsBomPreviewDialog(
      goodsId: goodsId,
      productName: productName,
      productModel: productModel,
      productCode: productCode,
    ),
  );
}

class _GoodsBomPreviewDialog extends ConsumerStatefulWidget {
  const _GoodsBomPreviewDialog({
    required this.goodsId,
    this.productName,
    this.productModel,
    this.productCode,
  });

  final String goodsId;
  final String? productName;
  final String? productModel;
  final String? productCode;

  @override
  ConsumerState<_GoodsBomPreviewDialog> createState() =>
      _GoodsBomPreviewDialogState();
}

class _GoodsBomPreviewDialogState
    extends ConsumerState<_GoodsBomPreviewDialog> {
  static const int _maxDepth = 10; // 树展开深度上限（防历史脏数据死循环）

  List<_PreviewRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 整树平铺加载：DFS 逐层调 list 接口（懒加载语义与组装信息页签一致）。
  /// [path] = 当前展开路径上的货品 id（含根），用于环路防护；
  /// [prefix] = 级联序号前缀（'' / '3' / '3.1'）。
  Future<void> _load() async {
    try {
      final repo = ref.read(goodsBomRepositoryProvider);
      final rows = <_PreviewRow>[];

      Future<void> walk(
        String goodsId,
        int depth,
        Set<String> path,
        String prefix,
      ) async {
        if (depth > _maxDepth) return;
        final items = await repo.list(goodsId);
        for (var i = 0; i < items.length; i++) {
          final it = items[i];
          final seq = prefix.isEmpty ? '${i + 1}' : '$prefix.${i + 1}';
          rows.add(_PreviewRow(it, depth, seq));
          if (it.hasChildren && !path.contains(it.componentGoodsId)) {
            await walk(it.componentGoodsId, depth + 1, {
              ...path,
              it.componentGoodsId,
            }, seq);
          }
        }
      }

      await walk(widget.goodsId, 0, {widget.goodsId}, '');
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '加载组装信息失败'); // TODO(l10n): 补 arb
    }
  }

  String get _title => '产品配件清单'; // TODO(l10n): 补 arb

  // ---- 打印（pdf 包生成 A4，NotoSansSC 中文字体） ----------------------------

  Future<void> _print() async {
    final rows = _rows ?? const <_PreviewRow>[];
    try {
      // UI 使用常用字子集降低首屏体积；打印按需加载完整字体，确保货品名称中的生僻字不丢失。
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      final font = pw.Font.ttf(fontData);
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (ctx) => [
            pw.Center(
              child: pw.Text(
                _title,
                style: pw.TextStyle(
                  font: font,
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 12),
            pw.Table(
              border: pw.TableBorder.all(width: 0.5),
              columnWidths: const {
                0: pw.FlexColumnWidth(2),
                1: pw.FlexColumnWidth(2),
                2: pw.FlexColumnWidth(2),
              },
              children: [
                pw.TableRow(
                  children: [
                    _pdfCell(font, '产品名称：${widget.productName ?? ''}'),
                    _pdfCell(font, '产品型号：${widget.productModel ?? ''}'),
                    _pdfCell(font, '备注：'),
                  ],
                ),
              ],
            ),
            pw.Table(
              border: pw.TableBorder.all(width: 0.5),
              columnWidths: const {
                0: pw.FixedColumnWidth(58), // 序号（缩进 └ + 级联 3.1.1 留宽）
                1: pw.FlexColumnWidth(1.4), // 物料编号
                2: pw.FlexColumnWidth(2.2), // 物料名称
                3: pw.FlexColumnWidth(1.8), // 规格
                4: pw.FlexColumnWidth(1.2), // 颜色
                5: pw.FixedColumnWidth(44), // 数量
                6: pw.FlexColumnWidth(1.2), // 材质
                7: pw.FlexColumnWidth(1.4), // 备注
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(
                    color: PdfColor.fromInt(0xFFEFEFEF),
                  ),
                  children: [
                    for (final h in const [
                      '序号',
                      '物料编号',
                      '物料名称',
                      '规格',
                      '颜色',
                      '数量',
                      '材质',
                      '备注',
                    ])
                      _pdfCell(font, h, bold: true, center: true),
                  ],
                ),
                for (var i = 0; i < rows.length; i++)
                  pw.TableRow(
                    children: [
                      _pdfCell(font, rows[i].indentedSeq),
                      _pdfCell(font, rows[i].markedCode),
                      _pdfCell(font, rows[i].plainName),
                      _pdfCell(font, rows[i].item.componentSpec ?? ''),
                      _pdfCell(font, rows[i].item.componentColorName ?? ''),
                      _pdfCell(font, _qty(rows[i].item.qty), center: true),
                      _pdfCell(font, rows[i].item.componentMaterial ?? ''),
                      _pdfCell(font, rows[i].item.summary ?? ''),
                    ],
                  ),
              ],
            ),
          ],
        ),
      );
      await printPdfBytes(
        await doc.save(),
        '${_title}_${widget.productCode ?? widget.productName ?? 'goods'}.pdf',
      );
    } catch (_) {
      if (!mounted) return;
      context.appError('生成打印件失败，请稍后重试'); // TODO(l10n): 补 arb
    }
  }

  pw.Widget _pdfCell(
    pw.Font font,
    String text, {
    bool bold = false,
    bool center = false,
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

  static String _qty(double? v) =>
      v == null ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v');

  // ---- 渲染 ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 860,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头部：标题 + 操作
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
                        '预览 · $_title', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      size: UtenButtonSize.small,
                      icon: Icons.print_outlined,
                      onPressed: (rows == null || rows.isEmpty) ? null : _print,
                      child: const Text('打印'), // TODO(l10n): 补 arb
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    UtenExportButton(
                      endpoint: ApiEndpoints.goodsBomExport(widget.goodsId),
                      requiredPermission: Perm.goodsExport,
                      report: '',
                      queryParams: const {},
                      filename:
                          '${_title}_${widget.productCode ?? widget.productName ?? 'goods'}',
                      label: '下载Excel', // TODO(l10n): 补 arb
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
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
                      : rows == null
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(UtenSpacing.s16),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: _a4Paper(theme, rows),
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

  /// A4 比例纸面（210:297 ≈ 1:1.414；宽 760 → 高约 1074）。
  Widget _a4Paper(ThemeData theme, List<_PreviewRow> rows) {
    const paperWidth = 760.0;
    return Container(
      width: paperWidth,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)],
      ),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: Text(
              '产品配件清单', // TODO(l10n): 补 arb
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.black,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // 产品信息行
          Table(
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            columnWidths: const {
              0: FlexColumnWidth(2),
              1: FlexColumnWidth(2),
              2: FlexColumnWidth(2),
            },
            children: [
              TableRow(
                children: [
                  _paperCell('产品名称：${widget.productName ?? ''}'),
                  _paperCell('产品型号：${widget.productModel ?? ''}'),
                  _paperCell('备注：'),
                ],
              ),
            ],
          ),
          // 配件表（整树平铺：编号前缀 *=子级 **=孙级）
          Table(
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            columnWidths: const {
              0: FixedColumnWidth(64), // 序号（缩进 └ + 级联 3.1.1 留宽）
              1: FlexColumnWidth(1.4), // 物料编号
              2: FlexColumnWidth(2.2), // 物料名称
              3: FlexColumnWidth(1.8), // 规格
              4: FlexColumnWidth(1.2), // 颜色
              5: FixedColumnWidth(52), // 数量
              6: FlexColumnWidth(1.2), // 材质
              7: FlexColumnWidth(1.4), // 备注
            },
            children: [
              TableRow(
                decoration: const BoxDecoration(color: UtenColors.slate100),
                children: [
                  for (final h in const [
                    '序号',
                    '物料编号',
                    '物料名称',
                    '规格',
                    '颜色',
                    '数量',
                    '材质',
                    '备注',
                  ])
                    _paperCell(h, bold: true, center: true),
                ],
              ),
              for (var i = 0; i < rows.length; i++)
                TableRow(
                  children: [
                    _paperCell(rows[i].indentedSeq),
                    _paperCell(rows[i].markedCode),
                    _paperCell(rows[i].plainName),
                    _paperCell(rows[i].item.componentSpec ?? ''),
                    _paperCell(rows[i].item.componentColorName ?? ''),
                    _paperCell(_qty(rows[i].item.qty), center: true),
                    _paperCell(rows[i].item.componentMaterial ?? ''),
                    _paperCell(rows[i].item.summary ?? ''),
                  ],
                ),
            ],
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
          fontSize: 11,
          color: Colors.black,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
