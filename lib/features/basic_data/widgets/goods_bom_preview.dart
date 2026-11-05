// 货品「预览」：A4 产品配件清单。
//
// 清单含整棵 BOM 树（子类/孙类全展开平铺）。层级只用级联序号表达
// （1 / 3.1 / 3.1.1），不再加缩进与子层星号标记（2026-09-25 口径）；
// 列集与组装信息表格/导出 Excel 一致（「表格显示啥导出啥」）。
// 完整展开上限与服务端同为 11 层 / 2000 行；环路或越界整次拒绝，不发布局部结果。
//
// 弹窗内按 A4 横向比例渲染(多列明细；标题 + 产品名称/型号/备注表头 +
// 明细表格)。用量两列(ADR-129)：「设计使用数量」与只读「真实使用数量」
// (没有数据或不适用显示「—」)，数字与组装信息表格同一格式。底部操作：
// - 打印：pdf 包生成 A4 横向 PDF（NotoSansSC 内置中文字体）→ printing 系统打印对话框；
// - 下载 Excel：复用 UtenExportButton（加密 xlsx，走后端 bom/export，同列集同序号）；
// - 关闭。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/data_display/uten_table_output_scope.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/account_action_owner.dart';
import '../../../shared/platform_tables/table_column_projection.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/goods_bom_item.dart';
import '../repositories/goods_bom_repository.dart';
import 'package:uten_imp/core/ui/human_error_message.dart';

/// 清单行：BOM 行 + 树深度（0=一级组件）+ 级联序号（1 / 3.1 / 3.1.1）。
class _PreviewRow {
  const _PreviewRow(this.item, this.depth, this.seq);

  final GoodsBomItem item;
  final int depth;
  final String seq;

  /// 物料编号（不缩进、不加层级前缀；层级由级联序号表达）。
  String get plainCode => item.componentCode ?? '';

  /// 物料名称（不缩进，列内对齐）。
  String get plainName => item.componentName ?? '';

  /// 列序 = 明细列头；纸面与 PDF 共用，尾包/用量与组装信息
  /// 表格同一口径)。
  List<String> cells({required bool showStock}) => [
    seq,
    plainCode,
    plainName,
    item.componentModel ?? '',
    item.componentSpec ?? '',
    item.componentMaterial ?? '',
    item.componentUnitName ?? '',
    item.componentColorName ?? '',
    if (showStock)
      item.componentStockQty == null
          ? '—'
          : formatBomQty(item.componentStockQty!),
    item.componentSourceType ?? '',
    item.consumptionBasis.label,
    item.basisOutputQtyText,
    item.partialPackageLabel,
    item.designQtyText,
    item.actualQtyText,
    item.summary ?? '',
  ];
}

const _bomOutputTableKey =
    'features.basic_data.widgets.goods_bom_tab.GoodsBomTabState.build.1';
final _openBomPreviews = Expando<bool>();

/// 弹出 A4 产品配件清单预览。
Future<void> showGoodsBomPreview({
  required BuildContext context,
  required String goodsId,
  String? productName,
  String? productModel,
  String? productCode,
}) async {
  if (_openBomPreviews[context] == true) return;
  _openBomPreviews[context] = true;
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    final boundary = container.read(sensitiveReadBoundaryProvider);
    final epoch = container.read(exportContextEpochProvider);
    bool current() =>
        context.mounted &&
        boundary == container.read(sensitiveReadBoundaryProvider) &&
        epoch == container.read(exportContextEpochProvider);
    final projection = TableColumnProjectionScope.resolve(
      context,
      _bomOutputTableKey,
    );
    final scope = await showUtenTableOutputScope(
      context: context,
      action: '预览打印',
      selectedCount: projection?.outputSelection.count ?? 0,
    );
    if (scope == null || !context.mounted || !current()) return;
    List<Map<String, String?>>? selectedRows;
    if (scope == UtenTableOutputScope.selected) {
      final selected = await UtenBusyOverlay.run(
        context,
        title: '正在核对选中组件',
        action: () => projection!.outputSelection.snapshot(),
      );
      if (!context.mounted || !current()) return;
      if (selected.rows.length != selected.count || selected.count == 0) {
        throw const FormatException('选中组件缺少完整输出身份，请刷新后重选');
      }
      selectedRows = List.unmodifiable(
        selected.rows.map((row) => Map<String, String?>.unmodifiable(row)),
      );
    }
    final frozen = projection == null
        ? null
        : TableColumnProjection(
            tableKey: projection.tableKey,
            scope: projection.scope,
            columns: List.unmodifiable(projection.columns),
            sourceKeys: Map.unmodifiable(projection.sourceKeys),
            rowSelection: selectedRows,
          );
    if (!context.mounted || !current()) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _GoodsBomPreviewDialog(
        goodsId: goodsId,
        productName: productName,
        productModel: productModel,
        productCode: productCode,
        selectedRows: selectedRows,
        projection: frozen,
      ),
    );
  } catch (error) {
    if (context.mounted) context.appApiError(error, fallback: '无法打开配件清单预览');
  } finally {
    _openBomPreviews[context] = false;
  }
}

class _GoodsBomPreviewDialog extends ConsumerStatefulWidget {
  const _GoodsBomPreviewDialog({
    required this.goodsId,
    this.productName,
    this.productModel,
    this.productCode,
    this.selectedRows,
    this.projection,
  });

  final String goodsId;
  final String? productName;
  final String? productModel;
  final String? productCode;
  final List<Map<String, String?>>? selectedRows;
  final TableColumnProjection? projection;

  @override
  ConsumerState<_GoodsBomPreviewDialog> createState() =>
      _GoodsBomPreviewDialogState();
}

class _GoodsBomPreviewDialogState
    extends ConsumerState<_GoodsBomPreviewDialog> {
  static const int _maxLevels = 11;
  static const int _maxRows = 2000;
  late final AccountActionOwner _owner;
  bool _printing = false;
  bool _preparingPrint = false;

  List<_PreviewRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _owner = AccountActionOwner(
      ref,
      onInvalidated: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final route = ModalRoute.of(context);
          if (route?.isActive == true) {
            Navigator.of(context).removeRoute(route!);
          }
        });
      },
    );
    _load();
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  /// 整树平铺加载：DFS 逐层调 list 接口（懒加载语义与组装信息页签一致）。
  /// [path] = 当前展开路径上的货品 id（含根），用于环路防护；
  /// [prefix] = 级联序号前缀（'' / '3' / '3.1'）。
  Future<void> _load() async {
    try {
      final repo = ref.read(goodsBomRepositoryProvider);
      final rows = <_PreviewRow>[];
      final cache = <String, List<GoodsBomItem>>{};
      final work = UiWorkBudget(isCurrent: () => mounted && _owner.isCurrent);

      Future<void> walk(
        String goodsId,
        int depth,
        Set<String> path,
        String prefix,
      ) async {
        if (depth >= _maxLevels) {
          throw const FormatException('BOM 层级超过完整输出上限，请从下层组件分别输出');
        }
        final items = cache[goodsId] ??= await repo.list(goodsId);
        work.ensureCurrent();
        for (var i = 0; i < items.length; i++) {
          final it = items[i];
          if (path.contains(it.componentGoodsId)) {
            throw const FormatException('BOM 存在循环引用，本次未生成输出');
          }
          if (it.componentCode?.trim().isNotEmpty != true) {
            throw const FormatException('存在不可见或未编号的组件，无法完整输出');
          }
          if (rows.length >= _maxRows) {
            throw const FormatException('BOM 展开超过 2000 行完整输出上限，请从下层组件分别输出');
          }
          final seq = prefix.isEmpty ? '${i + 1}' : '$prefix.${i + 1}';
          rows.add(_PreviewRow(it, depth, seq));
          if (it.hasChildren) {
            await walk(it.componentGoodsId, depth + 1, {
              ...path,
              it.componentGoodsId,
            }, seq);
          }
          await work.checkpoint();
        }
      }

      await walk(widget.goodsId, 0, {widget.goodsId}, '');
      if (!mounted || !_owner.isCurrent) return;
      final requested = widget.selectedRows;
      if (requested == null) {
        setState(() => _rows = rows);
      } else {
        String identity(String? seq, String? component) => '$seq|$component';
        final wanted = <String>{};
        for (final selector in requested) {
          if (selector['seq']?.isNotEmpty != true ||
              selector['componentGoodsId']?.isNotEmpty != true ||
              !wanted.add(
                identity(selector['seq'], selector['componentGoodsId']),
              )) {
            throw const FormatException('选中组件的输出身份无效或重复，请刷新后重选');
          }
        }
        final selected = <_PreviewRow>[];
        final found = <String>{};
        for (final row in rows) {
          final key = identity(row.seq, row.item.componentGoodsId);
          if (wanted.contains(key)) {
            if (!found.add(key)) {
              throw const FormatException('选中组件的输出身份不唯一，请刷新后重选');
            }
            selected.add(row);
          }
          await work.checkpoint();
        }
        if (found.length != wanted.length) {
          throw const FormatException('选中组件已变化或不在当前结构中，请刷新后重选');
        }
        if (!mounted || !_owner.isCurrent) return;
        setState(() => _rows = selected);
      }
    } catch (caughtError) {
      if (!mounted) return;
      setState(
        () => _error = humanErrorMessage(caughtError) ?? '加载组装信息失败',
      ); // TODO(l10n): 补 arb
    }
  }

  String get _title => '产品配件清单'; // TODO(l10n): 补 arb

  /// 明细列头（= 组装信息表格列；PDF 与纸面共用）。
  bool get _showStock =>
      ref.read(currentPermissionsProvider).contains(Perm.stockView);

  List<String> get _columns => [
    '序号',
    '物料编号',
    '物料名称',
    '型号',
    '规格',
    '材质',
    '单位',
    '颜色',
    if (_showStock) '库存数量',
    '来源',
    '计量方式',
    '基准产量',
    '尾包',
    '设计使用数量',
    '真实使用数量',
    '备注',
  ];

  static const _centeredColumns = {'库存数量', '基准产量', '尾包', '设计使用数量', '真实使用数量'};
  static const _fixedWidths = <String, ({double paper, double pdf})>{
    '序号': (paper: 56, pdf: 44),
    '单位': (paper: 44, pdf: 34),
    '库存数量': (paper: 64, pdf: 52),
    '来源': (paper: 52, pdf: 40),
    '计量方式': (paper: 68, pdf: 52),
    '基准产量': (paper: 62, pdf: 48),
    '尾包': (paper: 44, pdf: 34),
    '设计使用数量': (paper: 60, pdf: 52),
    '真实使用数量': (paper: 60, pdf: 52),
  };
  static const _flexWidths = <String, double>{
    '物料编号': 1.3,
    '物料名称': 1.9,
    '型号': 1.1,
    '规格': 1.5,
    '材质': 0.9,
    '颜色': 0.9,
    '备注': 1.3,
  };

  // ---- 打印（pdf 包生成 A4，NotoSansSC 中文字体） ----------------------------

  Future<void> _print() async {
    if (_printing || !_owner.isCurrent || _rows?.isNotEmpty != true) return;
    final rows = _rows!;
    setState(() {
      _printing = true;
      _preparingPrint = true;
    });
    try {
      // UI 使用常用字子集降低首屏体积；打印按需加载完整字体，确保货品名称中的生僻字不丢失。
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      final font = pw.Font.ttf(fontData);
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          // 横向 A4 与弹窗纸面保持同一列集。
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(28),
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
            // 列集 = 组装信息表格列（「表格显示啥导出啥」，2026-09-25）。
            // 列宽：9pt 字 + 左右各 4pt 内边距，四字表头一行放下；两个用量列
            // 52pt 让「设计使用/数量」整齐折成两行，不会折成三行。
            pw.Table(
              border: pw.TableBorder.all(width: 0.5),
              columnWidths: {
                for (final (index, label) in _columns.indexed)
                  index: _fixedWidths.containsKey(label)
                      ? pw.FixedColumnWidth(_fixedWidths[label]!.pdf)
                      : pw.FlexColumnWidth(_flexWidths[label] ?? 1),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(
                    color: PdfColor.fromInt(0xFFEFEFEF),
                  ),
                  children: [
                    for (final h in _columns)
                      _pdfCell(font, h, bold: true, center: true),
                  ],
                ),
                for (final row in rows)
                  pw.TableRow(
                    children: [
                      for (final (i, text)
                          in row.cells(showStock: _showStock).indexed)
                        _pdfCell(
                          font,
                          text,
                          center: _centeredColumns.contains(_columns[i]),
                        ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      );
      final bytes = await doc.save();
      if (!mounted || !_owner.isCurrent) return;
      setState(() => _preparingPrint = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_owner.isCurrent) return;
      await printPdfBytes(
        bytes,
        '${_title}_${widget.productCode ?? widget.productName ?? 'goods'}.pdf',
      );
    } catch (caughtError) {
      if (!mounted) return;
      context.appApiError(
        caughtError,
        fallback: '生成打印件失败，请稍后重试',
      ); // TODO(l10n): 补 arb
    } finally {
      if (mounted) {
        setState(() {
          _printing = false;
          _preparingPrint = false;
        });
      }
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

  // ---- 渲染 ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final theme = Theme.of(context);
    final rows = _rows;
    // 弹窗文字可框选复制（准则 §3.4：弹窗独立路由自带局部 region；内嵌表格自带更深 region）。
    return Stack(
      children: [
        SelectionArea(
          child: UtenDialogFrame(
            shape: const RoundedRectangleBorder(
              borderRadius: UtenRadius.xxlAll,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 860,
                maxHeight: MediaQuery.sizeOf(context).height * 0.92,
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UtenDialogHeader(
                      title: Text('预览 · $_title'),
                      icon: Icons.description_outlined,
                      showCloseButton: true,
                      onClose: _printing
                          ? null
                          : () => Navigator.of(context).pop(),
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
                    UtenDialogActions(
                      children: [
                        UtenButton(
                          icon: Icons.print_outlined,
                          onPressed: (rows == null || rows.isEmpty || _printing)
                              ? null
                              : _print,
                          child: const Text('打印'), // TODO(l10n): 补 arb
                        ),
                        UtenExportButton(
                          enabled:
                              rows?.isNotEmpty == true &&
                              !_printing &&
                              _error == null,
                          showOutputScope: false,
                          frozenProjection: widget.projection,
                          prepareExport: () async => UtenExportSelection(
                            stillCurrent: () => mounted && _owner.isCurrent,
                          ),
                          type: UtenButtonType.secondary,
                          endpoint: ApiEndpoints.goodsBomExport(widget.goodsId),
                          requiredPermission: Perm.goodsExport,
                          report: '',
                          queryParams: const {},
                          filename:
                              '${_title}_${widget.productCode ?? widget.productName ?? 'goods'}',
                          label: '下载Excel', // TODO(l10n): 补 arb
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if ((_error == null && rows == null) || _preparingPrint)
          UtenBusyOverlay(
            title: _preparingPrint ? '正在生成打印件' : '正在读取完整配件清单',
            showDoNotLeaveHint: false,
          ),
      ],
    );
  }

  /// A4 横向纸面(297:210)。宽 1000 → 高约 707。
  Widget _a4Paper(ThemeData theme, List<_PreviewRow> rows) {
    const paperWidth = 1000.0;
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
          // 配件明细表(整树平铺，层级由级联序号 1/3.1/3.1.1 表达)。
          // 列宽：11px 字 + 左右各 5px 内边距；两个用量列 60 让「设计使用/数量」
          // 整齐折成两行。
          Table(
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            columnWidths: {
              for (final (index, label) in _columns.indexed)
                index: _fixedWidths.containsKey(label)
                    ? FixedColumnWidth(_fixedWidths[label]!.paper)
                    : FlexColumnWidth(_flexWidths[label] ?? 1),
            },
            children: [
              TableRow(
                decoration: const BoxDecoration(color: UtenColors.slate100),
                children: [for (final h in _columns) _PaperHeaderCell(h)],
              ),
              for (final row in rows)
                TableRow(
                  children: [
                    for (final (i, text)
                        in row.cells(showStock: _showStock).indexed)
                      _paperCell(
                        text,
                        center: _centeredColumns.contains(_columns[i]),
                      ),
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

/// 纸面表头格（const 环境下不能调用实例方法，单独一个小 widget）。
class _PaperHeaderCell extends StatelessWidget {
  const _PaperHeaderCell(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 11,
          color: Colors.black,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
