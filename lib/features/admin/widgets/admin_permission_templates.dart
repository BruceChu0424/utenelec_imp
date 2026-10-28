import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/admin_models.dart';
import '../models/permission_template.dart';
import '../repositories/permission_configuration_repository.dart';

import 'permission_template_metadata_dialog.dart';
import 'permission_batch_dialog.dart';
export 'admin_permission_templates_workspace.dart';

bool _canManage(WidgetRef ref) =>
    ref.read(isSuperAdminProvider) &&
    ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);

String _templateError(Object error, AppLocalizations l) =>
    error is ApiException ? error.message : l.permissionTemplateLoadFailed;

class AdminPermissionTemplateActions extends ConsumerStatefulWidget {
  const AdminPermissionTemplateActions({
    super.key,
    required this.user,
    required this.enabled,
    required this.onApplied,
  });
  final AdminUserSummary user;
  final bool enabled;
  final VoidCallback onApplied;
  @override
  ConsumerState<AdminPermissionTemplateActions> createState() =>
      _TemplateActionsState();
}

class _TemplateActionsState
    extends ConsumerState<AdminPermissionTemplateActions> {
  bool _busy = false;
  bool _fetching = false;
  Future<void> _run(bool save) async {
    if (_busy || !widget.enabled) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final target = widget.user.id;
    bool current() =>
        mounted &&
        widget.enabled &&
        widget.user.id == target &&
        _canManage(ref) &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _busy = true;
      _fetching = save;
    });
    try {
      bool? applied;
      if (save) {
        final scope = await ref
            .read(apiClientProvider)
            .captureRequestScope(isCurrent: current);
        final source = await scope.run(
          () =>
              ref.read(permissionConfigurationRepositoryProvider).copy(target),
        );
        if (!mounted || !current()) return;
        setState(() => _fetching = false);
        await showDialog<PermissionTemplate>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PermissionTemplateMetadataDialog(
            initialCodes: source.permissions,
            initialName: widget.user.employeeName ?? widget.user.loginAccount,
          ),
        );
      } else {
        applied = await showPermissionBatchDialog(
          context,
          templateMode: true,
          userIds: [target],
          targetLabel: widget.user.employeeName ?? widget.user.loginAccount,
        );
      }
      if (mounted && current() && applied == true) {
        widget.onApplied();
        context.appSuccess(
          AppLocalizations.of(context).permissionTemplateApplied,
        );
      }
    } catch (error) {
      if (mounted && current()) {
        context.appError(_templateError(error, AppLocalizations.of(context)));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _fetching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: UtenSpacing.s4,
      runSpacing: UtenSpacing.s4,
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.bookmark_add_outlined,
          isLoading: _fetching,
          onPressed: widget.enabled && !_busy ? () => _run(true) : null,
          child: Text(l.permissionTemplateSaveFromUser),
        ),
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.fact_check_outlined,
          onPressed: widget.enabled && !_busy ? () => _run(false) : null,
          child: Text(l.permissionTemplateApply),
        ),
      ],
    );
  }
}
