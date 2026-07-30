// AdminDepartmentPermView - 按部门配置权限点
//
// 单选部门（组织树任意节点）→ 从完整权限目录（/admin/permission-catalog，动态、不硬编码）勾选
// 权限点 → 保存（PUT /admin/departments/{id}/permissions，整体替换）。
// 部门初始为空白，由超级管理员按需配置；勾选权限授予该部门及其下级部门员工，
// 下次登录或令牌刷新后生效。
// 切换部门时若有未保存修改，二次确认后丢弃。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../core/theme/uten_colors.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import 'perm_catalog_group_section.dart';

class AdminDepartmentPermView extends ConsumerStatefulWidget {
  const AdminDepartmentPermView({super.key});

  @override
  ConsumerState<AdminDepartmentPermView> createState() =>
      _AdminDepartmentPermViewState();
}

class _AdminDepartmentPermViewState
    extends ConsumerState<AdminDepartmentPermView> {
  /// 当前选中的部门（单选）
  DeptSelection? _dept;

  /// 本地待保存的勾选集合；null = 未做任何编辑（跟随服务端数据）
  Set<String>? _localChecked;

  bool _saving = false;

  /// 用于强制重置部门选择器（取消切换时恢复显示原部门）
  int _pickerVersion = 0;

  /// 服务端已保存的勾选集合（未选部门或加载中为 null）
  Set<String>? get _serverChecked {
    final dept = _dept;
    if (dept == null) return null;
    return ref
        .watch(adminDepartmentPermissionsProvider(dept.id))
        .valueOrNull
        ?.toSet();
  }

  /// 当前生效显示的勾选集合
  Set<String> get _checked => _localChecked ?? _serverChecked ?? const {};

  /// 是否有未保存修改
  bool get _isDirty {
    final local = _localChecked;
    final server = _serverChecked;
    return local != null && server != null && !setEquals(local, server);
  }

  // ===== 部门切换（含未保存确认） =====

  Future<void> _onDeptChanged(List<DeptSelection> sel) async {
    final next = sel.isEmpty ? null : sel.first;
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
        // 取消切换：强制选择器恢复显示原部门
        setState(() => _pickerVersion++);
        return;
      }
    }
    setState(() {
      _dept = next;
      _localChecked = null;
    });
  }

  // ===== 保存 =====

  Future<void> _save() async {
    final dept = _dept;
    if (dept == null || _saving) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateDepartmentPermissions(dept.id, _checked.toList());
      // 保存成功后重新拉取确认
      ref.invalidate(adminDepartmentPermissionsProvider(dept.id));
      if (!mounted) return;
      setState(() => _localChecked = null);
      UtenToast.success(context, '已保存「${dept.name}」的权限配置');
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toggle(String code, bool value) {
    setState(() {
      final next = {...(_localChecked ?? _serverChecked ?? const <String>{})};
      if (value) {
        next.add(code);
      } else {
        next.remove(code);
      }
      _localChecked = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dept = _dept;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        // 顶部说明条（与页面说明条同风格）
        UtenCard(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '勾选的权限将授予该部门及其下级部门的所有员工，下次登录或令牌刷新后生效。'
                  '部门初始为空白，由超级管理员按需配置。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 单选部门
        UtenDepartmentPicker(
          key: ValueKey('${dept?.id ?? 'none'}-$_pickerVersion'),
          mode: UtenDepartmentPickerMode.single,
          label: '选择部门',
          initialSelection: [?dept],
          onChanged: _onDeptChanged,
        ),
        const SizedBox(height: 16),
        if (dept == null) _emptyGuide(theme) else _catalogCard(theme, dept),
      ],
    );
  }

  Widget _emptyGuide(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.domain_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              '先在上方选择一个部门，再为其勾选权限点',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _catalogCard(ThemeData theme, DeptSelection dept) {
    final permsAsync = ref.watch(adminDepartmentPermissionsProvider(dept.id));
    final catalogAsync = ref.watch(permissionCatalogProvider);
    final checked = _checked;

    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '部门权限 · ${dept.name}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _isDirty
                          ? '已勾选 ${checked.length} 项 · 有未保存修改'
                          : '已勾选 ${checked.length} 项',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _isDirty
                            ? UtenColors.warning
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              UtenButton(
                size: UtenButtonSize.small,
                isLoading: _saving,
                onPressed: permsAsync.hasValue && catalogAsync.hasValue
                    ? _save
                    : null,
                child: const Text('保存'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _catalogBody(permsAsync, catalogAsync, checked),
        ],
      ),
    );
  }

  Widget _catalogBody(
    AsyncValue<List<String>> permsAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
    Set<String> checked,
  ) {
    final theme = Theme.of(context);
    // 已配权限加载失败：重试
    if (permsAsync.hasError) {
      return _loadErrorWithRetry(
        theme,
        '部门权限加载失败',
        () => ref.invalidate(adminDepartmentPermissionsProvider(_dept!.id)),
      );
    }
    // 权限目录加载失败：重试
    if (catalogAsync.hasError) {
      return _loadErrorWithRetry(
        theme,
        '权限目录加载失败',
        () => ref.invalidate(permissionCatalogProvider),
      );
    }
    final groups = catalogAsync.valueOrNull;
    if (groups == null || permsAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (groups.isEmpty) {
      return Text(
        '权限目录为空',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in groups)
          PermCatalogGroupSection(
            title: group.category,
            countLabel:
                '${group.permissions.where((p) => checked.contains(p.code)).length}/${group.permissions.length}',
            children: [
              for (final p in group.permissions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.name,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              p.code,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: checked.contains(p.code),
                        onChanged: (v) => _toggle(p.code, v),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _loadErrorWithRetry(
    ThemeData theme,
    String message,
    VoidCallback onRetry,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: UtenColors.error,
              ),
            ),
          ),
          UtenButton(
            type: UtenButtonType.ghost,
            size: UtenButtonSize.small,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
