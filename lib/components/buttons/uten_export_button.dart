import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import '../inputs/uten_input_decoration.dart';
import '../layout/uten_app_bar_action_scope.dart';
import '../layout/uten_collapsible_content.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';

import '../../core/io/file_saver.dart';
import '../../shared/export/master_export_job.dart';
import '../../shared/search/report_contact_query.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/ui/app_notification.dart';
import '../../shared/auth/permissions.dart';
import '../../shared/export/report_export_job_dialog.dart';
import '../../shared/export/report_export_jobs.dart';
import '../../shared/export/supplemental_export_job.dart';
import '../../shared/platform_tables/table_column_projection.dart';
import '../../shared/providers/export_context_epoch_provider.dart';
import '../../shared/providers/shared_providers.dart';
import 'uten_button.dart';
import '../feedback/uten_dialog.dart';
import '../feedback/uten_dialog_modules.dart';
import '../feedback/uten_task_progress_dialog.dart';
import '../data_display/uten_table_output_scope.dart';
import '../inputs/uten_field_hint_icon.dart';
import '../feedback/uten_busy_overlay.dart';

/// A business export may select a template or a group of files before the
/// shared password dialog. Cancellation never starts an export request.
class UtenExportSelection {
  const UtenExportSelection({
    this.bodyParams = const {},
    this.filename,
    this.extension = 'xlsx',
    this.stillCurrent,
    this.bodyForSelection,
  });

  final Map<String, dynamic> bodyParams;
  final String? filename;
  final String extension;

  /// Optional business context fence across preparation, password entry and file delivery.
  final bool Function()? stillCurrent;
  final Map<String, dynamic> Function(List<Map<String, String?>> selectedRows)?
  bodyForSelection;
}

/// 统一 Excel 导出入口，可选择普通下载或密码加密下载。
///
/// [endpoint] 导出端点路径，如 '/purchase/reports/export'。
/// [report] 报表 key（与后端 GET 路径一致，如 'order/detail' / 'expediting'）。
/// [queryParams] 过滤 + 排序参数（不含 page/size；与列表 _load 的 query 一致）。
/// [filename] 下载文件名（不含扩展名；按钮自动追加 .xlsx）。
/// [bodyParams] 不能进 URL 的筛选值(如客户/供应商的手机、银行账号)，随导出密码一起放请求体。
class UtenExportButton extends ConsumerStatefulWidget {
  const UtenExportButton({
    super.key,
    required this.endpoint,
    required this.report,
    required this.queryParams,
    this.bodyParams = const {},
    this.filename,
    this.requiredPermission,
    this.enabled = true,
    this.label = '下载表格',
    this.type = UtenButtonType.tonal,
    this.size = UtenButtonSize.small,
    this.height,
    this.icon = Icons.download_rounded,
    this.prepareExport,
    this.tableKey,
    this.selectedIds,
    this.queryForSelection,
    this.showOutputScope = true,
    this.frozenProjection,
    this.legacyPrivateQuery = const {},
  });

  final String endpoint;
  final String report;
  final Map<String, dynamic> queryParams;
  final Map<String, dynamic> bodyParams;
  final String? filename;

  /// 导出所需权限；未持有时不渲染按钮。后端仍是最终授权边界。
  final String? requiredPermission;

  /// Whether the current result set is ready to be exported.
  final bool enabled;

  /// 按钮文字（公司年长用户多，文字比纯图标易懂；默认"下载表格"，调用方可覆盖如"下载货品表"）。
  final String label;

  /// 按钮样式/尺寸：默认 tonal/small（AppBar 紧凑款）；
  /// 表格工具条场景传 primary/large（实心深绿 + 白字白 icon 大按钮）。
  final UtenButtonType type;
  final UtenButtonSize size;

  /// 高度覆盖（透传给 UtenButton.height）：表格工具条统一高度
  /// UtenTableToolbar.controlHeight 的场景用（2026-09-25 平台统一口径）。
  final double? height;

  /// 按钮图标；表格工具条统一「无 icon」口径时传 null。
  final IconData? icon;

  final Future<UtenExportSelection?> Function()? prepareExport;
  final String? tableKey;
  final Set<String>? selectedIds;
  final Map<String, dynamic> Function(Set<String> ids)? queryForSelection;
  final bool showOutputScope;
  final TableColumnProjection? frozenProjection;

  /// Durable adapters keep their named parameters; old direct endpoints receive these in the private body.
  final Map<String, String> legacyPrivateQuery;

  @override
  ConsumerState<UtenExportButton> createState() => _UtenExportButtonState();
}

class _UtenExportButtonState extends ConsumerState<UtenExportButton> {
  int _operation = 0;
  final _progressInvalidation = ValueNotifier<int>(0);
  bool _loading = false;
  bool _preparing = false;
  bool get _authorized =>
      widget.requiredPermission == null ||
      ref.read(currentPermissionsProvider).contains(widget.requiredPermission);

  void _invalidate() {
    if (!mounted) return;
    setState(() {
      _operation++;
      _loading = false;
      _preparing = false;
    });
    _progressInvalidation.value++;
  }

  @override
  void dispose() {
    _operation++;
    _progressInvalidation.value++;
    _progressInvalidation.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant UtenExportButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    const equality = DeepCollectionEquality();
    if (oldWidget.endpoint != widget.endpoint ||
        oldWidget.report != widget.report ||
        oldWidget.filename != widget.filename ||
        oldWidget.tableKey != widget.tableKey ||
        !equality.equals(oldWidget.queryParams, widget.queryParams) ||
        !equality.equals(oldWidget.bodyParams, widget.bodyParams)) {
      _invalidate();
    }
  }

  Future<void> _onTap() async {
    if (!widget.enabled || !_authorized || _loading || _preparing) return;
    final operation = ++_operation;
    final progressOwner = Object();
    final actionContext = UtenAppBarActionScope.actionContextOf(context);
    final epoch = ref.read(exportContextEpochProvider);
    final api = ref.read(apiClientProvider);
    UtenExportSelection? selection;
    bool current() =>
        mounted &&
        operation == _operation &&
        epoch == ref.read(exportContextEpochProvider) &&
        identical(api, ref.read(apiClientProvider)) &&
        _authorized &&
        (selection?.stillCurrent?.call() ?? true);
    setState(() => _preparing = true);
    try {
      final scope = await api.captureRequestScope(isCurrent: current);
      if (!mounted || !actionContext.mounted || !current()) return;
      final table = TableColumnProjectionScope.resolve(
        actionContext,
        widget.tableKey,
      );
      final selected = Set<String>.unmodifiable(
        widget.selectedIds ?? table?.outputSelection.ids ?? const <String>{},
      );
      selection = widget.prepareExport == null
          ? const UtenExportSelection()
          : await widget.prepareExport!();
      if (selection == null ||
          !mounted ||
          !actionContext.mounted ||
          !current()) {
        return;
      }
      final choice = await showDialog<_ExportFileChoice>(
        context: actionContext,
        builder: (_) => _ExportFileDialog(
          format: selection!.extension,
          selectedCount: selected.length,
          showScope: widget.showOutputScope,
          defaultStem:
              selection.filename ??
              widget.filename ??
              'export_${widget.report}',
        ),
      );
      if (choice == null || !mounted || !actionContext.mounted || !current()) {
        return;
      }
      final UtenExportSelection preparedSelection = selection;
      await runUtenBlockingTask<void>(
        context: actionContext,
        title: AppLocalizations.of(context).exportPreparingFile,
        isCurrent: current,
        invalidation: _progressInvalidation,
        owner: progressOwner,
        task: () async {
          final selectedOnly = choice.scope == UtenTableOutputScope.selected;
          final selectedSnapshot =
              selectedOnly &&
                  widget.queryForSelection == null &&
                  masterExportJobReport(widget.endpoint) == null &&
                  table != null
              ? await runUtenBlockingTask<UtenTableOutputSelection>(
                  context: actionContext,
                  title: '正在读取选中记录',
                  isCurrent: current,
                  invalidation: _progressInvalidation,
                  owner: progressOwner,
                  task: table.outputSelection.snapshot,
                )
              : null;
          if (!mounted || !actionContext.mounted || !current()) return;
          final selectedRows = selectedSnapshot?.rows;
          if (selectedOnly &&
              widget.queryForSelection == null &&
              masterExportJobReport(widget.endpoint) == null &&
              (selectedRows == null ||
                  selectedRows.length != selected.length)) {
            context.appError('选中记录缺少完整输出身份，请刷新后重试');
            return;
          }
          await _doExport(
            choice,
            preparedSelection,
            current,
            api,
            scope,
            selectedOnly ? selected : null,
            selectedRows,
            progressOwner,
          );
        },
      );
    } on ApiException catch (error) {
      if (mounted && current()) context.appError(error.message);
    } on FormatException catch (error) {
      if (mounted && current()) context.appError(error.message);
    } catch (_) {
      if (mounted && current()) {
        context.appError(AppLocalizations.of(context).exportFailed);
      }
    } finally {
      if (mounted && operation == _operation) {
        setState(() {
          _preparing = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _doExport(
    _ExportFileChoice choice,
    UtenExportSelection selection,
    bool Function() current,
    ApiClient api,
    AuthenticatedRequestScope scope,
    Set<String>? selectedIds,
    List<Map<String, String?>>? selectedRows,
    Object progressOwner,
  ) async {
    if (!mounted || !widget.enabled || !current()) return;
    setState(() => _loading = true);
    final actionContext = UtenAppBarActionScope.actionContextOf(context);
    final projection =
        widget.frozenProjection ??
        TableColumnProjectionScope.resolve(actionContext, widget.tableKey);
    final host = TableColumnProjectionScope.read(actionContext);
    if (host != null &&
        projection == null &&
        (widget.tableKey != null ||
            TableColumnProjectionScope.hasCurrentTables(actionContext))) {
      context.appError('无法确定要导出的表头，请返回对应表格后重试');
      return;
    }
    // 纯展示列（树形身份格等）不进导出投影：后端导出列集没有对应列，送过去
    // 会被「列不存在或不在可导出范围」整单拒绝（2026-10-20「导出组件」事故）。
    // 没有可导出列时停止，不能退回服务端完整列集而导出用户未选择的列。
    final exportProjection = projection == null
        ? null
        : TableColumnProjection(
            tableKey: projection.tableKey,
            scope: projection.scope,
            sourceKeys: projection.sourceKeys,
            rowSelection: selectedRows ?? projection.rowSelection,
            columns: projection.columns
                .where((column) => column.exportable)
                .toList(growable: false),
          );
    if (exportProjection != null && exportProjection.columns.isEmpty) {
      context.appError('当前表格没有可导出的列');
      return;
    }
    final domain = reportExportJobDomain(widget.endpoint);
    final taskReport =
        masterExportJobReport(widget.endpoint) ??
        (domain == 'audit' || domain == 'goods_actual_cost'
            ? supplementalExportJobReport(domain!, exportProjection?.tableKey)
            : widget.report);
    final query = {
      ...widget.queryParams,
      if (selectedIds != null && widget.queryForSelection != null)
        ...widget.queryForSelection!(selectedIds),
    };
    final documentBody = {
      ...widget.bodyParams,
      ...selection.bodyParams,
      if (selectedRows != null && selection.bodyForSelection != null)
        ...selection.bodyForSelection!(selectedRows),
      if (selectedIds != null && domain == 'master')
        'selectedIds': selectedIds.toList(growable: false),
    };
    if (domain == 'finance' &&
        ReportContactQuery.hasContactUrlValues(widget.queryParams)) {
      throw const FormatException('敏感列检索必须通过私有请求体提供');
    }
    final supportsTask = domain == 'goods_actual_cost'
        ? {'xlsx', 'pdf'}.contains(selection.extension)
        : domain == 'master'
        ? selection.extension == 'xlsx' &&
              documentBody.keys.every(
                (key) =>
                    key == 'format' ||
                    key == 'sensitiveFilter' ||
                    key == 'selectedIds',
              )
        : domain == 'where_used'
        ? {'xlsx', 'pdf'}.contains(selection.extension) &&
              documentBody.keys.every((key) => key == 'format')
        : domain == 'finance'
        ? selection.extension == 'xlsx' &&
              documentBody.keys.every(
                (key) => key == 'format' || key == 'sensitiveFilter',
              )
        : selection.extension == 'xlsx' && documentBody.isEmpty;
    final selectedOutput =
        selectedIds != null ||
        exportProjection?.rowSelection != null ||
        documentBody['selectedIds'] != null ||
        widget.legacyPrivateQuery.keys.any(query.containsKey);
    final jobs = ReportExportJobsClient(api, scope);
    var available = false;
    if (selectedOutput || (domain != null && supportsTask)) {
      available = await runUtenBlockingTask(
        context: actionContext,
        title: AppLocalizations.of(context).exportPreparingFile,
        isCurrent: current,
        invalidation: _progressInvalidation,
        owner: progressOwner,
        task: jobs.available,
      );
      if (!mounted || !current() || !actionContext.mounted) return;
      if (selectedOutput && !jobs.supportsSelectedOutput) {
        throw ApiException(
          'OUTPUT_SELECTION_UNSUPPORTED',
          '当前服务端尚未支持选中范围输出，请更新服务端后重试；本次未生成文件',
        );
      }
    }
    if (domain != null && supportsTask) {
      if (available) {
        final request = ReportExportJobRequest.create(
          domain: domain,
          report: taskReport,
          format: selection.extension,
          parameters: domain == 'audit' || domain == 'goods_actual_cost'
              ? supplementalExportJobParameters(domain, query, documentBody)
              : domain == 'master'
              ? masterExportJobParameters(taskReport, query, documentBody)
              : domain == 'finance'
              ? reportContactExportJobParameters(query, documentBody)
              : query,
          columnProjection:
              domain != 'where_used' &&
                  exportProjection != null &&
                  exportProjection.columns.isNotEmpty
              ? exportProjection.toJson()
              : null,
        );
        // The task dialog owns progress now; keep the underlying action gated
        // by _preparing without spinning an obscured button indefinitely.
        setState(() => _loading = false);
        await UtenBusyOverlay.yieldWhile(
          () => showDialog<void>(
            context: actionContext,
            barrierDismissible: false,
            builder: (_) => ReportExportJobDialog(
              client: jobs,
              request: request,
              store: ReportExportPendingStore(
                ref.read(sharedPreferencesProvider),
                scope.identity,
                domain,
                taskReport,
                format: selection.extension,
              ),
              stillCurrent: current,
              onDownload: (job) async {
                final filename = _exportFilename(selection, choice);
                final saved = await jobs.downloadToFile(
                  job.id,
                  choice.password,
                  filename,
                  directory: choice.directory,
                  stillCurrent: current,
                );
                if (!mounted || !current()) return;
                if (saved != null) {
                  _announceSaved(saved, filename);
                  return;
                }
                if (job.bytes > 32 * 1024 * 1024) {
                  throw ApiException(
                    'STREAMING_UNAVAILABLE',
                    '当前浏览器不支持大文件保存，请使用桌面版下载原任务',
                  );
                }
                final bytes = await jobs.download(job.id, choice.password);
                if (!mounted || !current()) return;
                await _saveExport(bytes, selection, current, choice);
              },
            ),
          ),
        );
        return;
      }
    }
    final legacyQuery = Map<String, dynamic>.of(query);
    final legacyBody = Map<String, dynamic>.of(documentBody);
    for (final entry in widget.legacyPrivateQuery.entries) {
      if (legacyQuery.containsKey(entry.key)) {
        legacyBody[entry.value] = legacyQuery.remove(entry.key);
      }
    }
    await runUtenBlockingTask(
      context: actionContext,
      title: AppLocalizations.of(context).exportPreparingFile,
      isCurrent: current,
      invalidation: _progressInvalidation,
      owner: progressOwner,
      task: () async {
        final Uint8List bytes = await scope.run(
          () => api.downloadBytes(
            widget.endpoint,
            body: {
              ...legacyBody,
              if (exportProjection != null)
                'columnProjection': exportProjection.toJson(),
              'password': choice.password,
            },
            query: {'report': widget.report, ...legacyQuery},
          ),
        );
        await scope.verify();
        if (!mounted || !current()) return;
        await _saveExport(bytes, selection, current, choice);
      },
    );
  }

  Future<void> _saveExport(
    Uint8List bytes,
    UtenExportSelection selection,
    bool Function() current,
    _ExportFileChoice choice,
  ) async {
    final name = _exportFilename(selection, choice);
    final saved = await saveBytes(
      bytes,
      name,
      directory: choice.directory,
      stillCurrent: current,
    );
    if (!mounted || !current()) return;
    _announceSaved(saved, name);
  }

  String _exportFilename(
    UtenExportSelection selection,
    _ExportFileChoice choice,
  ) {
    final extension = switch (selection.extension) {
      'zip' => 'zip',
      'pdf' => 'pdf',
      _ => 'xlsx',
    };
    return '${choice.filename}.$extension';
  }

  void _announceSaved(String saved, String name) {
    final l10n = AppLocalizations.of(context);
    context.appSuccess(
      kIsWeb
          ? l10n.exportDownloadStarted(name)
          : l10n.exportDownloadSaved(saved),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(exportContextEpochProvider, (previous, next) {
      if (previous != next) _invalidate();
    });
    final requiredPermission = widget.requiredPermission;
    if (requiredPermission != null &&
        !ref.watch(currentPermissionsProvider).contains(requiredPermission)) {
      return const SizedBox.shrink();
    }
    // 文字按钮（年长用户多，文字"下载表格"比纯图标易懂）；loading 时 UtenButton 自带转圈并禁用。
    return UtenButton(
      type: widget.type,
      size: widget.size,
      height:
          widget.height ??
          (widget.size == UtenButtonSize.large
              ? UtenTableToolbar.controlHeight
              : null),
      icon: widget.icon,
      compactIcon: Icons.download_rounded,
      isLoading: _loading,
      onPressed: widget.enabled && !_preparing ? _onTap : null,
      child: Text(widget.label),
    );
  }
}

/// 导出弹窗确认结果（2026-10-28 全站统一）：文件名必填（不含扩展名的主干），
/// 桌面版可另选保存目录（null = 默认桌面），密码沿旧口径（空 = 普通下载）。
class _ExportFileChoice {
  const _ExportFileChoice({
    required this.filename,
    required this.password,
    this.directory,
    this.scope = UtenTableOutputScope.all,
  });
  final String filename;
  final String password;
  final String? directory;
  final UtenTableOutputScope scope;
}

bool get _supportsDirectoryPicker =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

/// 导出前置设置（全站统一）：文件名（必填）+ 保存位置（桌面版，默认桌面）+
/// 可选密码，一个弹窗收齐，不再先密码后文件两个弹窗。取消返回 null。
class _ExportFileDialog extends StatefulWidget {
  const _ExportFileDialog({
    required this.format,
    required this.defaultStem,
    this.selectedCount = 0,
    this.showScope = true,
  });

  final String format;
  final String defaultStem;
  final int selectedCount;
  final bool showScope;

  @override
  State<_ExportFileDialog> createState() => _ExportFileDialogState();
}

class _ExportFileDialogState extends State<_ExportFileDialog> {
  UtenTableOutputScope _scope = UtenTableOutputScope.all;

  late final TextEditingController _name = TextEditingController(
    text: widget.defaultStem,
  );
  final _pwd = TextEditingController();
  final _confirm = TextEditingController();
  final _dir = TextEditingController();
  String? _error;
  bool _passwordExpanded = false;
  bool _choosingDirectory = false;

  @override
  void initState() {
    super.initState();
    if (_supportsDirectoryPicker) {
      defaultExportDirectory().then((path) {
        if (mounted && path != null && _dir.text.isEmpty) {
          setState(() => _dir.text = path);
        }
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _pwd.dispose();
    _confirm.dispose();
    _dir.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory() async {
    if (_choosingDirectory) return;
    setState(() => _choosingDirectory = true);
    final initial = _dir.text.trim().isNotEmpty ? _dir.text.trim() : null;
    try {
      final picked = await UtenBusyOverlay.run(
        context,
        title: '正在选择保存位置',
        action: () => UtenBusyOverlay.yieldWhile(
          () => FilePicker.platform.getDirectoryPath(initialDirectory: initial),
        ),
      );
      if (picked != null && mounted) {
        setState(() {
          _dir.text = picked;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '未能打开保存位置，请重试');
    } finally {
      if (mounted) setState(() => _choosingDirectory = false);
    }
  }

  String? _validate() {
    final l10n = AppLocalizations.of(context);
    var stem = _name.text.trim();
    final suffix = '.${widget.format}';
    if (stem.toLowerCase().endsWith(suffix)) {
      stem = stem.substring(0, stem.length - suffix.length);
    }
    if (stem.isEmpty) return l10n.exportFileNameRequired;
    if (stem.length > 150) return l10n.exportFileNameRequired;
    return null;
  }

  void _submit() {
    if (_choosingDirectory) return;
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final p = _pwd.text;
    if (p.length > 128) {
      setState(
        () => _error = AppLocalizations.of(context).exportPasswordTooLong,
      );
      return;
    }
    if (p.isNotEmpty && p != _confirm.text) {
      setState(
        () => _error = AppLocalizations.of(context).exportPasswordMismatch,
      );
      return;
    }
    var stem = _name.text.trim();
    final suffix = '.${widget.format}';
    if (stem.toLowerCase().endsWith(suffix)) {
      stem = stem.substring(0, stem.length - suffix.length);
    }
    Navigator.of(context).pop(
      _ExportFileChoice(
        filename: stem,
        password: p,
        scope: _scope,
        directory: _supportsDirectoryPicker && _dir.text.trim().isNotEmpty
            ? _dir.text.trim()
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final hasPassword = _pwd.text.isNotEmpty;
    final media = MediaQuery.of(context);
    final freeHeight =
        media.size.height -
        media.viewInsets.bottom -
        media.padding.vertical -
        48;
    final scale = media.textScaler.scale(14) / 14;
    final expandedHeight =
        (_passwordExpanded ? (hasPassword ? 900 : 820) : 640) * scale +
        (_error == null ? 0 : 48);
    final adaptiveWidth = media.size.width < 1100
        ? 520.0
        : (media.size.width * 0.44).clamp(520.0, 680.0);

    return UtenAlertDialog(
      maxWidth: adaptiveWidth,
      scrollable: freeHeight < expandedHeight,
      showCloseButton: true,
      title: UtenDialogHeading(
        icon: Icons.file_download_outlined,
        title: UtenDialogTitleWithHint(
          info: l10n.exportDialogSubtitle(widget.format.toUpperCase()),
          title: Text(
            widget.format == 'pdf'
                ? l10n.exportPdfDialogTitle
                : l10n.exportDialogTitle,
          ),
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showScope) ...[
            UtenDialogField(
              label: const Row(
                children: [
                  Text('导出范围'),
                  UtenFieldHintIcon(
                    info: '全部结果包含当前分类、搜索和表头筛选下的全部分页；仅已选保留当前勾选的记录。',
                    dense: true,
                  ),
                ],
              ),
              child: UtenTableOutputScopeField(
                value: _scope,
                selectedCount: widget.selectedCount,
                onChanged: (value) => setState(() => _scope = value),
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
          ],
          UtenDialogField(
            label: Text(l10n.exportFileNameLabel),
            child: Semantics(
              label: l10n.exportFileNameLabel,
              child: TextField(
                key: const Key('uten-export-filename'),
                controller: _name,
                autofocus: true,
                maxLength: 150,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    prefixIcon: const Icon(Icons.description_outlined),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: UtenRadius.mdAll,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UtenSpacing.s12,
                            vertical: UtenSpacing.s4,
                          ),
                          child: Text(
                            '.${widget.format}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                    counterText: '',
                    isDense: true,
                  ),
                ),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
          if (_supportsDirectoryPicker) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dir,
                    readOnly: true,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: l10n.exportSaveLocationLabel,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                UtenButton(
                  type: UtenButtonType.secondary,
                  isLoading: _choosingDirectory,
                  onPressed: _choosingDirectory ? null : _pickDirectory,
                  child: Text(l10n.exportBrowse),
                ),
              ],
            ),
          ],
          const SizedBox(height: UtenSpacing.s16),
          UtenDialogSettingTile(
            icon: _passwordExpanded
                ? Icons.lock_open_rounded
                : Icons.shield_outlined,
            onTap: () => setState(() {
              _passwordExpanded = !_passwordExpanded;
              if (!_passwordExpanded) {
                _pwd.clear();
                _confirm.clear();
              }
              _error = null;
            }),
            title: UtenDialogTitleWithHint(
              info: l10n.exportPasswordProtectionDescription,
              title: Text(
                _passwordExpanded
                    ? l10n.exportRemovePassword
                    : l10n.exportSetPassword,
              ),
            ),
            trailing: Icon(
              _passwordExpanded
                  ? Icons.expand_less_rounded
                  : Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          UtenCollapsibleContent(
            expanded: _passwordExpanded,
            maintainState: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: UtenSpacing.s16),
                TextField(
                  controller: _pwd,
                  obscureText: true,
                  maxLength: 128,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: l10n.exportPasswordOptionalLabel,
                      counterText: '',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  onChanged: (_) => setState(() => _error = null),
                  onSubmitted: (_) => _submit(),
                ),
                if (hasPassword) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    maxLength: 128,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: l10n.exportPasswordConfirmLabel,
                        counterText: '',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w400,
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        UtenButton(
          size: UtenButtonSize.large,
          icon: Icons.download_rounded,
          onPressed: _submit,
          child: Text(
            hasPassword
                ? l10n.exportDownloadEncrypted
                : l10n.exportDownloadPlain,
          ),
        ),
      ],
    );
  }
}
