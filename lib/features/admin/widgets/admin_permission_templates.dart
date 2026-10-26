import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/admin_models.dart';
import '../models/permission_configuration.dart';
import '../models/permission_template.dart';
import '../repositories/permission_configuration_repository.dart';
import '../repositories/permission_template_repository.dart';
import 'admin_permission_transfer_actions.dart';
import 'permission_transfer_preview.dart';

import 'permission_template_metadata_dialog.dart';
export 'admin_permission_templates_workspace.dart';

bool _canManage(WidgetRef ref) =>
    ref.read(isSuperAdminProvider) &&
    ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);

class _TemplateError extends StatelessWidget {
  const _TemplateError({required this.message, required this.reload});
  final String message;
  final VoidCallback reload;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        const SizedBox(height: UtenSpacing.s12),
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: reload,
          child: Text(AppLocalizations.of(context).permissionTemplateRetry),
        ),
      ],
    ),
  );
}

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
        applied = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              _ApplyTemplateDialog(target: widget.user, boundary: boundary),
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

class _ApplyTemplateDialog extends ConsumerStatefulWidget {
  const _ApplyTemplateDialog({required this.target, required this.boundary});
  final AdminUserSummary target;
  final SensitiveReadBoundary boundary;
  @override
  ConsumerState<_ApplyTemplateDialog> createState() => _ApplyTemplateState();
}

class _ApplyTemplateState extends ConsumerState<_ApplyTemplateDialog> {
  PermissionTemplate? _template;
  bool _merge = true;
  bool _busy = false;
  bool _applying = false;
  bool _uncertain = false;
  PermissionTransferPreview? _preview;
  final _confirmed = <String>{};
  String? _error;
  bool get _current =>
      mounted &&
      _canManage(ref) &&
      widget.boundary == ref.read(sensitiveReadBoundaryProvider);
  void _reset() {
    _preview = null;
    _confirmed.clear();
    _error = null;
  }

  Future<void> _execute(bool apply) async {
    final template = _template;
    final preview = _preview;
    if (!_current ||
        _busy ||
        _uncertain ||
        template == null ||
        (apply &&
            (preview == null ||
                !preview.canApply ||
                !preview.confirmedBy(_confirmed)))) {
      return;
    }
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _applying = apply;
      _error = null;
    });
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: () => _current);
      final repository = ref.read(permissionTemplateRepositoryProvider);
      if (apply) {
        await scope.run(
          () => repository.apply(
            widget.target.id,
            template,
            _merge,
            preview!,
            _confirmed,
          ),
        );
        if (mounted && _current) {
          refreshPermissionConfiguration(ref);
          Navigator.pop(context, true);
        }
      } else {
        final result = await scope.run(
          () => repository.preview(widget.target.id, template, _merge),
        );
        if (_current) {
          setState(() {
            _preview = result;
            _confirmed.clear();
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _uncertain =
              apply &&
              (error is! ApiException ||
                  error.httpStatus == null ||
                  error.httpStatus! >= 500);
          _error = _uncertain
              ? l.permissionTemplateUncertain
              : _templateError(error, l);
          _preview = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _applying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sensitiveReadBoundaryProvider);
    final l = AppLocalizations.of(context);
    final templates = ref.watch(permissionTemplatesProvider);
    final enabled = _current && !_busy && !_uncertain;
    return PopScope(
      canPop: !_applying,
      child: UtenAlertDialog(
        maxWidth: 820,
        icon: const Icon(Icons.fact_check_outlined),
        title: Text(l.permissionTemplateApply),
        content: SizedBox(
          width: 740,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.target.employeeName ?? widget.target.loginAccount,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(l.permissionTemplateScopeNote),
              const SizedBox(height: UtenSpacing.s16),
              templates.when(
                loading: () => const LinearProgressIndicator(),
                error: (error, _) => _TemplateError(
                  message: _templateError(error, l),
                  reload: () => ref.invalidate(permissionTemplatesProvider),
                ),
                data: (items) => items.isEmpty
                    ? Text(l.permissionTemplateEmptyHint)
                    : UtenDropdownScrollScope(
                        nativeDropdown: true,
                        child: DropdownButtonFormField<PermissionTemplate>(
                          key: ValueKey(
                            items
                                .map((row) => '${row.id}:${row.version}')
                                .join(','),
                          ),
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: l.permissionTemplateSelect,
                          ),
                          initialValue: items
                              .where(
                                (row) =>
                                    row.id == _template?.id &&
                                    row.version == _template?.version,
                              )
                              .firstOrNull,
                          items: items
                              .map(
                                (row) => DropdownMenuItem(
                                  value: row,
                                  child: Text(row.name),
                                ),
                              )
                              .toList(),
                          onChanged: enabled
                              ? (value) => setState(() {
                                  _template = value;
                                  _reset();
                                })
                              : null,
                        ),
                      ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              RadioGroup<bool>(
                groupValue: _merge,
                onChanged: (value) {
                  if (enabled && value != null) {
                    setState(() {
                      _merge = value;
                      _reset();
                    });
                  }
                },
                child: Column(
                  children: [
                    RadioListTile<bool>(
                      value: true,
                      enabled: enabled,
                      title: Text(l.permissionTemplateMerge),
                      subtitle: Text(l.permissionTemplateMergeHint),
                    ),
                    RadioListTile<bool>(
                      value: false,
                      enabled: enabled,
                      title: Text(l.permissionTemplateReplace),
                      subtitle: Text(l.permissionTemplateReplaceHint),
                    ),
                  ],
                ),
              ),
              if (!_current) Text(l.permissionTemplateBoundaryChanged),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_preview != null)
                PermissionTransferPreviewDetails(
                  preview: _preview!,
                  confirmations: _confirmed,
                  enabled: enabled,
                  onConfirmationChanged: (key, selected) => setState(() {
                    if (selected) {
                      _confirmed.add(key);
                    } else {
                      _confirmed.remove(key);
                    }
                  }),
                ),
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: !_applying
                ? () {
                    if (_uncertain && _current) {
                      refreshPermissionConfiguration(ref);
                    }
                    Navigator.pop(context);
                  }
                : null,
            child: Text(l.permissionTemplateClose),
          ),
          UtenButton(
            type: UtenButtonType.secondary,
            isLoading: _busy && !_applying,
            onPressed: enabled && _template != null
                ? () => _execute(false)
                : null,
            child: Text(l.permissionTemplatePreview),
          ),
          UtenButton(
            key: const ValueKey('confirm-apply-permission-template'),
            isLoading: _applying,
            onPressed:
                enabled &&
                    _preview?.canApply == true &&
                    _preview!.confirmedBy(_confirmed)
                ? () => _execute(true)
                : null,
            child: Text(l.permissionTemplateApply),
          ),
        ],
      ),
    );
  }
}
