// AdminDepartmentPermView - 按部门配置动态权限目录。
//
// 部门配置保留完整权限点，使用搜索、状态筛选、默认折叠和整组批量操作降低
// 高密度目录的设置成本；未保存修改通过固定底部操作栏统一提交。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import 'permission_catalog_browser.dart';
import 'permission_action_badge.dart';

class AdminDepartmentPermView extends ConsumerStatefulWidget {
  const AdminDepartmentPermView({super.key, this.initialDepartmentId});

  final String? initialDepartmentId;

  @override
  ConsumerState<AdminDepartmentPermView> createState() =>
      _AdminDepartmentPermViewState();
}

class _AdminDepartmentPermViewState
    extends ConsumerState<AdminDepartmentPermView> {
  static const _individualOnlyPermissions = <String>{
    Perm.auditLogView,
    Perm.auditLogExport,
    Perm.accountBalanceAdjust,
  };

  DeptSelection? _dept;
  Set<String>? _localChecked;
  bool _saving = false;
  int _pickerVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveInitialDepartment();
    });
  }

  Future<void> _resolveInitialDepartment() async {
    final id = widget.initialDepartmentId;
    if (id == null || id.isEmpty) return;
    try {
      final tree = await ref.read(adminDepartmentTreeProvider.future);
      final selection = buildDeptSelectionMap(tree)[id];
      if (!mounted || selection == null || _dept != null) return;
      setState(() => _dept = selection);
    } catch (_) {
      // 选择器仍可手动使用；路由中的失效部门 id 不阻塞权限页。
    }
  }

  Set<String>? get _serverChecked {
    final department = _dept;
    if (department == null) return null;
    return ref
        .read(adminDepartmentPermissionsProvider(department.id))
        .valueOrNull
        ?.toSet();
  }

  Set<String> get _checked =>
      _localChecked ?? _serverChecked ?? const <String>{};

  bool get _isDirty {
    final local = _localChecked;
    final server = _serverChecked;
    return local != null && server != null && !setEquals(local, server);
  }

  int get _dirtyCount {
    final local = _localChecked;
    final server = _serverChecked;
    if (local == null || server == null) return 0;
    return {
      ...local,
      ...server,
    }.where((code) => local.contains(code) != server.contains(code)).length;
  }

  Future<void> _onDeptChanged(List<DeptSelection> selection) async {
    final next = selection.firstOrNull;
    if (next?.id == _dept?.id) return;
    if (_isDirty) {
      final confirmed = await UtenDialog.show(
        context,
        title: '丢弃未保存修改',
        content: const Text('当前部门有未保存的权限修改，切换部门将丢弃这些修改。确定切换吗？'),
        confirmLabel: '丢弃并切换',
        danger: true,
      );
      if (!mounted) return;
      if (confirmed != true) {
        setState(() => _pickerVersion++);
        return;
      }
    }
    setState(() {
      _dept = next;
      _localChecked = null;
    });
  }

  Future<void> _save() async {
    final department = _dept;
    if (department == null || _saving || !_isDirty) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateDepartmentPermissions(department.id, _checked.toList());
      ref.invalidate(adminDepartmentPermissionsProvider(department.id));
      if (!mounted) return;
      setState(() => _localChecked = null);
      UtenToast.success(context, '已保存「${department.name}」的权限配置并即时生效');
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存失败，本地修改已保留，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _setPermissions(Iterable<String> codes, bool value) {
    setState(() {
      final next = {..._checked};
      value ? next.addAll(codes) : next.removeAll(codes);
      _localChecked = next;
    });
  }

  void _toggle(String code, bool value) => _setPermissions([code], value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final department = _dept;
    final showSaveBar = department != null && _isDirty;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s4,
              UtenSpacing.s16,
              UtenSpacing.s32,
            ),
            children: [
              UtenCard(
                margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                  vertical: UtenSpacing.s12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: Text(
                        '勾选的权限会授予该部门及其下级部门员工。'
                        '可搜索、按状态筛选，或从分组右侧菜单整组配置。'
                        '审计查看、审计导出和账户余额调整属于高风险权限，'
                        '只能在个人授权中点名配置，不支持部门授权。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              UtenDepartmentPicker(
                key: ValueKey('${department?.id ?? 'none'}-$_pickerVersion'),
                mode: UtenDepartmentPickerMode.single,
                label: '选择部门',
                initialSelection: [?department],
                onChanged: _onDeptChanged,
              ),
              const SizedBox(height: UtenSpacing.s16),
              if (department == null)
                _emptyGuide(theme)
              else
                _catalogCard(theme, department),
            ],
          ),
        ),
        if (showSaveBar)
          UtenBottomActionBar(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已修改 $_dirtyCount 项',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _localChecked = null),
                  child: const Text('撤销'),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  size: UtenButtonSize.small,
                  isLoading: _saving,
                  onPressed: _saving ? null : _save,
                  child: const Text('保存更改'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _emptyGuide(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.domain_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '先在上方选择一个部门，再为其配置权限点',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _catalogCard(ThemeData theme, DeptSelection department) {
    final permissionsAsync = ref.watch(
      adminDepartmentPermissionsProvider(department.id),
    );
    final catalogAsync = ref.watch(permissionCatalogProvider);
    final checked = _checked;

    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '部门权限 · ${department.name}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _isDirty
                ? '已配置 ${checked.length} 项 · $_dirtyCount 项未保存'
                : '已配置 ${checked.length} 项',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _isDirty
                  ? UtenColors.warning
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          _catalogBody(permissionsAsync, catalogAsync, checked),
        ],
      ),
    );
  }

  Widget _catalogBody(
    AsyncValue<List<String>> permissionsAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
    Set<String> checked,
  ) {
    if (permissionsAsync.hasError || catalogAsync.hasError) {
      return UtenEmpty.error(
        message: '部门权限加载失败',
        description: '请检查网络后重试。',
        actionLabel: '重试',
        onAction: () {
          final department = _dept;
          if (department != null) {
            ref.invalidate(adminDepartmentPermissionsProvider(department.id));
          }
          ref.invalidate(permissionCatalogProvider);
        },
      );
    }
    final rawGroups = catalogAsync.valueOrNull;
    if (rawGroups == null || permissionsAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final groups = rawGroups
        .map(
          (group) => PermissionCatalogGroup(
            module: group.module,
            category: group.category,
            permissions: group.permissions
                .where(
                  (permission) =>
                      !_individualOnlyPermissions.contains(permission.code),
                )
                .toList(growable: false),
          ),
        )
        .where((group) => group.permissions.isNotEmpty)
        .toList(growable: false);
    if (groups.isEmpty) {
      return const UtenEmpty(
        icon: Icons.security_outlined,
        message: '权限目录为空',
        description: '后端尚未返回可配置的权限点。',
      );
    }

    return PermissionCatalogBrowser(
      groups: groups,
      enabledFilterLabel: '已配置',
      disabledFilterLabel: '未配置',
      enableGroupLabel: '本组全部配置',
      disableGroupLabel: '本组全部取消配置',
      enableModuleLabel: '本模块全部配置',
      disableModuleLabel: '本模块全部取消配置',
      isEnabled: (permission) => checked.contains(permission.code),
      onEnableGroup: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        true,
      ),
      onDisableGroup: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        false,
      ),
      enableAllLabel: '全部配置',
      disableAllLabel: '全部取消配置',
      onEnableAll: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        true,
      ),
      onDisableAll: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        false,
      ),
      itemBuilder: (context, permission) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
          child: Row(
            children: [
              Expanded(
                child: PermissionTitleBlock(
                  name: permission.name,
                  actionType: permission.actionType,
                  description: permission.description,
                  nameStyle: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Semantics(
                label:
                    '${permission.name}${checked.contains(permission.code) ? '已配置' : '未配置'}',
                child: Switch(
                  value: checked.contains(permission.code),
                  onChanged: (value) => _toggle(permission.code, value),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
