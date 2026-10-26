import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/permission_template.dart';
import '../repositories/permission_template_repository.dart';

/// Basic information only. Permissions are edited in the main workspace.
class PermissionTemplateMetadataDialog extends ConsumerStatefulWidget {
  const PermissionTemplateMetadataDialog({
    super.key,
    this.template,
    this.initialCodes = const [],
    this.initialName = '',
    this.initialDescription = '',
    this.importing = false,
  });
  final PermissionTemplate? template;
  final List<String> initialCodes;
  final String initialName;
  final String initialDescription;
  final bool importing;
  @override
  ConsumerState<PermissionTemplateMetadataDialog> createState() =>
      _MetadataState();
}

class _MetadataState extends ConsumerState<PermissionTemplateMetadataDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final SensitiveReadBoundary _boundary;
  bool _saving = false;
  bool _uncertain = false;
  String? _error;
  bool get _current =>
      mounted &&
      ref.read(isSuperAdminProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.authorizationManage) &&
      _boundary == ref.read(sensitiveReadBoundaryProvider);
  @override
  void initState() {
    super.initState();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _name = TextEditingController(
      text: widget.template?.name ?? widget.initialName,
    );
    _description = TextEditingController(
      text: widget.template?.description ?? widget.initialDescription,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (_saving || _uncertain || !_current) return;
    if (_name.text.trim().isEmpty ||
        _name.text.trim().length > 80 ||
        _description.text.trim().length > 1000) {
      setState(() => _error = l.permissionTemplateInvalidName);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: () => _current);
      final saved = await scope.run(
        () => ref
            .read(permissionTemplateRepositoryProvider)
            .save(
              template: widget.template,
              name: _name.text,
              description: _description.text,
              permissions: {
                ...?widget.template?.permissions,
                ...widget.initialCodes,
              },
            ),
      );
      if (mounted && _current) {
        ref.invalidate(permissionTemplatesProvider);
        context.appSuccess(l.permissionTemplateSaved);
        Navigator.pop(context, saved);
      }
    } catch (error) {
      if (_current) {
        setState(() {
          _uncertain =
              error is! ApiException ||
              error.httpStatus == null ||
              error.httpStatus! >= 500;
          _error = _uncertain
              ? l.permissionTemplateUncertain
              : error is ApiException
              ? error.message
              : l.permissionTemplateLoadFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sensitiveReadBoundaryProvider);
    final l = AppLocalizations.of(context);
    final enabled = _current && !_saving && !_uncertain;
    return PopScope(
      canPop: !_saving,
      child: UtenAlertDialog(
        title: Text(
          widget.template != null
              ? '编辑模板信息'
              : widget.importing
              ? '导入模板'
              : l.permissionTemplateNew,
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenInput(
                key: const ValueKey('permission-template-name'),
                label: l.permissionTemplateName,
                controller: _name,
                enabled: enabled,
                required: true,
              ),
              const SizedBox(height: UtenSpacing.s12),
              UtenInput(
                key: const ValueKey('permission-template-description'),
                label: '备注',
                controller: _description,
                enabled: enabled,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                widget.template != null
                    ? '权限在右侧面板直接设置，修改后自动保存。'
                    : '创建后进入权限设置，勾选权限后自动保存。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.importing)
                Text(
                  l.permissionTemplateSelectedCount(widget.initialCodes.length),
                ),
              if (!_current) Text(l.permissionTemplateBoundaryChanged),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: !_saving
                ? () {
                    if (_uncertain) ref.invalidate(permissionTemplatesProvider);
                    Navigator.pop(context);
                  }
                : null,
            child: Text(
              _uncertain
                  ? l.permissionTemplateClose
                  : l.permissionTemplateCancel,
            ),
          ),
          UtenButton(
            key: ValueKey(
              widget.template == null
                  ? 'create-permission-template'
                  : 'confirm-template-metadata',
            ),
            isLoading: _saving,
            onPressed: enabled ? _save : null,
            child: Text(
              widget.template != null
                  ? '保存信息'
                  : widget.importing
                  ? '导入并设置权限'
                  : '创建并设置权限',
            ),
          ),
        ],
      ),
    );
  }
}
