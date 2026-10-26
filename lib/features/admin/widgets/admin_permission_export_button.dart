import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/permission_configuration.dart';
import '../models/permission_template.dart';
import '../models/permission_template_archive.dart';
import '../repositories/permission_configuration_repository.dart';
import '../services/permission_archive_files.dart';
import 'admin_permission_transfer_actions.dart' show permissionTransferError;

enum PermissionExportScope { employee, department, baseline, template }

/// Contextual export shares naming, identity fencing and server snapshot reads.
/// Callers disable it while edits are pending so downloaded permissions always
/// describe a saved state.
class AdminPermissionExportButton extends ConsumerStatefulWidget {
  const AdminPermissionExportButton({
    super.key,
    required this.scope,
    this.sourceId,
    this.sourceName,
    this.template,
    this.enabled = true,
    this.disabledReason,
  });

  final PermissionExportScope scope;
  final String? sourceId;
  final String? sourceName;
  final PermissionTemplate? template;
  final bool enabled;
  final String? disabledReason;

  @override
  ConsumerState<AdminPermissionExportButton> createState() =>
      _ExportButtonState();
}

class _ExportButtonState extends ConsumerState<AdminPermissionExportButton> {
  bool _busy = false;
  int _operation = 0;

  bool get _authorized =>
      ref.read(isSuperAdminProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);

  @override
  void didUpdateWidget(covariant AdminPermissionExportButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope ||
        oldWidget.sourceId != widget.sourceId ||
        oldWidget.sourceName != widget.sourceName ||
        oldWidget.template != widget.template ||
        oldWidget.enabled != widget.enabled) {
      _operation++;
      _busy = false;
    }
  }

  Future<void> _export() async {
    if (_busy || !widget.enabled || !_authorized) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final operation = ++_operation;
    final exportScope = widget.scope;
    final sourceId = widget.sourceId;
    final sourceName = widget.sourceName;
    final template = widget.template;
    bool current() =>
        mounted &&
        operation == _operation &&
        widget.enabled &&
        boundary == ref.read(sensitiveReadBoundaryProvider) &&
        _authorized;
    setState(() => _busy = true);
    try {
      final requestScope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      if (!current()) return;
      final String filename;
      final Uint8List encoded;
      if (exportScope == PermissionExportScope.template) {
        if (template == null) throw const FormatException('请先选择模板');
        filename = permissionArchiveFilename('模板', template.name);
        encoded = PermissionTemplateArchive.fromTemplate(template).encode();
      } else {
        final configuration = await requestScope.run(
          ref.read(permissionConfigurationRepositoryProvider).export,
        );
        if (!current()) return;
        final scope = switch (exportScope) {
          PermissionExportScope.employee =>
            PermissionConfigurationScope.employee,
          PermissionExportScope.department =>
            PermissionConfigurationScope.department,
          PermissionExportScope.baseline =>
            PermissionConfigurationScope.baseline,
          PermissionExportScope.template => throw StateError('模板范围应单独处理'),
        };
        final label = switch (exportScope) {
          PermissionExportScope.employee => '员工',
          PermissionExportScope.department => '部门',
          _ => '全员基础包',
        };
        filename = permissionArchiveFilename(label, sourceName);
        encoded = configuration.select(scope, sourceId: sourceId).encode();
      }
      if (!current()) return;
      final path = await saveBytes(encoded, filename, stillCurrent: current);
      if (mounted && current()) context.appSuccess('权限已导出：$path');
    } catch (error) {
      if (mounted && current()) {
        context.appError(permissionTransferError(error));
      }
    } finally {
      if (mounted && operation == _operation) {
        setState(() => _busy = false);
      }
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
    return UtenButton(
      key: ValueKey('export-permission-${widget.scope.name}'),
      type: UtenButtonType.secondary,
      size: UtenButtonSize.small,
      icon: Icons.download_outlined,
      isLoading: _busy,
      onPressed: widget.enabled && !_busy ? _export : null,
      onDisabledTap: !widget.enabled
          ? () => context.appWarning(widget.disabledReason ?? '请先保存当前修改，再导出权限')
          : null,
      child: Text(switch (widget.scope) {
        PermissionExportScope.template => '导出模板',
        PermissionExportScope.baseline => '导出基础包',
        _ => '导出权限',
      }),
    );
  }
}
