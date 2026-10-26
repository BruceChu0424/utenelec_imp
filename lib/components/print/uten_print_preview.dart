// 通用「预览 → 打印」组件（所有表格页共用，对齐货品资料 BOM 预览体验）。
//
// 用法：AppBar 放 UtenPrintPreviewButton（通常在 UtenExportButton 旁），点击弹 A4 纸面预览：
// - 预览：标题 + 副标题（筛选口径/日期范围）+ 表格（灰底 + 白纸，A4 横版自动分页，
//   每页重复表头 + 页码，列等宽撑满纸宽保证横向显示全）；
// - 打印：pdf 包生成 A4 横版 PDF（NotoSansSC 内置中文字体）→ printing 系统打印对话框；
// - 下载 Excel：可选，复用 UtenExportButton（加密 xlsx 走后端导出，与页内导出口径一致）；
// - 数据：loader 返回"显示就绪"的表头 + 行（报表页用 formatReportCell 格式化，与页面表格同口径）。
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/platform_tables/table_column_projection.dart';
import '../../shared/platform_tables/platform_table_models.dart';
import '../../shared/platform_tables/platform_table_repository.dart';
import '../../shared/business_columns/business_column.dart';
import '../../shared/providers/sensitive_read_boundary_provider.dart';

import '../../core/print/pdf_printer.dart';
import '../../core/print/isolated_print_pdf.dart';
import '../../core/performance/ui_work_budget.dart';
import '../../core/network/read_scope_revision.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../buttons/uten_button.dart';
import '../buttons/uten_export_button.dart';
import '../feedback/uten_dialog.dart';
import '../layout/uten_app_bar_action_scope.dart';
import '../data_display/uten_selection_lifecycle.dart';

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
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget();
  work.ensureCurrent();
  if (projection == null) return source;
  final keys = source.columnKeys;
  if (keys == null ||
      keys.length != source.headers.length ||
      keys.toSet().length != keys.length) {
    throw const FormatException('打印数据尚未绑定唯一字段编号，不能套用当前表头');
  }
  for (final row in source.rows) {
    if (row.length != keys.length) {
      throw const FormatException('打印数据列数与字段编号不一致，请刷新后重试');
    }
    await work.checkpoint();
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
    work.ensureCurrent();
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
          work.ensureCurrent();
          records[row.recordId] = row;
          await work.checkpoint();
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
    work.ensureCurrent();
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
  final allowed = {
    for (final fact in capabilities?.facts ?? const <PlatformTableFact>[])
      fact.key: fact,
  };
  String? calculate(int row, String key, Set<String> visiting) {
    if (visiting.contains(key)) throw const FormatException('计算展示列存在循环引用');
    final definition = definitions[key];
    if (definition?.formula == null || definition?.calculated != true) {
      throw const FormatException('打印字段缺少服务器定义，请刷新表格');
    }
    if (definition!.priceProtected && capabilities?.priceVisible != true) {
      throw const FormatException('当前账号不能打印所选计算列的价格信息');
    }
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

  final sourceIndexes = projection.columns.map(indexOf).toList(growable: false);
  final rows = <List<String>>[];
  for (var row = 0; row < source.rows.length; row++) {
    final cells = <String>[];
    for (
      var columnIndex = 0;
      columnIndex < projection.columns.length;
      columnIndex++
    ) {
      final column = projection.columns[columnIndex];
      final sourceIndex = sourceIndexes[columnIndex];
      cells.add(
        sourceIndex != null
            ? source.rows[row][sourceIndex]
            : capabilities?.supportsValues == false
            ? calculate(row, column.key, {}) ?? '—'
            : _printRecordValue(records[source.rowIds![row]], column.key),
      );
      await work.checkpoint();
    }
    rows.add(cells);
  }
  work.ensureCurrent();
  return UtenPrintTable(
    headers: projection.columns.map((c) => c.label).toList(growable: false),
    columnKeys: projection.columns.map((c) => c.key).toList(growable: false),
    columnWidths: projection.columns
        .map((c) => c.width.isFinite ? c.width.clamp(1.0, 2000.0) : 100.0)
        .toList(growable: false),
    rowIds: source.rowIds,
    factValues: source.factValues,
    rows: rows,
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

const _previewRowsPerPage = 20;

/// Full paper selection is independent of which lazy pages are mounted.
/// Keep the original SelectionArea's concatenated paragraph order, including
/// repeated headers and page captions; no business value is reformatted.
Future<String> buildUtenPrintSelectionText(
  UtenPrintTable table,
  String title, {
  String? subtitle,
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget();
  work.ensureCurrent();
  final text = StringBuffer()..write(title);
  if (subtitle != null && subtitle.isNotEmpty) text.write(subtitle);
  final count =
      ((table.rows.length + _previewRowsPerPage - 1) ~/ _previewRowsPerPage)
          .clamp(1, 1 << 30);
  for (var page = 0; page < count; page++) {
    for (final header in table.headers) {
      text.write(header);
      await work.checkpoint();
    }
    final end = ((page + 1) * _previewRowsPerPage).clamp(0, table.rows.length);
    for (var index = page * _previewRowsPerPage; index < end; index++) {
      for (final cell in table.rows[index]) {
        text.write(cell);
        await work.checkpoint();
      }
    }
    if (table.rows.isEmpty) text.write('暂无数据');
    text.write('第 ${page + 1} / $count 页 · 共 ${table.rows.length} 行');
    await work.checkpoint();
  }
  work.ensureCurrent();
  return text.toString();
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
  context = UtenAppBarActionScope.actionContextOf(context);
  final projection = applyTableProjection
      ? TableColumnProjectionScope.resolve(context, tableKey)
      : null;
  if (applyTableProjection &&
      TableColumnProjectionScope.hasCurrentTables(context) &&
      projection == null) {
    context.appError('当前页面有多张表格，请明确选择要预览的表头');
    return Future<void>.value();
  }
  ProviderContainer? container;
  try {
    container = ProviderScope.containerOf(context, listen: false);
  } on StateError {
    // Standalone paper previews also work outside the authenticated app shell.
  }
  final readBoundary = container?.read(sensitiveReadBoundaryProvider);
  final readRevision = container?.read(readScopeRevisionProvider);
  PlatformTableRepository? repository;
  if (projection?.columns.any((column) => column.key.startsWith('platform:')) ==
      true) {
    try {
      repository = container?.read(platformTableRepositoryProvider);
    } on StateError {
      /* Standalone projections fail visibly if required dynamic data has no repository. */
    }
  }
  return showDialog<void>(
    context: context,
    builder: (_) {
      final dialog = _UtenPrintPreviewDialog(
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
        providerContainer: container,
        readBoundary: readBoundary,
        readRevision: readRevision,
      );
      return container == null
          ? dialog
          : UncontrolledProviderScope(container: container, child: dialog);
    },
  );
}

/// AppBar「预览打印」按钮（与 UtenExportButton 同款紧凑文字按钮）。
class UtenPrintPreviewButton extends StatelessWidget {
  const UtenPrintPreviewButton({
    super.key,
    required this.title,
    this.subtitle,
    this.enabled = true,
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
    this.icon = Icons.print_outlined,
  });

  final String title;
  final String? subtitle;
  final bool enabled;
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
  /// 表格工具条场景传 primary/large（与「表头设置 / 全屏」同款纯文字，
  /// 传 icon: null——2026-10-08 工具条无 icon 口径）。
  final UtenButtonType type;
  final UtenButtonSize size;

  /// 按钮图标；null = 纯文字（工具条口径）。
  final IconData? icon;

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
      icon: icon,
      onPressed: !enabled
          ? null
          : () => showUtenPrintPreview(
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
    this.providerContainer,
    this.readBoundary,
    this.readRevision,
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
  final ProviderContainer? providerContainer;
  final SensitiveReadBoundary? readBoundary;
  final int? readRevision;

  @override
  State<_UtenPrintPreviewDialog> createState() =>
      _UtenPrintPreviewDialogState();
}

class _UtenPrintPreviewDialogState extends State<_UtenPrintPreviewDialog> {
  UtenPrintTable? _table;
  String? _error;
  ProviderSubscription<SensitiveReadBoundary>? _boundarySubscription;
  ProviderSubscription<int>? _revisionSubscription;
  int _contextVersion = 0;
  bool _invalidated = false;
  bool _printing = false;
  final _pdfGenerator = IsolatedPrintPdfGenerator();
  final _paperSelectionKey = GlobalKey<SelectionAreaState>();
  String _selectedPaperText = '';
  bool _allPaperSelected = false;
  int _selectionRevision = 0;

  void _resetFullPaperSelection() {
    _selectionRevision++;
    _allPaperSelected = false;
  }

  @override
  void initState() {
    super.initState();
    _boundarySubscription = widget.providerContainer?.listen(
      sensitiveReadBoundaryProvider,
      (_, next) {
        if (next == widget.readBoundary || _invalidated || !mounted) return;
        _retireRead();
      },
      fireImmediately: true,
    );
    _revisionSubscription = widget.providerContainer?.listen(
      readScopeRevisionProvider,
      (_, next) {
        if (next == widget.readRevision || _invalidated || !mounted) return;
        _retireRead();
      },
      fireImmediately: true,
    );
    _load();
  }

  void _retireRead() {
    if (_invalidated || !mounted) return;
    setState(() {
      _contextVersion++;
      _invalidated = true;
      _printing = false;
      _table = null;
      _pdfGenerator.dispose();
      _resetFullPaperSelection();
      _selectedPaperText = '';
      _error = '账号、服务器或权限已变化，请关闭后重新预览';
    });
  }

  bool _isCurrent(int version) {
    if (!mounted || _invalidated || version != _contextVersion) return false;
    try {
      return widget.providerContainer == null ||
          (widget.readBoundary ==
                  widget.providerContainer!.read(
                    sensitiveReadBoundaryProvider,
                  ) &&
              widget.readRevision ==
                  widget.providerContainer!.read(readScopeRevisionProvider));
    } on StateError {
      return false;
    }
  }

  @override
  void dispose() {
    _contextVersion++;
    _selectionRevision++;
    _pdfGenerator.dispose();
    _boundarySubscription?.close();
    _revisionSubscription?.close();
    super.dispose();
  }

  void _selectAllPaperText(SelectionChangedCause cause) {
    if (_table == null || !_isCurrent(_contextVersion)) return;
    _selectionRevision++;
    _allPaperSelected = true;
    _paperSelectionKey.currentState?.selectableRegion.selectAll(cause);
  }

  Future<void> _copyPaperText() async {
    final version = _contextVersion;
    final selection = _selectionRevision;
    final table = _table;
    bool current() => _isCurrent(version) && selection == _selectionRevision;
    if (table == null || !current()) return;
    try {
      final text = _allPaperSelected
          ? await buildUtenPrintSelectionText(
              table,
              widget.title,
              subtitle: widget.subtitle,
              budget: UiWorkBudget(isCurrent: current),
            )
          : _selectedPaperText;
      if (!current() || text.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: text));
      if (current()) {
        _paperSelectionKey.currentState?.selectableRegion.hideToolbar();
      }
    } on UiWorkCancelled {
      // No stale document is copied after a different selection or identity.
    } catch (_) {
      if (mounted && current()) context.appError('复制失败，请重试');
    }
  }

  Widget _paperSelection(Widget child) => Listener(
    onPointerDown: (event) {
      if (event.buttons == kPrimaryButton) _resetFullPaperSelection();
    },
    child: Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            const [
              LogicalKeyboardKey.arrowLeft,
              LogicalKeyboardKey.arrowRight,
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.home,
              LogicalKeyboardKey.end,
              LogicalKeyboardKey.escape,
            ].contains(event.logicalKey)) {
          _resetFullPaperSelection();
        }
        return KeyEventResult.ignored;
      },
      child: Actions(
        actions: {
          SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
            onInvoke: (intent) {
              _selectAllPaperText(intent.cause);
              return null;
            },
          ),
          CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
            onInvoke: (_) => _copyPaperText(),
          ),
        },
        child: UtenSelectionArea(
          selectionKey: _paperSelectionKey,
          onSelectionChanged: (content) =>
              _selectedPaperText = content?.plainText ?? '',
          contextMenuBuilder: (context, region) =>
              AdaptiveTextSelectionToolbar.buttonItems(
                anchors: region.contextMenuAnchors,
                buttonItems: [
                  for (final item in region.contextMenuButtonItems)
                    if (item.type == ContextMenuButtonType.copy)
                      ContextMenuButtonItem(
                        type: item.type,
                        label: item.label,
                        onPressed: _copyPaperText,
                      )
                    else if (item.type == ContextMenuButtonType.selectAll)
                      ContextMenuButtonItem(
                        type: item.type,
                        label: item.label,
                        onPressed: () =>
                            _selectAllPaperText(SelectionChangedCause.toolbar),
                      )
                    else
                      item,
                ],
              ),
          child: child,
        ),
      ),
    ),
  );

  Future<void> _load() async {
    final version = _contextVersion;
    if (!_isCurrent(version)) return;
    try {
      final loaded = await widget.loader();
      if (!_isCurrent(version)) return;
      final t = await projectUtenPrintTable(
        loaded,
        widget.projection,
        repository: widget.repository,
        budget: UiWorkBudget(isCurrent: () => _isCurrent(version)),
      );
      if (!_isCurrent(version)) return;
      setState(() => _table = t);
    } catch (error) {
      if (!_isCurrent(version)) return;
      setState(
        () => _error = error is FormatException ? error.message : '加载数据失败，请重试',
      ); // TODO(l10n): 补 arb
    }
  }

  // ---- 打印（pdf 包生成 A4 横版，NotoSansSC 中文字体） ----------------------

  Future<void> _print() async {
    final version = _contextVersion;
    final t = _table;
    if (t == null || _printing || !_isCurrent(version)) return;
    setState(() => _printing = true);
    try {
      // UI 使用常用字子集降低首屏体积；打印按需加载完整字体，确保业务数据中的生僻字不丢失。
      final fontData = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      if (!_isCurrent(version)) return;
      final bytes = await _pdfGenerator.generate(
        PrintPdfRequest(
          title: widget.title,
          subtitle: widget.subtitle,
          headers: t.headers,
          rows: t.rows,
          columnWidths: t.columnWidths,
          fontBytes: fontData.buffer.asUint8List(
            fontData.offsetInBytes,
            fontData.lengthInBytes,
          ),
        ),
      );
      if (!_isCurrent(version)) return;
      await printPdfBytes(bytes, '${widget.title}.pdf');
    } catch (_) {
      if (!mounted || !_isCurrent(version)) return;
      context.appError('生成打印件失败，请稍后重试'); // TODO(l10n): 补 arb
    } finally {
      if (_isCurrent(version)) setState(() => _printing = false);
    }
  }

  // 屏幕预览的工具条与纸面可以滚动；PDF 的纸张、字号和分页保持原契约。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final table = _table;
    return UtenDialogFrame(
      maxWidth: 1080,
      fillHeight: true,
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverToBoxAdapter(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _invalidated ? '预览已失效' : '预览 · ${widget.title}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: UtenSpacing.s8,
                        runSpacing: UtenSpacing.s4,
                        children: [
                          UtenButton(
                            type: UtenButtonType.tonal,
                            size: UtenButtonSize.small,
                            icon: Icons.print_outlined,
                            isLoading: _printing,
                            onPressed:
                                (table == null ||
                                    table.rows.isEmpty ||
                                    _printing)
                                ? null
                                : _print,
                            child: const Text('打印'),
                          ),
                          if (widget.exportEndpoint != null)
                            UtenExportButton(
                              endpoint: widget.exportEndpoint!,
                              report: widget.exportReport ?? '',
                              queryParams: widget.exportQuery ?? const {},
                              bodyParams: {
                                ...?widget.exportBody,
                                if (widget.projection != null)
                                  'columnProjection': widget.projection!
                                      .toJson(),
                              },
                              filename: widget.exportFilename ?? widget.title,
                              requiredPermission: widget.exportPermission,
                              enabled: !_invalidated,
                              prepareExport: () async {
                                final version = _contextVersion;
                                return UtenExportSelection(
                                  stillCurrent: () => _isCurrent(version),
                                );
                              },
                              label: '下载Excel',
                            ),
                          UtenButton(
                            type: UtenButtonType.tonal,
                            icon: Icons.close_rounded,
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
              ],
            ),
          ),
        ],
        body: Container(
          color: theme.colorScheme.surfaceContainerHighest,
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Text(_error!),
                )
              : table == null
              ? const SizedBox(
                  height: 160,
                  child: Center(child: CircularProgressIndicator()),
                )
              : Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    primary: false,
                    child: SizedBox(
                      width: 1000,
                      child: _paperSelection(_a4Pages(theme, table)),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  // 纸面保留 1000 宽及原分页；横向查看属于纸面预览的二维内容。
  Widget _a4Pages(ThemeData theme, UtenPrintTable t) {
    const paperWidth = 1000.0;
    final pageCount =
        ((t.rows.length + _previewRowsPerPage - 1) ~/ _previewRowsPerPage)
            .clamp(1, 1 << 30);
    return ListView.builder(
      key: const ValueKey('uten-print-paper-list'),
      primary: true,
      padding: EdgeInsets.zero,
      itemCount: pageCount,
      itemBuilder: (context, page) {
        final start = page * _previewRowsPerPage;
        final end = (start + _previewRowsPerPage).clamp(0, t.rows.length);
        return Padding(
          padding: EdgeInsets.only(top: page == 0 ? 0 : UtenSpacing.s16),
          child: UtenSelectionLifecycleScope(
            child: RepaintBoundary(
              key: ValueKey('uten-print-paper-$page'),
              child: _a4Page(
                theme,
                t,
                t.rows.sublist(start, end),
                page,
                pageCount,
                paperWidth,
              ),
            ),
          ),
        );
      },
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
