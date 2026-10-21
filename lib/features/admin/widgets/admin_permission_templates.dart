import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
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
import '../providers/admin_providers.dart';
import '../repositories/permission_configuration_repository.dart';
import '../repositories/permission_template_repository.dart';
import 'admin_permission_transfer_actions.dart';
import 'admin_permission_workspace.dart';
import 'permission_catalog_browser.dart';
import 'permission_transfer_preview.dart';

bool _canManage(WidgetRef ref) =>
    ref.read(isSuperAdminProvider) &&
    ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);

/// Saved snapshots share the account/department workspace, without introducing roles.
class AdminPermissionTemplatesView extends ConsumerStatefulWidget {
  const AdminPermissionTemplatesView({super.key, required this.navigation});
  final Widget navigation;
  @override
  ConsumerState<AdminPermissionTemplatesView> createState() =>
      _TemplatesViewState();
}

class _TemplatesViewState extends ConsumerState<AdminPermissionTemplatesView> {
  String? _selectedId;
  bool _detail = false;
  bool _busy = false;
  bool _deleting = false;

  Future<void> _edit([PermissionTemplate? template]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _TemplateEditor(template: template),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(PermissionTemplate template) async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        _canManage(ref) &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => UtenAlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l.permissionTemplateDelete),
        content: Text('${template.name}\n\n${l.permissionTemplateDeleteHint}'),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.permissionTemplateCancel),
          ),
          UtenButton(
            type: UtenButtonType.danger,
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.permissionTemplateDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !current()) return;
    setState(() {
      _busy = true;
      _deleting = true;
    });
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      await scope.run(
        () => ref.read(permissionTemplateRepositoryProvider).delete(template),
      );
      if (mounted && current()) {
        setState(() {
          _selectedId = null;
          _detail = false;
        });
        context.appSuccess(l.permissionTemplateDeleted);
      }
    } catch (error) {
      if (mounted && current()) context.appError(_templateError(error, l));
    } finally {
      if (mounted) {
        ref.invalidate(permissionTemplatesProvider);
        setState(() {
          _busy = false;
          _deleting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final templates = ref.watch(permissionTemplatesProvider);
    final catalog = ref.watch(permissionCatalogProvider);
    final rows = templates.value ?? const <PermissionTemplate>[];
    final selected = rows.where((row) => row.id == _selectedId).firstOrNull;
    final leading = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          child: UtenButton(
            key: const ValueKey('new-permission-template'),
            icon: Icons.add,
            onPressed: !_busy ? _edit : null,
            child: Text(l.permissionTemplateNew),
          ),
        ),
        Expanded(
          child: templates.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _TemplateError(
              message: _templateError(error, l),
              reload: () => ref.invalidate(permissionTemplatesProvider),
            ),
            data: (items) => items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Text(l.permissionTemplateEmptyHint),
                    ),
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UtenSpacing.s4),
                    itemBuilder: (context, index) {
                      final row = items[index];
                      return ListTile(
                        selected: row.id == selected?.id,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(UtenRadius.card),
                        ),
                        selectedTileColor: Theme.of(
                          context,
                        ).colorScheme.primaryContainer,
                        leading: const Icon(Icons.fact_check_outlined),
                        title: Text(row.name),
                        subtitle: Text(
                          l.permissionTemplateSelectedCount(
                            row.permissions.length,
                          ),
                        ),
                        trailing: row.id == selected?.id
                            ? const Icon(Icons.check_circle)
                            : null,
                        onTap: !_busy
                            ? () => setState(() {
                                _selectedId = row.id;
                                _detail = true;
                              })
                            : null,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
    final trailing = selected == null
        ? Center(child: Text(l.permissionTemplateNoSelection))
        : SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (selected.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s8),
                          child: SelectableText(selected.description),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: UtenSpacing.s12,
                        ),
                        child: Text(l.permissionTemplateSnapshotNote),
                      ),
                      Wrap(
                        spacing: UtenSpacing.s8,
                        runSpacing: UtenSpacing.s8,
                        children: [
                          UtenButton(
                            icon: Icons.edit_outlined,
                            onPressed: !_busy ? () => _edit(selected) : null,
                            child: Text(l.permissionTemplateEdit),
                          ),
                          UtenButton(
                            type: UtenButtonType.danger,
                            icon: Icons.delete_outline,
                            isLoading: _deleting,
                            onPressed: !_busy ? () => _delete(selected) : null,
                            child: Text(l.permissionTemplateDelete),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                catalog.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _TemplateError(
                    message: _templateError(error, l),
                    reload: () => ref.invalidate(permissionCatalogProvider),
                  ),
                  data: (groups) => PermissionCatalogBrowser(
                    key: ValueKey(selected.id),
                    groups: groups,
                    isEnabled: (permission) =>
                        selected.permissions.contains(permission.code),
                    itemBuilder: (_, permission) => CheckboxListTile(
                      value: selected.permissions.contains(permission.code),
                      onChanged: null,
                      title: Text(permission.name),
                      subtitle: permission.description == null
                          ? null
                          : Text(permission.description!),
                    ),
                  ),
                ),
              ],
            ),
          );
    return AdminPermissionWorkspace(
      navigation: widget.navigation,
      leading: leading,
      trailing: trailing,
      compact: _detail && selected != null
          ? Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => setState(() => _detail = false),
                  ),
                ),
                Expanded(child: trailing),
              ],
            )
          : leading,
    );
  }
}

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

class _TemplateEditor extends ConsumerStatefulWidget {
  const _TemplateEditor({
    this.template,
    this.initialCodes = const [],
    this.initialName = '',
  });
  final PermissionTemplate? template;
  final List<String> initialCodes;
  final String initialName;
  @override
  ConsumerState<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends ConsumerState<_TemplateEditor> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final Set<String> _codes;
  late final SensitiveReadBoundary _boundary;
  bool _saving = false;
  bool _uncertain = false;
  String? _error;
  bool get _current =>
      mounted &&
      _canManage(ref) &&
      _boundary == ref.read(sensitiveReadBoundaryProvider);
  @override
  void initState() {
    super.initState();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _name = TextEditingController(
      text: widget.template?.name ?? widget.initialName,
    );
    _description = TextEditingController(
      text: widget.template?.description ?? '',
    );
    _codes = {...?widget.template?.permissions, ...widget.initialCodes};
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
      await scope.run(
        () => ref
            .read(permissionTemplateRepositoryProvider)
            .save(
              template: widget.template,
              name: _name.text,
              description: _description.text,
              permissions: _codes,
            ),
      );
      if (mounted && _current) {
        ref.invalidate(permissionTemplatesProvider);
        context.appSuccess(l.permissionTemplateSaved);
        Navigator.pop(context, true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _uncertain =
              error is! ApiException ||
              error.httpStatus == null ||
              error.httpStatus! >= 500;
          _error = _uncertain
              ? l.permissionTemplateUncertain
              : _templateError(error, l);
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
    final catalog = ref.watch(permissionCatalogProvider);
    final known = {
      for (final group in catalog.value ?? <PermissionCatalogGroup>[])
        for (final permission in group.permissions) permission.code,
    };
    final unknown = _codes.difference(known);
    final enabled = _current && !_saving && !_uncertain;
    return PopScope(
      canPop: !_saving,
      child: UtenAlertDialog(
        maxWidth: 1040,
        title: Text(
          widget.template == null
              ? l.permissionTemplateNew
              : l.permissionTemplateEdit,
        ),
        content: SizedBox(
          width: 940,
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
              const SizedBox(height: UtenSpacing.s8),
              UtenInput(
                key: const ValueKey('permission-template-description'),
                label: l.permissionTemplateDescription,
                controller: _description,
                enabled: enabled,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                child: Text(l.permissionTemplateSelectedCount(_codes.length)),
              ),
              Text(
                l.permissionTemplateSensitiveNote,
                key: const ValueKey('permission-template-sensitive-note'),
              ),
              if (!_current) Text(l.permissionTemplateBoundaryChanged),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (catalog.hasValue && unknown.isNotEmpty)
                Wrap(
                  children: [
                    Text(l.permissionTemplateUnknownCodes),
                    TextButton(
                      onPressed: enabled
                          ? () => setState(() => _codes.removeAll(unknown))
                          : null,
                      child: Text(l.permissionTemplateClearUnknown),
                    ),
                  ],
                ),
              const SizedBox(height: UtenSpacing.s16),
              catalog.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _TemplateError(
                  message: _templateError(error, l),
                  reload: () => ref.invalidate(permissionCatalogProvider),
                ),
                data: (groups) => PermissionCatalogBrowser(
                  groups: groups,
                  isEnabled: (permission) => _codes.contains(permission.code),
                  itemBuilder: (_, permission) => CheckboxListTile(
                    key: ValueKey('template-code-${permission.code}'),
                    title: Text(permission.name),
                    subtitle: permission.description == null
                        ? null
                        : Text(permission.description!),
                    value: _codes.contains(permission.code),
                    onChanged:
                        enabled && permission.grantPolicy.individuallyGrantable
                        ? (value) => setState(() {
                            if (value == true) {
                              _codes.add(permission.code);
                            } else {
                              _codes.remove(permission.code);
                            }
                          })
                        : null,
                  ),
                ),
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
            key: const ValueKey('save-permission-template'),
            isLoading: _saving,
            onPressed: enabled && catalog.hasValue ? _save : null,
            child: Text(l.permissionTemplateSave),
          ),
        ],
      ),
    );
  }
}

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
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _TemplateEditor(
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
                    : DropdownButtonFormField<PermissionTemplate>(
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
