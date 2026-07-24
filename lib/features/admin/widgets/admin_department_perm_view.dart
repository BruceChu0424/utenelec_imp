// AdminDepartmentPermView - 按部门配置角色
//
// UtenDepartmentPicker（多选 + 抽屉）选中多个部门 → 统一勾选角色 → 批量保存
// （循环 PUT /admin/departments/{id}/roles，全部完成后 Toast 汇总）。
// 已配角色的部门在树节点旁显示角色数徽标（数据来自 adminDepartmentRolesProvider）。
// 部门角色对该部门的直属员工生效（不含子部门）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';

class AdminDepartmentPermView extends ConsumerStatefulWidget {
  const AdminDepartmentPermView({super.key});

  @override
  ConsumerState<AdminDepartmentPermView> createState() =>
      _AdminDepartmentPermViewState();
}

class _AdminDepartmentPermViewState
    extends ConsumerState<AdminDepartmentPermView> {
  List<DeptSelection> _selectedDepts = const [];
  final Set<String> _selectedRoles = {};
  bool _saving = false;

  Future<void> _saveAll() async {
    if (_selectedDepts.isEmpty || _saving) return;
    setState(() => _saving = true);
    final repo = ref.read(adminRepositoryProvider);
    final roles = _selectedRoles.toList();
    var ok = 0;
    var failed = 0;
    for (final dept in _selectedDepts) {
      try {
        await repo.updateDepartmentRoles(dept.id, roles);
        ok++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (failed == 0) {
      UtenToast.success(context, '已保存 $ok 个部门的角色配置');
    } else {
      UtenToast.warning(context, '保存完成：成功 $ok 个，失败 $failed 个');
    }
    ref.invalidate(adminDepartmentRolesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rolesAsync = ref.watch(adminRolesProvider);
    final entryById = {
      for (final e
          in ref.watch(adminDepartmentRolesProvider).valueOrNull ??
              const <DepartmentRoleEntry>[])
        e.departmentId: e,
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '部门角色对该部门的直属员工生效（不含子部门）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        UtenDepartmentPicker(
          mode: UtenDepartmentPickerMode.multi,
          label: '选择部门（可多选）',
          initialSelection: _selectedDepts,
          badgeCountFor: (id) => entryById[id]?.roles.length,
          onChanged: (sel) => setState(() => _selectedDepts = sel),
        ),
        const SizedBox(height: 16),
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '统一分配角色',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _selectedDepts.isEmpty
                    ? '先在上方选择一个或多个部门'
                    : '将应用到 ${_selectedDepts.length} 个部门',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              rolesAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Text(
                  '角色加载失败',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                data: (roles) {
                  if (roles.isEmpty) {
                    return Text(
                      '暂无可分配角色',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    );
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final role in roles)
                        FilterChip(
                          selected: _selectedRoles.contains(role.code),
                          onSelected: (v) {
                            setState(() {
                              if (v) {
                                _selectedRoles.add(role.code);
                              } else {
                                _selectedRoles.remove(role.code);
                              }
                            });
                          },
                          label: Text(role.name),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: UtenButton(
                  size: UtenButtonSize.small,
                  isLoading: _saving,
                  onPressed: _selectedDepts.isEmpty ? null : _saveAll,
                  child: Text(
                    _selectedDepts.isEmpty
                        ? '批量保存部门角色'
                        : '批量保存（${_selectedDepts.length} 个部门）',
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
