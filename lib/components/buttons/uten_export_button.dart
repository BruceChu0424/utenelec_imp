import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../inputs/uten_input_decoration.dart';
import '../layout/uten_app_bar_action_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';

import '../../core/io/file_saver.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/ui/app_notification.dart';
import '../../shared/auth/permissions.dart';
import '../../shared/platform_tables/table_column_projection.dart';
import '../../shared/providers/export_context_epoch_provider.dart';
import 'uten_button.dart';
import '../feedback/uten_dialog.dart';

/// A business export may select a template or a group of files before the
/// shared password dialog. Cancellation never starts an export request.
class UtenExportSelection {
  const UtenExportSelection({
    this.bodyParams = const {},
    this.filename,
    this.extension = 'xlsx',
    this.stillCurrent,
  });

  final Map<String, dynamic> bodyParams;
  final String? filename;
  final String extension;

  /// Optional business context fence across preparation, password entry and file delivery.
  final bool Function()? stillCurrent;
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

  @override
  ConsumerState<UtenExportButton> createState() => _UtenExportButtonState();
}

class _UtenExportButtonState extends ConsumerState<UtenExportButton> {
  int _operation = 0;
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
      selection = widget.prepareExport == null
          ? const UtenExportSelection()
          : await widget.prepareExport!();
      if (selection == null ||
          !mounted ||
          !actionContext.mounted ||
          !current()) {
        return;
      }
      final password = await showDialog<String>(
        context: actionContext,
        builder: (_) => _ExportPasswordDialog(format: selection!.extension),
      );
      if (password == null || !mounted || !current()) return;
      await _doExport(password, selection, current, api, scope);
    } on ApiException catch (error) {
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
    String password,
    UtenExportSelection selection,
    bool Function() current,
    ApiClient api,
    AuthenticatedRequestScope scope,
  ) async {
    if (!mounted || !widget.enabled || !current()) return;
    setState(() => _loading = true);
    final actionContext = UtenAppBarActionScope.actionContextOf(context);
    final projection = TableColumnProjectionScope.resolve(
      actionContext,
      widget.tableKey,
    );
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
    // 全部列都被剔除时干脆不送投影，让后端用它默认的完整列集。
    final exportProjection = projection == null
        ? null
        : TableColumnProjection(
            tableKey: projection.tableKey,
            scope: projection.scope,
            sourceKeys: projection.sourceKeys,
            columns: projection.columns
                .where((column) => column.exportable)
                .toList(growable: false),
          );
    final Uint8List bytes = await scope.run(
      () => api.downloadBytes(
        widget.endpoint,
        body: {
          ...widget.bodyParams,
          ...selection.bodyParams,
          if (exportProjection != null && exportProjection.columns.isNotEmpty)
            'columnProjection': exportProjection.toJson(),
          'password': password,
        },
        query: {'report': widget.report, ...widget.queryParams},
      ),
    );
    await scope.verify();
    if (!mounted || !current()) return;
    final extension = switch (selection.extension) {
      'zip' => 'zip',
      'pdf' => 'pdf',
      _ => 'xlsx',
    };
    final name =
        '${selection.filename ?? widget.filename ?? 'export_${widget.report}'}.$extension';
    final saved = await saveBytes(bytes, name, stillCurrent: current);
    if (!mounted || !current()) return;
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
      isLoading: _loading,
      onPressed: widget.enabled && !_preparing ? _onTap : null,
      child: Text(widget.label),
    );
  }
}

/// 返回空字符串表示普通下载，返回非空密码表示加密下载，取消返回 null。
class _ExportPasswordDialog extends StatefulWidget {
  const _ExportPasswordDialog({required this.format});

  final String format;

  @override
  State<_ExportPasswordDialog> createState() => _ExportPasswordDialogState();
}

class _ExportPasswordDialogState extends State<_ExportPasswordDialog> {
  final _pwd = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pwd.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
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
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final hasPassword = _pwd.text.isNotEmpty;
    return UtenAlertDialog(
      title: Text(
        widget.format == 'pdf'
            ? l10n.exportPdfDialogTitle
            : l10n.exportDialogTitle,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.exportPasswordOptionalHint,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwd,
            obscureText: true,
            autofocus: true,
            maxLength: 128,
            decoration: UtenInputDecoration(
              InputDecoration(
                labelText: l10n.exportPasswordOptionalLabel,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          if (hasPassword) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _confirm,
              obscureText: true,
              maxLength: 128,
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: l10n.exportPasswordConfirmLabel,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _submit(),
            ),
          ],
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
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
