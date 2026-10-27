import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_page_layout.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/admin_models.dart';
import '../models/permission_template.dart';
import '../providers/admin_providers.dart';
import '../repositories/permission_template_repository.dart';
import '../services/permission_archive_files.dart';
import 'admin_permission_export_button.dart';
import 'admin_permission_transfer_actions.dart';
import 'admin_permission_workspace.dart';
import 'permission_action_badge.dart';
import 'permission_catalog_browser.dart';
import 'permission_template_metadata_dialog.dart';

/// The draft belongs to the workspace, above both responsive pane layouts.
class AdminPermissionTemplatesView extends ConsumerStatefulWidget {
  const AdminPermissionTemplatesView({
    super.key,
    required this.navigation,
    this.onPermissionDirtyChanged,
  });
  final Widget navigation;
  final ValueChanged<bool>? onPermissionDirtyChanged;
  @override
  ConsumerState<AdminPermissionTemplatesView> createState() =>
      _TemplatesState();
}

class _TemplatesState extends ConsumerState<AdminPermissionTemplatesView> {
  final _search = TextEditingController();
  late final SensitiveReadBoundary _boundary;
  PermissionTemplate? _selected;
  Set<String> _codes = {};
  Timer? _autosave;
  Future<bool>? _inFlight;
  String _query = '';
  String? _error;
  bool _detail = false;
  bool _busy = false;
  bool _saving = false;
  bool _uncertain = false;
  bool? _reportedPending;
  bool get _current =>
      mounted &&
      ref.read(isSuperAdminProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.authorizationManage) &&
      _boundary == ref.read(sensitiveReadBoundaryProvider);
  bool get _dirty =>
      _selected != null && !setEquals(_codes, _selected!.permissions.toSet());
  bool get _pending => _dirty || _saving || _busy || _uncertain;
  @override
  void initState() {
    super.initState();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _select(PermissionTemplate template) {
    _autosave?.cancel();
    setState(() {
      _selected = template;
      _codes = template.permissions.toSet();
      _detail = true;
      _error = null;
      _uncertain = false;
    });
  }

  Future<void> _choose(PermissionTemplate template) async {
    if (_busy || !_current) return;
    if (template.id == _selected?.id) {
      setState(() => _detail = true);
      return;
    }
    if (await _save() && _current) _select(template);
  }

  void _change(String code, bool value) {
    if (!_current || _uncertain || _busy) return;
    setState(() {
      if (value) {
        _codes.add(code);
      } else {
        _codes.remove(code);
      }
      _error = null;
    });
    _autosave?.cancel();
    if (_dirty) {
      _autosave = Timer(const Duration(milliseconds: 650), () => _save());
    }
  }

  /// A single versioned queue flushes newer choices after the active write.
  /// Unknown outcomes stop the queue rather than replaying a business write.
  Future<bool> _save({bool notify = false}) async {
    _autosave?.cancel();
    while (_inFlight != null) {
      final previous = _inFlight!;
      if (!await previous) return false;
      if (identical(_inFlight, previous)) _inFlight = null;
    }
    if (!mounted || !_current || _uncertain) return false;
    if (!_dirty) {
      if (notify) {
        context.appSuccess(
          AppLocalizations.of(context).permissionTemplateSaved,
        );
      }
      return true;
    }
    final operation = _persist();
    _inFlight = operation;
    final success = await operation;
    if (identical(_inFlight, operation)) _inFlight = null;
    if (!mounted || !success || !_current) return false;
    if (_dirty) return _save(notify: notify);
    if (notify) {
      context.appSuccess(AppLocalizations.of(context).permissionTemplateSaved);
    }
    return true;
  }

  Future<bool> _persist() async {
    final template = _selected!;
    final codes = {..._codes};
    bool current() => _current && _selected?.id == template.id;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      final saved = await scope.run(
        () => ref
            .read(permissionTemplateRepositoryProvider)
            .save(
              template: template,
              name: template.name,
              description: template.description,
              permissions: codes,
            ),
      );
      if (!current()) return false;
      // Advance the saved version; never overwrite edits made during the request.
      setState(() => _selected = saved);
      ref.invalidate(permissionTemplatesProvider);
      return true;
    } catch (error) {
      if (current()) {
        setState(() {
          _uncertain =
              error is! ApiException ||
              error.httpStatus == null ||
              error.httpStatus! >= 500;
          _error = _uncertain
              ? AppLocalizations.of(context).permissionTemplateUncertain
              : _errorText(error);
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _metadata({bool edit = false, bool importing = false}) async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      if (!await _save() || !_current) return;
      final archive = importing
          ? await pickPermissionTemplateArchive(stillCurrent: () => _current)
          : null;
      if (!mounted || !_current || (importing && archive == null)) return;
      final result = await showDialog<PermissionTemplate>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PermissionTemplateMetadataDialog(
          template: edit ? _selected : null,
          initialName: archive?.name ?? '',
          initialDescription: archive?.description ?? '',
          initialCodes: archive?.permissions.toList() ?? const [],
          importing: importing,
        ),
      );
      if (_current && result != null) _select(result);
    } catch (error) {
      if (mounted && _current) {
        context.appError(permissionTransferError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    if (_saving || _busy || !_current) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: const Text('重新加载模板'),
        content: const Text('将读取服务器上的最新模板，并替换当前未保存的选择。是否继续？'),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重新加载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_current) return;
    _autosave?.cancel();
    setState(() => _busy = true);
    try {
      final id = _selected?.id;
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: () => _current);
      final rows = await scope.run(
        () => ref.read(permissionTemplateRepositoryProvider).list(),
      );
      if (!_current) return;
      final saved = rows.where((row) => row.id == id).firstOrNull;
      if (saved != null) {
        _select(saved);
      } else {
        setState(() {
          _selected = null;
          _codes = {};
          _uncertain = false;
          _error = null;
          _detail = false;
        });
      }
      ref.invalidate(permissionTemplatesProvider);
    } catch (error) {
      if (mounted && _current) {
        context.appError(_errorText(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final template = _selected;
    if (template == null || _busy || _saving || !_current || _uncertain) return;
    _autosave?.cancel();
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(l.permissionTemplateDelete),
        content: Text('${template.name}\n\n${l.permissionTemplateDeleteHint}'),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.permissionTemplateCancel),
          ),
          UtenButton(
            type: UtenButtonType.danger,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.permissionTemplateDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !_current) {
      if (_current && _dirty && _error == null) {
        _autosave = Timer(const Duration(milliseconds: 650), () => _save());
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: () => _current);
      await scope.run(
        () => ref.read(permissionTemplateRepositoryProvider).delete(template),
      );
      if (mounted && _current) {
        setState(() {
          _selected = null;
          _codes = {};
          _detail = false;
          _error = null;
        });
        context.appSuccess(l.permissionTemplateDeleted);
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
              : _errorText(error);
        });
      }
    } finally {
      if (mounted) {
        ref.invalidate(permissionTemplatesProvider);
        setState(() => _busy = false);
      }
    }
  }

  String _errorText(Object error) => error is ApiException
      ? error.message
      : AppLocalizations.of(context).permissionTemplateLoadFailed;

  @override
  Widget build(BuildContext context) {
    ref.watch(sensitiveReadBoundaryProvider);
    if (_reportedPending != _pending) {
      _reportedPending = _pending;
      final pending = _pending;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onPermissionDirtyChanged?.call(pending);
      });
    }
    final l = AppLocalizations.of(context);
    final templates = ref.watch(permissionTemplatesProvider);
    final selected = _selected;
    final leading = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenSearchBar(
          controller: _search,
          hint: '搜索模板名称 / 备注',
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: templates.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _loadError(
              error,
              () => ref.invalidate(permissionTemplatesProvider),
            ),
            data: (items) {
              final rows = items
                  .where(
                    (row) => '${row.name} ${row.description}'
                        .toLowerCase()
                        .contains(_query),
                  )
                  .toList();
              if (rows.isEmpty) {
                return UtenEmpty(
                  icon: Icons.fact_check_outlined,
                  message: items.isEmpty ? '还没有权限模板' : '没有匹配的模板',
                  description: items.isEmpty
                      ? '点击右下角「新建模板」或「导入模板」开始设置。'
                      : '换个名称或备注关键词试试。',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.only(
                  bottom: UtenFloatingActionGroup.scrollClearance,
                ),
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: UtenSpacing.s4),
                itemBuilder: (context, index) {
                  final row = rows[index].id == selected?.id
                      ? selected!
                      : rows[index];
                  return ListTile(
                    key: ValueKey('permission-template-${row.id}'),
                    selected: row.id == selected?.id,
                    shape: const RoundedRectangleBorder(
                      borderRadius: UtenRadius.controlAll,
                    ),
                    selectedTileColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    leading: const Icon(Icons.fact_check_outlined),
                    title: Text(row.name),
                    subtitle: Text(
                      '${l.permissionTemplateSelectedCount(row.id == selected?.id ? _codes.length : row.permissions.length)}${row.description.isEmpty ? '' : '\n${row.description}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: row.id == selected?.id
                        ? const Icon(Icons.chevron_right)
                        : null,
                    onTap: !_busy && _current ? () => _choose(row) : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
    final trailing = _permissions();
    final workspace = AdminPermissionWorkspace(
      navigation: widget.navigation,
      leading: leading,
      trailing: trailing,
      compact: _detail && selected != null
          ? Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回模板列表'),
                    onPressed: () => setState(() => _detail = false),
                  ),
                ),
                Expanded(child: trailing),
              ],
            )
          : leading,
    );
    return PopScope(
      canPop: !_pending,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _busy) return;
        if (await _save() && context.mounted) {
          Navigator.of(context).pop(result);
        }
      },
      child: Stack(
        children: [
          Positioned.fill(child: workspace),
          Positioned(
            right: UtenPageEdgePadding.resolve(
              context,
              const EdgeInsets.all(UtenSpacing.s16),
            ).right,
            bottom: UtenSpacing.s16,
            left: UtenSpacing.s16,
            child: Align(
              alignment: Alignment.bottomRight,
              child: UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    key: const ValueKey('import-permission-template'),
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.large,
                    icon: Icons.upload_outlined,
                    onPressed: _current && !_busy && !_uncertain
                        ? () => _metadata(importing: true)
                        : null,
                    child: const Text('导入模板'),
                  ),
                  UtenButton(
                    key: const ValueKey('new-permission-template'),
                    type: selected == null
                        ? UtenButtonType.primary
                        : UtenButtonType.secondary,
                    size: UtenButtonSize.large,
                    icon: Icons.add,
                    onPressed: _current && !_busy && !_uncertain
                        ? () => _metadata()
                        : null,
                    child: Text(l.permissionTemplateNew),
                  ),
                  if (selected != null)
                    UtenButton(
                      key: const ValueKey('save-permission-template'),
                      size: UtenButtonSize.large,
                      icon: Icons.save_outlined,
                      isLoading: _saving,
                      onPressed: _current && !_busy && !_saving && !_uncertain
                          ? () => _save(notify: true)
                          : null,
                      child: Text(l.permissionTemplateSave),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _loadError(Object error, VoidCallback retry) => UtenEmpty.error(
    message: _errorText(error),
    actionLabel: '重试',
    onAction: retry,
  );

  Widget _permissions() {
    final l = AppLocalizations.of(context);
    final selected = _selected;
    if (selected == null) {
      return const UtenEmpty(
        icon: Icons.tune_rounded,
        message: '选择模板，设置权限',
        description: '从左侧选择已有模板，或在右下角新建、导入模板。',
      );
    }
    final theme = Theme.of(context);
    final catalog = ref.watch(permissionCatalogProvider);
    final known = {
      for (final group in catalog.value ?? <PermissionCatalogGroup>[])
        for (final permission in group.permissions) permission.code,
    };
    final unknown = _codes.difference(known);
    final enabled = _current && !_busy && !_uncertain;
    final status = !_current
        ? l.permissionTemplateBoundaryChanged
        : _saving
        ? '正在保存…'
        : _error != null
        ? '保存未完成'
        : _dirty
        ? '等待自动保存'
        : '已自动保存';
    return UtenPageEdgePadding.scroll(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s4,
        UtenSpacing.s16,
        UtenFloatingActionGroup.scrollClearance,
      ),
      preserveStart: true,
      builder: (context, pagePadding) => ListView(
        padding: pagePadding,
        children: [
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: UtenSpacing.s16,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '模板权限 · ${selected.name}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '${l.permissionTemplateSelectedCount(_codes.length)} · $status',
                          key: const ValueKey(
                            'permission-template-save-status',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _error != null
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: UtenSpacing.s4,
                      runSpacing: UtenSpacing.s4,
                      children: [
                        AdminPermissionExportButton(
                          scope: PermissionExportScope.template,
                          template: selected,
                          enabled: !_pending,
                        ),
                        UtenButton(
                          key: const ValueKey('edit-permission-template'),
                          type: UtenButtonType.secondary,
                          size: UtenButtonSize.small,
                          icon: Icons.edit_outlined,
                          onPressed: enabled && !_saving
                              ? () => _metadata(edit: true)
                              : null,
                          child: const Text('编辑信息'),
                        ),
                        UtenButton(
                          type: UtenButtonType.danger,
                          size: UtenButtonSize.small,
                          icon: Icons.delete_outline,
                          onPressed: enabled && !_saving ? _delete : null,
                          child: Text(l.permissionTemplateDelete),
                        ),
                      ],
                    ),
                  ],
                ),
                if (selected.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s8),
                    child: SelectableText(selected.description),
                  ),
                const SizedBox(height: UtenSpacing.s12),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        Wrap(
                          spacing: UtenSpacing.s8,
                          children: [
                            if (!_uncertain)
                              TextButton(
                                onPressed: _current && !_saving
                                    ? () => _save()
                                    : null,
                                child: const Text('重试保存'),
                              ),
                            TextButton(
                              onPressed: _current && !_saving && !_busy
                                  ? _reload
                                  : null,
                              child: const Text('重新加载模板'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (catalog.hasValue && unknown.isNotEmpty)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(l.permissionTemplateUnknownCodes),
                      TextButton(
                        onPressed: enabled
                            ? () {
                                for (final code in unknown) {
                                  _change(code, false);
                                }
                              }
                            : null,
                        child: Text(l.permissionTemplateClearUnknown),
                      ),
                    ],
                  ),
                catalog.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _loadError(
                    error,
                    () => ref.invalidate(permissionCatalogProvider),
                  ),
                  data: (groups) => PermissionCatalogBrowser(
                    key: ValueKey(selected.id),
                    groups: groups,
                    enabledFilterLabel: '已选',
                    disabledFilterLabel: '未选',
                    isEnabled: (permission) => _codes.contains(permission.code),
                    itemBuilder: (context, permission) => Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s4,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: PermissionTitleBlock(
                              name: permission.name,
                              actionType: permission.actionType,
                              description: permission.description,
                              grantPolicy: permission.grantPolicy,
                              sensitivity: permission.sensitivity,
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          Switch(
                            key: ValueKey('template-code-${permission.code}'),
                            value: _codes.contains(permission.code),
                            onChanged:
                                enabled &&
                                    permission.grantPolicy.individuallyGrantable
                                ? (value) => _change(permission.code, value)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
