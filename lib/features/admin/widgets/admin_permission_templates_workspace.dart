import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/network/read_scope_revision.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_page_layout.dart';
import '../../../components/layout/uten_table_column_kit.dart'
    show utenTableSelectedRowColor;
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/admin_models.dart';
import '../models/permission_template.dart';
import '../models/permission_template_selection_plan.dart';
import '../providers/admin_providers.dart';
import '../repositories/permission_template_repository.dart';
import '../services/permission_archive_files.dart';
import 'admin_permission_export_button.dart';
import 'admin_permission_transfer_actions.dart';
import 'admin_permission_workspace.dart';
import 'permission_action_badge.dart';
import 'permission_catalog_browser.dart';
import 'admin_permission_editor_surface.dart';
import 'permission_draft_session.dart';
import 'permission_template_metadata_dialog.dart';

/// The draft belongs to the workspace, above both responsive pane layouts.
class AdminPermissionTemplatesView extends ConsumerStatefulWidget {
  const AdminPermissionTemplatesView({
    super.key,
    required this.navigation,
    this.onPermissionDirtyChanged,
    this.onLeaveGuardChanged,
  });
  final Widget navigation;
  final ValueChanged<bool>? onPermissionDirtyChanged;

  /// 宿主页面的离开守卫登记（有草稿时三选一，返回 true 才放行）。
  final ValueChanged<Future<bool> Function()?>? onLeaveGuardChanged;
  @override
  ConsumerState<AdminPermissionTemplatesView> createState() =>
      _TemplatesState();
}

class _TemplatesState extends ConsumerState<AdminPermissionTemplatesView> {
  final _catalogMount = PermissionCatalogMount();
  final _search = TextEditingController();
  late final SensitiveReadBoundary _boundary;
  PermissionTemplate? _selected;
  Set<String> _codes = {};
  final _sensitiveConfirmed = <String>{};
  Future<bool>? _inFlight;
  String _query = '';
  String? _error;
  bool _detail = false;
  bool _busy = false;
  bool _saving = false;
  bool _uncertain = false;
  bool? _reportedPending;
  late final PermissionDraftSession _idleSave;
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
    _idleSave = PermissionDraftSession(onIdleSave: () => _save());
    widget.onLeaveGuardChanged?.call(_confirmLeave);
  }

  @override
  void dispose() {
    _idleSave.dispose();
    widget.onLeaveGuardChanged?.call(null);
    _search.dispose();
    super.dispose();
  }

  /// 离开守卫：有草稿时三选一；保存需一次密码（模板保存接口要求再认证）。
  Future<bool> _confirmLeave() async {
    if (!_dirty || !mounted) return true;
    _idleSave.pause();
    try {
      final allowed = await guardPermissionDraftLeave(
        context,
        subject: '权限模板「${_selected?.name ?? ''}」',
        changeCount:
            _codes.difference(_selected!.permissions.toSet()).length +
            _selected!.permissions.toSet().difference(_codes).length,
        save: () => _save(),
      );
      if (allowed && mounted && _dirty) {
        // 不保存离开：丢弃本地草稿，回到已保存版本。
        setState(() {
          _codes = _selected!.permissions.toSet();
          _error = null;
        });
        _idleSave.clear();
      }
      return allowed;
    } finally {
      if (mounted) _idleSave.resume();
    }
  }

  void _select(PermissionTemplate template) {
    setState(() {
      _selected = template;
      _codes = template.permissions.toSet();
      _sensitiveConfirmed.clear();
      _detail = true;
      _error = null;
      _uncertain = false;
    });
    _idleSave.clear();
  }

  Future<void> _choose(PermissionTemplate template) async {
    if (_busy || !_current) return;
    if (template.id == _selected?.id) {
      setState(() => _detail = true);
      return;
    }
    if (await _confirmLeave() && _current) _select(template);
  }

  void _change(String code, bool value) => _changeMany([code], value);

  void _changeMany(Iterable<String> codes, bool value) {
    if (!_current || _uncertain || _busy) return;
    final catalog = [
      for (final group
          in ref.read(permissionCatalogProvider).value ??
              const <PermissionCatalogGroup>[])
        ...group.permissions,
    ];
    final plan = PermissionTemplateSelectionPlan.selectMany(
      current: _codes,
      catalog: catalog,
      codes: codes,
      enabled: value,
    );
    if (plan.blocked.isNotEmpty) {
      context.appWarning('请先单独选择所需查看权限：${plan.blocked.join('、')}');
      return;
    }
    setState(() {
      _codes = plan.codes;
      _error = null;
    });
    if (plan.relatedRemoved.isNotEmpty) {
      context.appInfo('已同时移出 ${plan.relatedRemoved.length} 项依赖该查看权限的动作，保存后生效');
    }
    // 本地草稿：不再 650ms 即存（每次保存都要输一次密码）；
    // 停止操作一段时间后自动保存，切模板/离开页面时三选一。
    if (_dirty) {
      _idleSave.noteEdit();
    } else {
      _idleSave.clear();
    }
  }

  Future<void> _togglePermission(AdminPermission permission, bool value) async {
    final target = _selected?.id;
    final needsConfirmation =
        value &&
        !_codes.contains(permission.code) &&
        (!permission.grantPolicy.bulkEligible ||
            permission.sensitivity != 'NORMAL');
    if (needsConfirmation) {
      final confirmed = await UtenDialog.show(
        context,
        title: '确认模板敏感权限',
        content: Text(
          '「${permission.name}」涉及敏感能力。保存后会同步到此模板的所有实时关联对象；个人取消继续优先。',
        ),
        confirmLabel: '确认加入模板',
        danger: true,
      );
      if (!mounted ||
          !_current ||
          _selected?.id != target ||
          confirmed != true) {
        return;
      }
      _sensitiveConfirmed.add(permission.code);
    }
    _change(permission.code, value);
  }

  /// A single versioned queue flushes newer choices after the active write.
  /// Unknown outcomes stop the queue rather than replaying a business write.
  Future<bool> _save({bool notify = false}) async {
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
            .saveReviewed(
              template: template,
              name: template.name,
              description: template.description,
              permissions: codes,
              sensitiveConfirmations: _sensitiveConfirmed.intersection(
                codes.difference(template.permissions.toSet()),
              ),
            ),
      );
      if (!current()) return false;
      // Advance the saved version; never overwrite edits made during the request.
      setState(() => _selected = saved);
      _sensitiveConfirmed.removeWhere(
        (code) => saved.permissions.contains(code),
      );
      _idleSave.clear();
      refreshPermissionConfiguration(ref);
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
    _idleSave.pause();
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
      if (mounted) {
        setState(() => _busy = false);
        _idleSave.resume();
      }
    }
  }

  Future<void> _delete() async {
    final template = _selected;
    if (template == null || _busy || _saving || !_current || _uncertain) return;
    _idleSave.pause();
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
        _idleSave.noteEdit();
      } else {
        _idleSave.resume();
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
        _idleSave.clear();
        refreshPermissionConfiguration(ref);
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
        if (_current) refreshPermissionConfiguration(ref);
        setState(() => _busy = false);
        _idleSave.resume();
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
                    // 与「按员工」卡片列表、表格选中行同语言的定稿选中色
                    // （primaryContainer 亮薄荷与全站选中口径不一致）。
                    selectedTileColor: utenTableSelectedRowColor(
                      Theme.of(context),
                    ),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: const Icon(Icons.fact_check_outlined, size: 20),
                    title: Text(row.name),
                    subtitle: Text(
                      '${l.permissionTemplateSelectedCount(row.id == selected?.id ? _codes.length : row.permissions.length)}'
                      '${row.appliedCount > 0 ? ' · ${row.appliedUserCount} 人 / ${row.appliedDepartmentCount} 部门' : ''}'
                      '${row.description.isEmpty ? '' : '\n${row.description}'}',
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
    // 离开守卫由宿主 AdminPermissionsPage 的路由级 PopScope 统一处理
    //（本视图经 onLeaveGuardChanged 登记三选一）；这里不再自持 PopScope，
    // 避免同一路由两道 canPop 互相卡死。
    return Stack(
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
        ? '有未保存修改（闲置后自动保存）'
        : '已保存';
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
          AdminPermissionEditorSurface(
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
                if (selected.appliedCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '关联 ${selected.appliedUserCount} 名员工、${selected.appliedDepartmentCount} 个部门；实时关联随修改同步；旧版快照需重新应用，负责人委派按最新权限核对。',
                      style: theme.textTheme.bodySmall,
                    ),
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
                    key: _catalogMount.forOwner((
                      ref.watch(sensitiveReadBoundaryProvider),
                      ref.watch(readScopeRevisionProvider),
                      selected.id,
                    )),
                    groups: groups,
                    enabledFilterLabel: '已选',
                    disabledFilterLabel: '未选',
                    isEnabled: (permission) => _codes.contains(permission.code),
                    enableAllLabel: '选择全部普通权限',
                    disableAllLabel: '清空模板权限',
                    enableModuleLabel: '选择本模块普通权限',
                    disableModuleLabel: '移出本模块权限',
                    enableGroupLabel: '选择本组普通权限',
                    disableGroupLabel: '移出本组权限',
                    onGrantScope: enabled
                        ? (scope) => _changeMany([
                            for (final group in groups)
                              if ((scope.module == null ||
                                      scope.module == group.module) &&
                                  (scope.category == null ||
                                      scope.category == group.category))
                                for (final permission in group.permissions)
                                  if (permission.grantPolicy.bulkEligible)
                                    permission.code,
                          ], true)
                        : null,
                    onDisableGroup: enabled
                        ? (permissions) => _changeMany(
                            permissions.map((permission) => permission.code),
                            false,
                          )
                        : null,
                    onDisableAll: enabled
                        ? (_) => _changeMany(_codes.toList(), false)
                        : null,
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
                                ? (value) =>
                                      _togglePermission(permission, value)
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
