// UtenExportButton - 加密 Excel 导出按钮（页面 AppBar 用）。
//
// 点击弹密码对话框 → POST /export（密码 body，过滤/排序 query）→ 跨端保存加密 .xlsx。
// 防连点 + loading + context.mounted 守卫 + ApiException/兜底错误提示。
// 设计：紧凑 IconButton（下载图标），loading 时显小转圈并禁用。
// 文档：docs/02-组件库/UtenExportButton.md
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/io/file_saver.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/app_notification.dart';
import '../../shared/auth/permissions.dart';
import 'uten_button.dart';

/// 加密 Excel 导出按钮（紧凑 IconButton，放页面 AppBar.actions）。
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
    if (_loading) return; // 防连点
    final pwd = await showDialog<String>(
      context: context,
      builder: (_) => const _ExportPasswordDialog(),
    );
    // null=取消；非空=加密导出。安全策略禁止从报表端点导出明文工作簿。
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
      context.appSuccess(kIsWeb ? '已开始下载 $name' : '已保存：$saved');
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('导出失败，请稍后重试'); // TODO(l10n): 补 arb
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
      onPressed: _onTap,
      child: Text(widget.label),
    );
  }
}

/// 导出对话框：必须设置 6-128 位打开密码并二次确认。
/// 确认返回密码，取消返回 null。
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
    if (p.length < 6 || p.length > 128) {
      setState(() => _error = '密码长度必须为 6-128 位'); // TODO(l10n): 补 arb
      return;
    }
    if (p != _confirm.text) {
      setState(() => _error = '两次密码不一致'); // TODO(l10n): 补 arb
      return;
    }
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导出 Excel'), // TODO(l10n): 补 arb
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '为保护导出数据，必须设置打开密码；Excel/WPS 打开文件时需要输入。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwd,
            obscureText: true,
            autofocus: true,
            maxLength: 128,
            decoration: const InputDecoration(
              labelText: '密码（6-128 位）', // TODO(l10n): 补 arb
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirm,
            obscureText: true,
            maxLength: 128,
            decoration: const InputDecoration(
              labelText: '确认密码', // TODO(l10n): 补 arb
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'), // TODO(l10n): 补 arb
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.lock_outline_rounded, size: 18),
          label: const Text('加密导出'), // TODO(l10n): 补 arb
        ),
      ],
    );
  }
}
