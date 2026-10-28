import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/admin_models.dart';
import '../models/permission_configuration.dart';
import '../models/permission_template.dart';
import '../providers/admin_providers.dart';
import '../repositories/permission_configuration_repository.dart';
import '../repositories/permission_template_repository.dart';
import '../services/permission_archive_files.dart';
import '../services/permission_workspace_archive.dart';
import 'permission_configuration_import_dialog.dart';
import 'permission_transfer_preview.dart';

bool _canTransfer(WidgetRef ref) =>
    ref.read(isSuperAdminProvider) &&
    ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);

void refreshPermissionConfiguration(WidgetRef ref) {
  ref.read(permissionConfigurationRevisionProvider.notifier).state++;
  ref.invalidate(permissionCatalogProvider);
  ref.invalidate(adminPermissionBaselineProvider);
  ref.invalidate(adminDepartmentPermissionsProvider);
  ref.invalidate(adminEffectivePermissionsProvider);
  ref.invalidate(permissionTemplatesProvider);
  ref.invalidate(permissionTemplateBindingsProvider);
}

String permissionTransferError(Object error) => switch (error) {
  final ApiException e when isSessionBoundaryError(e) =>
    '登录状态已变化或暂时无法核对，请关闭窗口后重新打开。',
  final ApiException e => e.message,
  final FormatException e => e.message,
  _ => '权限设置处理失败，请重试',
};

class AdminPermissionArchiveActions extends ConsumerStatefulWidget {
  const AdminPermissionArchiveActions({super.key, this.importEnabled = true});
  final bool importEnabled;

  @override
  ConsumerState<AdminPermissionArchiveActions> createState() =>
      _ArchiveActionsState();
}

class _ArchiveActionsState
    extends ConsumerState<AdminPermissionArchiveActions> {
  bool _exporting = false;
  bool _importing = false;
  bool get _busy => _exporting || _importing;

  Future<void> _export() async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _canTransfer(ref);
    if (_busy || !current()) return;
    setState(() => _exporting = true);
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      final results = await Future.wait<Object>([
        scope.run(ref.read(permissionConfigurationRepositoryProvider).export),
        scope.run(ref.read(permissionTemplateRepositoryProvider).list),
      ]);
      if (!current()) return;
      final bytes = await buildPermissionWorkspaceArchive(
        configuration: results[0] as PermissionConfiguration,
        templates: results[1] as List<PermissionTemplate>,
        stillCurrent: current,
      );
      if (!current()) return;
      final path = await saveBytes(
        bytes,
        permissionWorkspaceArchiveFilename,
        stillCurrent: current,
      );
      if (mounted && current()) context.appSuccess('已保存的权限设置已导出：$path');
    } catch (error) {
      if (mounted && current()) {
        context.appError(permissionTransferError(error));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _canTransfer(ref) &&
        widget.importEnabled;
    if (_busy || !current()) return;
    setState(() => _importing = true);
    try {
      final bytes = await pickPermissionArchiveBytes(stillCurrent: current);
      if (bytes == null || !current()) return;
      final configuration = PermissionConfiguration.decode(bytes);
      if (!mounted || !current()) return;
      final applied = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PermissionConfigurationImportDialog(
          configuration: configuration,
          boundary: boundary,
        ),
      );
      if (mounted && current() && applied == true) {
        refreshPermissionConfiguration(ref);
        context.appSuccess('权限设置已导入');
      }
    } catch (error) {
      if (mounted && current()) {
        context.appError(permissionTransferError(error));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(isSuperAdminProvider) ||
        !ref
            .watch(currentPermissionsProvider)
            .contains(Perm.authorizationManage)) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: UtenSpacing.s4,
      runSpacing: UtenSpacing.s4,
      children: [
        Tooltip(
          message: '下载完整 ZIP，包含权限设置和全部模板。解压后可通过各自入口导入 JSON。',
          child: UtenButton(
            key: const ValueKey('export-permission-configuration'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.small,
            icon: Icons.download_outlined,
            isLoading: _exporting,
            onPressed: _busy ? null : _export,
            child: const Text('导出全部权限'),
          ),
        ),
        UtenButton(
          key: const ValueKey('import-permission-configuration'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.upload_outlined,
          isLoading: _importing,
          onPressed: _busy || !widget.importEnabled ? null : _import,
          onDisabledTap: !widget.importEnabled
              ? () => context.appWarning('请先保存当前权限修改，再导入权限设置')
              : null,
          child: const Text('导入权限设置'),
        ),
      ],
    );
  }
}

class AdminPermissionCopyActions extends ConsumerStatefulWidget {
  const AdminPermissionCopyActions({
    super.key,
    required this.user,
    required this.enabled,
    required this.onApplied,
  });
  final AdminUserSummary user;
  final bool enabled;
  final VoidCallback onApplied;

  @override
  ConsumerState<AdminPermissionCopyActions> createState() =>
      _CopyActionsState();
}

class _CopyActionsState extends ConsumerState<AdminPermissionCopyActions> {
  bool _busy = false;
  bool _copying = false;
  int _operation = 0;

  @override
  void didUpdateWidget(covariant AdminPermissionCopyActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.id != widget.user.id) {
      _operation++;
      _busy = false;
      _copying = false;
    }
  }

  Future<void> _copy() async {
    if (_busy || !widget.enabled) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final userId = widget.user.id;
    final operation = ++_operation;
    bool current() =>
        mounted &&
        operation == _operation &&
        userId == widget.user.id &&
        widget.enabled &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _canTransfer(ref);
    if (!current()) return;
    setState(() {
      _busy = true;
      _copying = true;
    });
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      final source = await scope.run(
        () => ref.read(permissionConfigurationRepositoryProvider).copy(userId),
      );
      if (!mounted || !current()) return;
      ref.read(permissionCopyClipboardProvider.notifier).state = source;
      context.appSuccess(
        '已复制${source.sourceLabel}的 ${source.permissions.length} 项操作权限，请选择另一位员工后粘贴',
      );
    } catch (error) {
      if (mounted && current()) {
        context.appError(permissionTransferError(error));
      }
    } finally {
      if (mounted && operation == _operation) {
        setState(() {
          _busy = false;
          _copying = false;
        });
      }
    }
  }

  Future<void> _paste() async {
    final source = ref.read(permissionCopyClipboardProvider);
    if (source == null || _busy || !widget.enabled) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final userId = widget.user.id;
    final operation = ++_operation;
    bool current() =>
        mounted &&
        operation == _operation &&
        userId == widget.user.id &&
        widget.enabled &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _canTransfer(ref);
    setState(() => _busy = true);
    try {
      final applied = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CopyPreviewDialog(
          source: source,
          target: widget.user,
          boundary: boundary,
        ),
      );
      if (mounted && current() && applied == true) {
        widget.onApplied();
        context.appSuccess(
          '已为${widget.user.employeeName ?? widget.user.loginAccount}设置相同的操作权限',
        );
      }
    } finally {
      if (mounted && operation == _operation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copied = ref.watch(permissionCopyClipboardProvider);
    return Wrap(
      spacing: UtenSpacing.s4,
      runSpacing: UtenSpacing.s4,
      children: [
        UtenButton(
          key: const ValueKey('copy-user-permissions'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.copy_outlined,
          isLoading: _copying,
          onPressed: widget.enabled && !_busy ? _copy : null,
          child: const Text('复制权限'),
        ),
        Tooltip(
          message: copied == null ? '先复制另一位员工的权限' : '已复制：${copied.sourceLabel}',
          child: UtenButton(
            key: const ValueKey('paste-user-permissions'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.small,
            icon: Icons.content_paste_outlined,
            onPressed:
                widget.enabled &&
                    !_busy &&
                    copied != null &&
                    copied.sourceUserId != widget.user.id
                ? _paste
                : null,
            child: const Text('粘贴权限'),
          ),
        ),
      ],
    );
  }
}

class _CopyPreviewDialog extends ConsumerStatefulWidget {
  const _CopyPreviewDialog({
    required this.source,
    required this.target,
    required this.boundary,
  });
  final PermissionCopySnapshot source;
  final AdminUserSummary target;
  final SensitiveReadBoundary boundary;

  @override
  ConsumerState<_CopyPreviewDialog> createState() => _CopyPreviewState();
}

class _CopyPreviewState extends ConsumerState<_CopyPreviewDialog> {
  PermissionTransferPreview? _preview;
  final Set<String> _confirmed = {};
  bool _loading = true;
  bool _applying = false;
  bool _uncertain = false;
  bool _boundaryFailed = false;
  String? _error;
  late final Future<AuthenticatedRequestScope> _scope;
  bool get _current =>
      mounted &&
      widget.boundary == ref.read(sensitiveReadBoundaryProvider) &&
      _canTransfer(ref);

  @override
  void initState() {
    super.initState();
    _scope = ref
        .read(apiClientProvider)
        .captureRequestScope(isCurrent: () => _current);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _preview = null;
      _confirmed.clear();
      _error = null;
    });
    try {
      final scope = await _scope;
      final preview = await scope.run(
        () => ref
            .read(permissionConfigurationRepositoryProvider)
            .previewCopy(widget.target.id, widget.source),
      );
      if (_current) setState(() => _preview = preview);
    } catch (error) {
      if (mounted) {
        setState(() {
          _boundaryFailed = isSessionBoundaryError(error);
          _error = permissionTransferError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply() async {
    final preview = _preview;
    if (!_current ||
        _applying ||
        _uncertain ||
        _boundaryFailed ||
        preview == null ||
        !preview.canApply ||
        !preview.confirmedBy(_confirmed)) {
      return;
    }
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final scope = await _scope;
      await scope.run(
        () => ref
            .read(permissionConfigurationRepositoryProvider)
            .applyCopy(widget.target.id, widget.source, preview, _confirmed),
      );
      if (mounted && _current) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _boundaryFailed = isSessionBoundaryError(error);
          _uncertain =
              error is! ApiException ||
              error.httpStatus == null ||
              error.httpStatus! >= 500;
          _error = _uncertain
              ? '请求结果尚未确认，请关闭窗口刷新并核对权限，暂勿重复粘贴。'
              : permissionTransferError(error);
          _preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sensitiveReadBoundaryProvider);
    return PopScope(
      canPop: !_applying,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _uncertain && _current) {
          refreshPermissionConfiguration(ref);
        }
      },
      child: UtenAlertDialog(
        maxWidth: 760,
        title: const Text('确认粘贴权限'),
        content: SizedBox(
          width: 700,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.source.sourceLabel} → ${widget.target.employeeName ?? widget.target.loginAccount}',
              ),
              const SizedBox(height: UtenSpacing.s8),
              const Text('将目标员工的操作权限设置为与来源员工一致。可查看数据范围仍按目标员工原设置。'),
              const SizedBox(height: UtenSpacing.s12),
              if (!_current)
                const Text('登录身份或服务器已变化，请关闭后重新操作。')
              else if (_loading)
                const LinearProgressIndicator()
              else ...[
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_preview != null)
                  PermissionTransferPreviewDetails(
                    preview: _preview!,
                    confirmations: _confirmed,
                    enabled: !_applying,
                    onConfirmationChanged: (key, checked) => setState(() {
                      checked ? _confirmed.add(key) : _confirmed.remove(key);
                    }),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _applying
                ? null
                : () {
                    Navigator.of(context).pop(false);
                  },
            child: const Text('取消'),
          ),
          if (_error != null && !_uncertain && !_boundaryFailed && _current)
            TextButton(
              onPressed: _applying || _loading ? null : _load,
              child: const Text('重新预览'),
            ),
          UtenButton(
            key: const ValueKey('confirm-paste-permissions'),
            isLoading: _applying,
            onPressed:
                !_current ||
                    _loading ||
                    _uncertain ||
                    _preview?.canApply != true ||
                    !_preview!.confirmedBy(_confirmed)
                ? null
                : _apply,
            child: const Text('确认粘贴'),
          ),
        ],
      ),
    );
  }
}
