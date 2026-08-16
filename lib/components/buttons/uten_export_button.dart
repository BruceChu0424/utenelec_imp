import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/io/file_saver.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/app_notification.dart';
import '../../shared/auth/permissions.dart';
import 'uten_button.dart';

/// 统一 Excel 导出入口，可选择普通下载或密码加密下载。
///
/// [endpoint] 导出端点路径，如 '/purchase/reports/export'。
/// [report] 报表 key（与后端 GET 路径一致，如 'order/detail' / 'expediting'）。
/// [queryParams] 过滤 + 排序参数（不含 page/size；与列表 _load 的 query 一致）。
/// [filename] 下载文件名（不含扩展名；按钮自动追加 .xlsx）。
class UtenExportButton extends ConsumerStatefulWidget {
  const UtenExportButton({
    super.key,
    required this.endpoint,
    required this.report,
    required this.queryParams,
    this.filename,
    this.requiredPermission,
    this.enabled = true,
    this.label = '下载表格',
    this.type = UtenButtonType.tonal,
    this.size = UtenButtonSize.small,
  });

  final String endpoint;
  final String report;
  final Map<String, dynamic> queryParams;
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

  @override
  ConsumerState<UtenExportButton> createState() => _UtenExportButtonState();
}

class _UtenExportButtonState extends ConsumerState<UtenExportButton> {
  bool _loading = false;

  Future<void> _onTap() async {
    if (!widget.enabled || _loading) return; // 防连点 / 等待查询高水位边界
    final pwd = await showDialog<String>(
      context: context,
      builder: (_) => const _ExportPasswordDialog(),
    );
    // null 表示取消；空字符串表示不加密。
    if (pwd == null || !mounted) return;
    await _doExport(pwd);
  }

  Future<void> _doExport(String password) async {
    setState(() => _loading = true);
    try {
      final Uint8List bytes = await ref
          .read(apiClientProvider)
          .downloadBytes(
            widget.endpoint,
            body: {'password': password},
            query: {'report': widget.report, ...widget.queryParams},
          );
      final name = '${widget.filename ?? 'export_${widget.report}'}.xlsx';
      final saved = await saveBytes(bytes, name);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      context.appSuccess(
        kIsWeb
            ? l10n.exportDownloadStarted(name)
            : l10n.exportDownloadSaved(saved),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError(AppLocalizations.of(context).exportFailed);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final requiredPermission = widget.requiredPermission;
    if (requiredPermission != null &&
        !ref.watch(currentPermissionsProvider).contains(requiredPermission)) {
      return const SizedBox.shrink();
    }
    // 文字按钮（年长用户多，文字"下载表格"比纯图标易懂）；loading 时 UtenButton 自带转圈并禁用。
    return UtenButton(
      type: widget.type,
      size: widget.size,
      icon: Icons.download_rounded,
      isLoading: _loading,
      onPressed: widget.enabled ? _onTap : null,
      child: Text(widget.label),
    );
  }
}

/// 返回空字符串表示普通下载，返回非空密码表示加密下载，取消返回 null。
class _ExportPasswordDialog extends StatefulWidget {
  const _ExportPasswordDialog();

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
    return AlertDialog(
      title: Text(l10n.exportDialogTitle),
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
            decoration: InputDecoration(
              labelText: l10n.exportPasswordOptionalLabel,
              border: const OutlineInputBorder(),
              isDense: true,
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
              decoration: InputDecoration(
                labelText: l10n.exportPasswordConfirmLabel,
                border: const OutlineInputBorder(),
                isDense: true,
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
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(
            hasPassword ? Icons.lock_outline_rounded : Icons.download_rounded,
            size: 18,
          ),
          label: Text(
            hasPassword
                ? l10n.exportDownloadEncrypted
                : l10n.exportDownloadPlain,
          ),
        ),
      ],
    );
  }
}
