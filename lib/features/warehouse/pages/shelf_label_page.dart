// 货架目视化清单页（仓库管理 hub → 库存查询分区）。
//
// 对标仓库现场挂牌「目视化管理清单 Visual Management List」：
// - 数据：货品主档中已维护库位号（goods.stock_place）的货品，按 库行→层→位 排序；
//   与库存数量无关（货架固定摆放什么就列什么），口径见 GET /api/stock/shelf-labels。
// - 页面：库行下拉（/api/stock/shelf-labels/racks）+ 抬头仓库名（打印标题用）+ 关键字；
//   按库行分组卡片展示（库位号/物料编码/物料系列/物料名称/颜色，与挂牌列一致）。
// - 预览打印：每个库行独立 A4 横版页，复刻挂牌版式（UTEN 头 + 库行徽章 + 斑马纹表），
//   末尾留白行供现场手写补充；PDF 走 pdf/printing（NotoSansSC 全量字体）。
// - Excel 导出：/stock/reports/export report='shelf-labels'（stock_report:export，可加密）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/print/pdf_printer.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../stock/repositories/stock_query_repository.dart';

class ShelfLabelPage extends ConsumerStatefulWidget {
  const ShelfLabelPage({super.key});

  @override
  ConsumerState<ShelfLabelPage> createState() => _ShelfLabelPageState();
}

class _ShelfLabelPageState extends ConsumerState<ShelfLabelPage> {
  List<String>? _racks;
  List<ShelfLabelRow>? _rows;
  bool _loading = false;
  String? _error;
  String? _rack; // null = 全部库行
  String _keyword = '';
  String? _warehouseId; // 仅作打印抬头（挂牌标题「XX仓库物料库」）
  final _titleOverride = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      await _loadRacks();
      await _load();
    });
  }

  @override
  void dispose() {
    _titleOverride.dispose();
    super.dispose();
  }

  Future<void> _loadRacks() async {
    try {
      final racks = await ref
          .read(stockQueryRepositoryProvider)
          .shelfLabelRacks();
      if (!mounted) return;
      setState(() => _racks = racks);
    } catch (_) {
      /* 库行下拉加载失败不阻塞主表（仍可全部查询） */
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await ref
          .read(stockQueryRepositoryProvider)
          .shelfLabels(
            rack: _rack,
            keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
          );
      if (!mounted) return;
      setState(() => _rows = rows);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '加载失败'); // TODO(l10n): 补 arb
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 挂牌标题：用户可手改；默认取所选仓库名 +「物料库」（对标现场「五金仓库物料库」）。
  String get _headerTitle {
    final override = _titleOverride.text.trim();
    if (override.isNotEmpty) return override;
    final name = _warehouseId == null
        ? null
        : ref.read(masterNameServiceProvider).warehouseEntries[_warehouseId];
    if (name == null || name.isEmpty) return '仓库物料库';
    return name.endsWith('物料库') ? name : '$name物料库';
  }

  /// 按库行分组（保持服务端排序：库行 → 层 → 位）。
  List<MapEntry<String, List<ShelfLabelRow>>> get _groups {
    final map = <String, List<ShelfLabelRow>>{};
    for (final r in _rows ?? const <ShelfLabelRow>[]) {
      map.putIfAbsent(r.rack.isEmpty ? '未分库行' : r.rack, () => []).add(r);
    }
    return map.entries.toList();
  }

  Map<String, dynamic> get _exportQuery => <String, dynamic>{
    if (_rack != null) 'rack': _rack,
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final groups = _groups;
    final total = _rows?.length ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '货架目视化清单', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Column(
            children: [
              // 筛选行：抬头仓库名（打印用）+ 库行 + 搜索 + 计数 + 打印/导出
              Padding(
                padding: const EdgeInsets.only(
                  top: UtenSpacing.s12,
                  bottom: UtenSpacing.s8,
                ),
                child: Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 200,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _warehouseId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '抬头仓库(打印标题)', // TODO(l10n): 补 arb
                        ),
                        items: [
                          for (final e in names.warehouseEntries.entries)
                            DropdownMenuItem<String?>(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                        onChanged: (v) => setState(() => _warehouseId = v),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _titleOverride,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '标题覆盖(可选)', // TODO(l10n): 补 arb
                          hintText: '如：五金仓库物料库',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    SizedBox(
                      width: 160,
                      child: DropdownButtonFormField<String?>(
                        initialValue: _rack,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '库行', // TODO(l10n): 补 arb
                        ),
                        items: [
                          const DropdownMenuItem<String?>(child: Text('全部')),
                          for (final r in _racks ?? const <String>[])
                            DropdownMenuItem<String?>(
                              value: r,
                              child: Text('$r 库行'),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _rack = v);
                          _load();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 240,
                      child: UtenSearchBar(
                        hint: '搜索(名称/编码/系列/库位号)', // TODO(l10n): 补 arb
                        onChanged: (kw) {
                          setState(() => _keyword = kw);
                          _load();
                        },
                      ),
                    ),
                    Text(
                      '共 $total 项 · ${groups.length} 个库行', // TODO(l10n): 补 arb
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    UtenButton(
                      size: UtenButtonSize.large,
                      icon: Icons.print_outlined,
                      onPressed: (total == 0 || _loading)
                          ? null
                          : () => _showPrintPreview(context),
                      child: const Text('预览打印'), // TODO(l10n): 补 arb
                    ),
                    UtenExportButton(
                      endpoint: '/stock/reports/export',
                      requiredPermission: Perm.stockReportExport,
                      report: 'shelf-labels',
                      queryParams: _exportQuery,
                      filename: '货架目视化清单',
                      type: UtenButtonType.primary,
                      size: UtenButtonSize.large,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading && _rows == null
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!),
                            const SizedBox(height: UtenSpacing.s8),
                            UtenButton(
                              onPressed: _load,
                              child: const Text('重试'), // TODO(l10n): 补 arb
                            ),
                          ],
                        ),
                      )
                    : total == 0
                    ? const Center(
                        child: Text(
                          '暂无已维护库位号的货品\n请先在货品资料中填写「库位号」(如 A31-3-1)',
                          textAlign: TextAlign.center,
                        ), // TODO(l10n): 补 arb
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s40),
                        itemCount: groups.length,
                        itemBuilder: (_, i) =>
                            _rackCard(theme, groups[i].key, groups[i].value),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单个库行卡片：头部（库行徽章 + 项数）+ 挂牌同款五列表格。
  Widget _rackCard(ThemeData theme, String rack, List<ShelfLabelRow> rows) {
    const teal = Color(0xFF1B7F8E);
    return Card(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: teal,
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Text(
                  _headerTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '$rack 库行',
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '${rows.length} 项',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(1.1),
              1: FlexColumnWidth(1.4),
              2: FlexColumnWidth(),
              3: FlexColumnWidth(2.6),
              4: FlexColumnWidth(0.9),
            },
            border: TableBorder.all(color: Colors.black26, width: 0.5),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFDCF0F3)),
                children: [
                  for (final h in const ['库位号', '物料编码', '物料系列', '物料名称', '颜色'])
                    _headCell(h),
                ],
              ),
              for (var r = 0; r < rows.length; r++)
                TableRow(
                  decoration: BoxDecoration(
                    color: r.isOdd ? const Color(0xFFF2F8FA) : Colors.white,
                  ),
                  children: [
                    _cell(rows[r].place),
                    _cell(rows[r].goodsCode),
                    _cell(rows[r].series),
                    _cell(rows[r].goodsName, alignStart: true),
                    _cell(rows[r].colorName),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _headCell(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
    ),
  );

  static Widget _cell(String? text, {bool alignStart = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    child: Text(
      (text == null || text.isEmpty) ? '' : text,
      textAlign: alignStart ? TextAlign.start : TextAlign.center,
      style: const TextStyle(fontSize: 12),
    ),
  );

  // ---- 预览打印（复刻挂牌版式：每库行独立 A4 横版页，末尾留白行供手写） ----

  void _showPrintPreview(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _ShelfLabelPrintDialog(
        title: _headerTitle,
        groups: _groups,
        exportQuery: _exportQuery,
      ),
    );
  }
}

/// 挂牌打印预览对话框：灰底 + 白纸分页预览，打印生成同版式 PDF。
class _ShelfLabelPrintDialog extends StatefulWidget {
  const _ShelfLabelPrintDialog({
    required this.title,
    required this.groups,
    required this.exportQuery,
  });

  final String title;
  final List<MapEntry<String, List<ShelfLabelRow>>> groups;
  final Map<String, dynamic> exportQuery;

  @override
  State<_ShelfLabelPrintDialog> createState() => _ShelfLabelPrintDialogState();
}

class _ShelfLabelPrintDialogState extends State<_ShelfLabelPrintDialog> {
  static const _teal = PdfColor.fromInt(0xFF1B7F8E);
  static const _tealLight = PdfColor.fromInt(0xFFF2F8FA);
  static const _rowsPerPage = 16; // 每页数据行（不含末尾留白）
  static const _blankRows = 6; // 每库行末尾留白行（现场手写补充位）

  Future<void> _print() async {
    try {
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      final font = pw.Font.ttf(fontData);
      final doc = pw.Document();
      for (final g in widget.groups) {
        final rows = g.value;
        for (var i = 0; i < rows.length || i == 0; i += _rowsPerPage) {
          final chunk = i < rows.length
              ? rows.sublist(
                  i,
                  i + _rowsPerPage > rows.length
                      ? rows.length
                      : i + _rowsPerPage,
                )
              : const <ShelfLabelRow>[];
          final isLastChunk = i + _rowsPerPage >= rows.length;
          doc.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4.landscape,
              margin: const pw.EdgeInsets.all(24),
              build: (_) => _pdfLabelPage(
                font,
                g.key,
                chunk,
                padBlanks: isLastChunk ? _blankRows : 0,
              ),
            ),
          );
          if (rows.isEmpty) break;
        }
      }
      await printPdfBytes(await doc.save(), '${widget.title}-货架目视化清单.pdf');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('生成打印件失败，请稍后重试')));
    }
  }

  /// PDF 单页：UTEN 头（左 logo 文案 / 中标题 / 右库行徽章）+ 五列斑马表 + 留白行。
  pw.Widget _pdfLabelPage(
    pw.Font font,
    String rack,
    List<ShelfLabelRow> rows, {
    int padBlanks = 0,
  }) {
    pw.Widget hCell(String t) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: pw.Text(
        t,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          font: font,
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.white,
        ),
      ),
    );
    pw.Widget dCell(String? t, {bool start = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: pw.Text(
        t ?? '',
        textAlign: start ? pw.TextAlign.left : pw.TextAlign.center,
        style: pw.TextStyle(font: font, fontSize: 9),
      ),
    );
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          color: _teal,
          padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: pw.Row(
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'UTEN优腾',
                    style: pw.TextStyle(
                      font: font,
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.white,
                    ),
                  ),
                  pw.Text(
                    '德国工匠 · 质造开关',
                    style: pw.TextStyle(
                      font: font,
                      fontSize: 7,
                      color: PdfColors.white,
                    ),
                  ),
                ],
              ),
              pw.Expanded(
                child: pw.Column(
                  children: [
                    pw.Text(
                      widget.title,
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        font: font,
                        fontSize: 14,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.white,
                      ),
                    ),
                    pw.Text(
                      '目视化管理清单 Visual Management List',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        font: font,
                        fontSize: 10,
                        color: PdfColors.white,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  borderRadius: pw.BorderRadius.circular(3),
                ),
                child: pw.Text(
                  '$rack库行',
                  style: pw.TextStyle(
                    font: font,
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 6),
        pw.Table(
          border: pw.TableBorder.all(width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(1.1),
            1: pw.FlexColumnWidth(1.4),
            2: pw.FlexColumnWidth(),
            3: pw.FlexColumnWidth(2.6),
            4: pw.FlexColumnWidth(0.9),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _teal),
              children: [
                for (final h in ['库位号', '物料编码', '物料系列', '物料名称', '颜色']) hCell(h),
              ],
            ),
            for (var i = 0; i < rows.length; i++)
              pw.TableRow(
                decoration: pw.BoxDecoration(
                  color: i.isOdd ? _tealLight : PdfColors.white,
                ),
                children: [
                  dCell(rows[i].place),
                  dCell(rows[i].goodsCode),
                  dCell(rows[i].series),
                  dCell(rows[i].goodsName, start: true),
                  dCell(rows[i].colorName),
                ],
              ),
            for (var i = 0; i < padBlanks; i++)
              pw.TableRow(
                children: [
                  dCell(' '),
                  dCell(''),
                  dCell(''),
                  dCell(''),
                  dCell(''),
                ],
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                        '预览 · ${widget.title} · 货架目视化清单', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      size: UtenButtonSize.small,
                      icon: Icons.print_outlined,
                      onPressed: widget.groups.isEmpty ? null : _print,
                      child: const Text('打印'), // TODO(l10n): 补 arb
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    UtenExportButton(
                      endpoint: '/stock/reports/export',
                      report: 'shelf-labels',
                      queryParams: widget.exportQuery,
                      filename: '货架目视化清单',
                      requiredPermission: Perm.stockReportExport,
                      label: '下载Excel', // TODO(l10n): 补 arb
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'), // TODO(l10n): 补 arb
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
                    child: Center(
                      child: Column(
                        children: [
                          for (final g in widget.groups) ...[
                            _paperLabel(theme, g.key, g.value),
                            const SizedBox(height: UtenSpacing.s16),
                          ],
                        ],
                      ),
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

  /// 屏上纸面预览（与 PDF 同款版式；一个库行一张纸，row 多示意截断提示打印分页）。
  Widget _paperLabel(ThemeData theme, String rack, List<ShelfLabelRow> rows) {
    const teal = Color(0xFF1B7F8E);
    const tealLight = Color(0xFFF2F8FA);
    return Container(
      width: 1000,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: teal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'UTEN优腾',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '德国工匠 · 质造开关',
                      style: TextStyle(color: Colors.white, fontSize: 8),
                    ),
                  ],
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Text(
                        '目视化管理清单 Visual Management List',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '$rack库行',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(1.1),
              1: FlexColumnWidth(1.4),
              2: FlexColumnWidth(),
              3: FlexColumnWidth(2.6),
              4: FlexColumnWidth(0.9),
            },
            border: TableBorder.all(color: Colors.black54, width: 0.5),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: teal),
                children: [
                  for (final h in ['库位号', '物料编码', '物料系列', '物料名称', '颜色'])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      child: Text(
                        h,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              for (var i = 0; i < rows.length; i++)
                TableRow(
                  decoration: BoxDecoration(
                    color: i.isOdd ? tealLight : Colors.white,
                  ),
                  children: [
                    _paperCell(rows[i].place),
                    _paperCell(rows[i].goodsCode),
                    _paperCell(rows[i].series),
                    _paperCell(rows[i].goodsName, start: true),
                    _paperCell(rows[i].colorName),
                  ],
                ),
              for (var i = 0; i < 6; i++)
                const TableRow(
                  children: [
                    _BlankCell(),
                    _BlankCell(),
                    _BlankCell(),
                    _BlankCell(),
                    _BlankCell(),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '共 ${rows.length} 项 · 打印时每个库行自动分页',
              style: const TextStyle(fontSize: 9, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _paperCell(String? text, {bool start = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: Text(
      text ?? '',
      textAlign: start ? TextAlign.start : TextAlign.center,
      style: const TextStyle(fontSize: 10, color: Colors.black),
    ),
  );
}

class _BlankCell extends StatelessWidget {
  const _BlankCell();

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.all(12), child: Text(' '));
}
