// 通用「预览 → 打印」组件（所有表格页共用，对齐货品资料 BOM 预览体验）。
//
// 用法：AppBar 放 UtenPrintPreviewButton（通常在 UtenExportButton 旁），点击弹 A4 纸面预览：
// - 预览：标题 + 副标题（筛选口径/日期范围）+ 表格（灰底 + 白纸，A4 横版自动分页，
//   每页重复表头 + 页码，列等宽撑满纸宽保证横向显示全）；
// - 打印：pdf 包生成 A4 横版 PDF（NotoSansSC 内置中文字体）→ printing 系统打印对话框；
// - 下载 Excel：可选，复用 UtenExportButton（加密 xlsx 走后端导出，与页内导出口径一致）；
// - 数据：loader 返回"显示就绪"的表头 + 行（报表页用 formatReportCell 格式化，与页面表格同口径）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/platform_tables/table_column_projection.dart';
import '../../shared/platform_tables/platform_table_models.dart';
import '../../shared/platform_tables/platform_table_repository.dart';
import '../../shared/business_columns/business_column.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/print/pdf_printer.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../buttons/uten_button.dart';
import '../buttons/uten_export_button.dart';

/// 打印表格数据：表头 + 行（均为显示就绪字符串）。
class UtenPrintTable {
  const UtenPrintTable({
    required this.headers,
    required this.rows,
    this.columnKeys,
    this.rowIds,
    this.factValues,
    this.columnWidths,
  });

  final List<String> headers;
  final List<List<String>> rows;

  /// Stable schema IDs; labels are never used as field identity.
  final List<String>? columnKeys;
  final List<String?>? rowIds;

  /// Unformatted, authorized facts for report calculations; one map per row.
  final List<Map<String, String?>>? factValues;
  final List<double>? columnWidths;
}

/// Shared by paper preview and PDF; stale/missing field bindings fail visibly.
Future<UtenPrintTable> projectUtenPrintTable(
  UtenPrintTable source,
  TableColumnProjection? projection, {
  PlatformTableRepository? repository,
}) async {
  if (projection == null) return source;
  final keys = source.columnKeys;
  if (keys == null ||
      keys.length != source.headers.length ||
      keys.toSet().length != keys.length) {
    throw const FormatException('打印数据尚未绑定唯一字段编号，不能套用当前表头');
  }
  if (source.rows.any((row) => row.length != keys.length)) {
    throw const FormatException('打印数据列数与字段编号不一致，请刷新后重试');
  }
  if (projection.columns.isEmpty ||
      projection.columns.map((c) => c.key).toSet().length !=
          projection.columns.length) {
    throw const FormatException('当前打印表头为空或有重复字段');
  }
  final indexes = {for (var i = 0; i < keys.length; i++) keys[i]: i};
  int? indexOf(TableProjectedColumn column) =>
      indexes[column.sourceKey ??
          projection.sourceKeys[column.key] ??
          column.key] ??
      indexes[column.key];
  final dynamicColumns = projection.columns
      .where((column) => indexOf(column) == null)
      .toList();
  final records = <String, PlatformRowValues>{};
  PlatformTableCapabilities? capabilities;
  if (dynamicColumns.isNotEmpty) {
    if (repository == null ||
        projection.scope == null ||
        dynamicColumns.any((c) => !c.key.startsWith('platform:'))) {
      throw const FormatException('当前表头包含尚未加载的字段，不能省略后继续打印');
    }
    final scopes = await repository.scopes();
    final matches = scopes.where((s) => s.scope == projection.scope);
    if (matches.isEmpty) throw const FormatException('当前账号不能读取这些扩展字段');
    capabilities = matches.first;
    if (capabilities.supportsValues) {
      if (source.rowIds == null ||
          source.rowIds!.length != source.rows.length ||
          source.rowIds!.any((id) => id == null || id.isEmpty)) {
        throw const FormatException('打印扩展字段需要每行的真实记录编号');
      }
      final ids = source.rowIds!.whereType<String>().toSet().toList();
      for (var start = 0; start < ids.length; start += 200) {
        final end = (start + 200).clamp(0, ids.length);
        for (final row in await repository.rows(
          projection.scope!,
          ids.sublist(start, end),
          columnIds: dynamicColumns
              .map((c) => c.key.substring('platform:'.length))
              .toList(),
        )) {
          records[row.recordId] = row;
        }
      }
      if (ids.any((id) => !records.containsKey(id))) {
        throw const FormatException('部分打印记录已失效或不在查看范围内');
      }
    }
  }
  final definitions = <String, PlatformColumnDefinition>{};
  if (dynamicColumns.isNotEmpty && capabilities?.supportsValues == false) {
    final authorized = await repository!.search(
      projection.scope!,
      '',
      ids: dynamicColumns
          .map((column) => column.key.substring('platform:'.length))
          .toList(),
    );
    for (final definition in authorized) {
      definitions[definition.key] = definition;
    }
    if (dynamicColumns.any((column) => !definitions.containsKey(column.key))) {
      throw const FormatException('打印字段缺少当前服务器授权定义，请刷新表格');
    }
  }
  if (source.factValues != null &&
      source.factValues!.length != source.rows.length) {
    throw const FormatException('打印计算依据与明细行数不一致');
  }
  String? calculate(int row, String key, Set<String> visiting) {
    if (visiting.contains(key)) throw const FormatException('计算展示列存在循环引用');
    final definition = definitions[key];
    if (definition?.formula == null || definition?.calculated != true) {
      throw const FormatException('打印字段缺少服务器定义，请刷新表格');
    }
    if (definition!.priceProtected && capabilities?.priceVisible != true) {
      throw const FormatException('当前账号不能打印所选计算列的价格信息');
    }
    final allowed = {
      for (final fact in capabilities?.facts ?? const <PlatformTableFact>[])
        fact.key: fact,
    };
    return definition.formula!.calculate((operand) {
      if (operand.constant != null) {
        return businessExactDecimal(operand.constant);
      }
      if (operand.fact != null) {
        final fact = allowed[operand.fact];
        if (fact == null ||
            fact.priceProtected && capabilities?.priceVisible != true) {
          throw const FormatException('当前账号不能打印计算列引用的业务字段');
        }
        final value = platformExactFact(
          source.factValues?[row][operand.fact] ??
              source.factValues?[row][projection.sourceKeys[operand.fact]],
        );
        if (value == null) {
          throw FormatException('打印缺少“${fact.name}”的原始数字，不能用格式化文字代替');
        }
        return value;
      }
      final referenceKey = 'platform:${operand.columnId}';
      if (!definitions.containsKey(referenceKey)) {
        throw const FormatException('打印计算列缺少依赖定义，请刷新表格');
      }
      return calculate(row, referenceKey, {...visiting, key});
    });
  }

  return UtenPrintTable(
    headers: projection.columns.map((c) => c.label).toList(growable: false),
    columnKeys: projection.columns.map((c) => c.key).toList(growable: false),
    columnWidths: projection.columns
        .map((c) => c.width.isFinite ? c.width.clamp(1.0, 2000.0) : 100.0)
        .toList(growable: false),
    rowIds: source.rowIds,
    factValues: source.factValues,
    rows: [
      for (var row = 0; row < source.rows.length; row++)
        [
          for (final column in projection.columns)
            if (indexOf(column) != null)
              source.rows[row][indexOf(column)!]
            else if (capabilities?.supportsValues == false)
              calculate(row, column.key, {}) ?? '—'
            else
              _printRecordValue(records[source.rowIds![row]], column.key),
        ],
    ],
  );
}

String _printRecordValue(PlatformRowValues? row, String key) {
  final cells = row?.cells.where((cell) => key == 'platform:${cell.columnId}');
  if (cells == null || cells.isEmpty) {
    throw const FormatException('扩展字段未完整返回，不能省略后继续打印');
  }
  final cell = cells.first;
  if (cell.masked) return '***';
  if (cell.error != null) {
    throw const FormatException('扩展字段尚未计算成功，请刷新后重试打印');
  }
  return cell.value ?? '';
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
  Map<String, dynamic>? exportBody,
  String? exportFilename,
  String? exportPermission,
  String? tableKey,
  bool applyTableProjection = true,
}) {
  final projection = applyTableProjection
      ? TableColumnProjectionScope.resolve(context, tableKey)
      : null;
  if (applyTableProjection &&
      TableColumnProjectionScope.hasCurrentTables(context) &&
      projection == null) {
    context.appError('当前页面有多张表格，请明确选择要预览的表头');
    return Future<void>.value();
  }
  PlatformTableRepository? repository;
  if (projection?.columns.any((column) => column.key.startsWith('platform:')) ==
      true) {
    try {
      repository = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(platformTableRepositoryProvider);
    } on StateError {
      /* Standalone projections fail visibly if required dynamic data has no repository. */
    }
  }
  return showDialog<void>(
    context: context,
    builder: (_) => _UtenPrintPreviewDialog(
      title: title,
      subtitle: subtitle,
      loader: loader,
      exportEndpoint: exportEndpoint,
      exportReport: exportReport,
      exportQuery: exportQuery,
      exportBody: exportBody,
      exportFilename: exportFilename,
      exportPermission: exportPermission,
      projection: projection,
      repository: repository,
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
    this.exportBody,
    this.exportFilename,
    this.exportPermission,
    this.tableKey,
    this.applyTableProjection = true,
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

  /// 不能进 URL 的导出筛选值 (随导出密码放请求体)。
  final Map<String, dynamic>? exportBody;
  final String? exportFilename;
  final String? exportPermission;
  final String? tableKey;
  final bool applyTableProjection;

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
      // 工具条 large 档高度统一到 UtenTableToolbar.controlHeight（2026-09-25
      // 平台统一口径：顶部按钮稍矮一档；全站 16+ 调用点随组件一次收口）。
      height: size == UtenButtonSize.large
          ? UtenTableToolbar.controlHeight
          : null,
      icon: Icons.print_outlined,
      onPressed: () => showUtenPrintPreview(
        context: context,
        title: title,
        subtitle: subtitle,
        loader: loader,
        exportEndpoint: exportEndpoint,
        exportReport: exportReport,
        exportQuery: exportQuery,
        exportBody: exportBody,
        exportFilename: exportFilename,
        exportPermission: exportPermission,
        tableKey: tableKey,
        applyTableProjection: applyTableProjection,
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
    this.exportBody,
    this.exportFilename,
    this.exportPermission,
    this.projection,
    this.repository,
  });

  final String title;
  final String? subtitle;
  final Future<UtenPrintTable> Function() loader;
  final String? exportEndpoint;
  final String? exportReport;
  final Map<String, dynamic>? exportQuery;

  /// 不能进 URL 的导出筛选值 (随导出密码放请求体)。
  final Map<String, dynamic>? exportBody;
  final String? exportFilename;
  final String? exportPermission;
  final TableColumnProjection? projection;
  final PlatformTableRepository? repository;

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
      final loaded = await widget.loader();
      final t = await projectUtenPrintTable(
        loaded,
        widget.projection,
        repository: widget.repository,
      );
      if (!mounted) return;
      setState(() => _table = t);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is FormatException ? error.message : '加载数据失败，请重试',
      ); // TODO(l10n): 补 arb
    }
  }

  // ---- 打印（pdf 包生成 A4 横版，NotoSansSC 中文字体） ----------------------

  Future<void> _print() async {
    final t = _table;
    if (t == null) return;
    try {
      // UI 使用常用字子集降低首屏体积；打印按需加载完整字体，确保业务数据中的生僻字不丢失。
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
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
                  font: font,
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
              pw.SizedBox(height: 4),
              pw.Center(
                child: pw.Text(
                  widget.subtitle!,
                  style: pw.TextStyle(font: font, fontSize: 9),
                ),
              ),
            ],
            pw.SizedBox(height: 10),
            pw.Table(
              columnWidths: {
                for (var i = 0; i < t.headers.length; i++)
                  i: pw.FlexColumnWidth(t.columnWidths?[i] ?? 1),
              },
              border: pw.TableBorder.all(width: 0.5),
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(
                    color: PdfColor.fromInt(0xFFEFEFEF),
                  ),
                  children: [
                    for (final h in t.headers)
                      _pdfCell(font, h, bold: true, center: true),
                  ],
                ),
                for (final row in t.rows)
                  pw.TableRow(
                    children: [for (final c in row) _pdfCell(font, c)],
                  ),
              ],
            ),
          ],
        ),
      );
      await printPdfBytes(await doc.save(), '${widget.title}.pdf');
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
                        '预览 · ${widget.title}', // TODO(l10n): 补 arb
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
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
                        bodyParams: {
                          ...?widget.exportBody,
                          if (widget.projection != null)
                            'columnProjection': widget.projection!.toJson(),
                        },
                        filename: widget.exportFilename ?? widget.title,
                        requiredPermission: widget.exportPermission,
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
      final end = i + _rowsPerPage > t.rows.length
          ? t.rows.length
          : i + _rowsPerPage;
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
  Widget _a4Page(
    ThemeData theme,
    UtenPrintTable t,
    List<List<String>> rows,
    int pageIndex,
    int pageCount,
    double paperWidth,
  ) {
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
                i: FlexColumnWidth(t.columnWidths?[i] ?? 1),
            },
            border: TableBorder.all(color: Colors.black54, width: 0.6),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: UtenColors.slate100),
                children: [
                  for (final h in t.headers)
                    _paperCell(h, bold: true, center: true),
                ],
              ),
              for (final row in rows)
                TableRow(children: [for (final c in row) _paperCell(c)]),
            ],
          ),
          if (rows.isEmpty && pageIndex == 0)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  '暂无数据', // TODO(l10n): 补 arb
                  style: TextStyle(color: Colors.black54),
                ),
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
