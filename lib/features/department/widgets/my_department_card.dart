// 工作台「我的部门」卡片：展示本部门（大部门分支）架构树 + 花名册（安全字段），
// 大屏左右分屏、小屏弹窗选部门；普通员工只读；部门负责人额外可对本部门成员做权限开/关。
// 后端 /api/my-department/** 与 /api/department-staff-permissions/** 已就绪（问题 #20）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/cards/uten_person_card.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/widgets/employee_leadership_badge.dart';
import '../models/department_node.dart';
import '../models/my_department.dart';
import '../providers/my_department_providers.dart';
import '../repositories/my_department_repository.dart';
import 'uten_department_tree_view.dart';

class MyDepartmentCard extends ConsumerStatefulWidget {
  const MyDepartmentCard({super.key});

  @override
  ConsumerState<MyDepartmentCard> createState() => _MyDepartmentCardState();
}

class _MyDepartmentCardState extends ConsumerState<MyDepartmentCard> {
  String? _selectedId;
  bool _expanded = true;

  void _select(String id) => setState(() => _selectedId = id);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final treeAsync = ref.watch(myDepartmentTreeProvider);
    return UtenCard(
      margin: EdgeInsets.zero,
      child: treeAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: UtenSpacing.s32),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => _InlineError(
          message: e is ApiException ? e.message : '部门信息加载失败',
          onRetry: () => ref.invalidate(myDepartmentTreeProvider),
        ),
        data: (tree) {
          if (tree.isEmpty) return const SizedBox.shrink();
          final selectedId = _selectedId ?? tree.first.id;
          final selectedNode = _findNode(tree, selectedId) ?? tree.first;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(theme, tree.first.name),
              if (_expanded) ...[
                const SizedBox(height: UtenSpacing.s12),
                _treeAndRoster(theme, tree, selectedNode),
                const SizedBox(height: UtenSpacing.s16),
                const _ManagerPermissionPanel(),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _header(ThemeData theme, String branchName) {
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Icon(
              Icons.account_tree_rounded,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '我的部门',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  branchName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            _expanded
                ? Icons.expand_less_rounded
                : Icons.expand_more_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _treeAndRoster(
    ThemeData theme,
    List<DepartmentNode> tree,
    DepartmentNode selected,
  ) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 720) {
          // 大屏：左右分屏（树 | 花名册）；固定高度，内部各自滚动（避免随人数无限增高）。
          return SizedBox(
            height: 380,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 280,
                  child: _tree(tree, selected.id),
                ),
                const SizedBox(width: UtenSpacing.s4),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s4,
                  ),
                  color: theme.colorScheme.outlineVariant,
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: _roster(selected.id)),
              ],
            ),
          );
        }
        // 小屏：选部门按钮（弹窗） + 花名册。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _compactSelector(theme, selected),
            const SizedBox(height: UtenSpacing.s8),
            SizedBox(
              height: 340,
              child: _roster(selected.id),
            ),
          ],
        );
      },
    );
  }

  Widget _compactSelector(ThemeData theme, DepartmentNode selected) {
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: () => _showTreePopup(selected.id),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              Icons.corporate_fare_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                selected.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.unfold_more_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  void _showTreePopup(String selectedId) {
    final tree = ref.read(myDepartmentTreeProvider).valueOrNull ?? const [];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s12,
            UtenSpacing.s8,
            UtenSpacing.s12,
            UtenSpacing.s16,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    '选择部门',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Expanded(
                child: _tree(tree, selectedId, showSearch: true, popOnTap: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tree(
    List<DepartmentNode> tree,
    String selectedId, {
    bool showSearch = false,
    bool popOnTap = false,
  }) {
    return UtenDepartmentTreeView(
      nodes: tree,
      selectedIds: {selectedId},
      onNodeTap: (n) {
        _select(n.id);
        if (popOnTap && mounted) Navigator.of(context).pop();
      },
      nodeEnabledPredicate: (_) => true,
      showSearch: showSearch,
      expandOnRowTap: true,
      initiallyExpandDepth: 2,
    );
  }

  Widget _roster(String deptId) {
    final theme = Theme.of(context);
    final async = ref.watch(myDepartmentRosterProvider(deptId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _InlineError(
        message: e is ApiException ? e.message : '花名册加载失败',
        onRetry: () => ref.invalidate(myDepartmentRosterProvider(deptId)),
      ),
      data: (roster) {
        if (roster.staff.isEmpty) {
          return Center(
            child: Text(
              '该部门暂无在册员工',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: roster.staff.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) => _staffRow(roster.staff[i]),
        );
      },
    );
  }

  Widget _staffRow(MyDepartmentStaffRow r) {
    final parts = <String>[
      if (r.code != null && r.code!.isNotEmpty) r.code!,
      if (r.positionName != null && r.positionName!.isNotEmpty)
        r.positionName!,
      if (r.officePhone != null && r.officePhone!.isNotEmpty)
        '电话 ${r.officePhone}',
      if (r.email != null && r.email!.isNotEmpty) r.email!,
    ];
    return UtenPersonCard(
      title: r.fullName ?? '—',
      subtitle: parts.isEmpty ? null : parts.join(' · '),
      titleLeading: r.departmentManager
          ? const EmployeeLeadershipBadge(departmentManager: true)
          : null,
      avatarText: r.fullName,
      trailing: r.isSelf ? _selfBadge() : null,
    );
  }

  Widget _selfBadge() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(UtenSpacing.s8),
      ),
      child: Text(
        '我',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 部门负责人的权限面板（非负责人 403 时整体隐藏）。
class _ManagerPermissionPanel extends ConsumerWidget {
  const _ManagerPermissionPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(managedStaffPermissionsProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        // 403 = 非负责人，正常隐藏；其它错误给提示。
        if (e is ApiException && e.code == 'FORBIDDEN') {
          return const SizedBox.shrink();
        }
        return _InlineError(
          message: e is ApiException ? e.message : '权限面板加载失败',
          onRetry: () => ref.invalidate(managedStaffPermissionsProvider),
        );
      },
      data: (data) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: UtenRadius.mdAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      '本部门员工权限（你是「${data.departmentName}」负责人）',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '基线权限默认开启（可关闭），额外权限默认关闭（可授予）。仅本部门负责人可见可改。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (data.staff.isEmpty)
                Text('本部门暂无在册员工', style: theme.textTheme.bodySmall)
              else
                for (final s in data.staff) ...[
                  _StaffPermissionRow(codes: data.permissionCodes, staff: s),
                  const SizedBox(height: UtenSpacing.s8),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _StaffPermissionRow extends ConsumerStatefulWidget {
  const _StaffPermissionRow({required this.codes, required this.staff});

  final List<DepartmentPermissionItem> codes;
  final DepartmentStaffPermissionRow staff;

  @override
  ConsumerState<_StaffPermissionRow> createState() =>
      _StaffPermissionRowState();
}

class _StaffPermissionRowState extends ConsumerState<_StaffPermissionRow> {
  late final Map<String, String> _overrides =
      Map<String, String>.from(widget.staff.overrides);
  final Set<String> _busy = {};

  @override
  void didUpdateWidget(covariant _StaffPermissionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 与服务端最新覆盖同步（保留进行中的乐观改动：_busy 中的 code 不覆盖）。
    final server = widget.staff.overrides;
    setState(() {
      for (final c in {...oldWidget.staff.overrides.keys, ...server.keys}) {
        if (_busy.contains(c)) continue;
        final sv = server[c];
        if (sv == null) {
          _overrides.remove(c);
        } else {
          _overrides[c] = sv;
        }
      }
    });
  }

  bool _effective(DepartmentPermissionItem item) {
    final e = _overrides[item.code];
    if (e == 'revoke') return false;
    if (e == 'grant') return true;
    return item.baseline; // 无覆盖：基线默认 ON，额外默认 OFF
  }

  Future<void> _toggle(DepartmentPermissionItem item, bool value) async {
    // 最小化覆盖：基线 ON→清回(null)、基线 OFF→revoke；额外 ON→grant、额外 OFF→清(null)。
    final String? effect;
    if (value) {
      effect = item.baseline ? null : 'grant';
    } else {
      effect = item.baseline ? 'revoke' : null;
    }
    final code = item.code;
    setState(() {
      _busy.add(code);
      if (effect == null) {
        _overrides.remove(code);
      } else {
        _overrides[code] = effect;
      }
    });
    try {
      await ref
          .read(myDepartmentRepositoryProvider)
          .setOverride(widget.staff.employeeId, code, effect);
      if (mounted) {
        context.appSuccess(
          '已更新「${widget.staff.fullName ?? ''}」的「${item.name}」',
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        _revert(code);
        context.appError(e.message);
      }
    } catch (_) {
      if (mounted) {
        _revert(code);
        context.appError('更新失败，请重试');
      }
    } finally {
      // 成功路径也必须清 busy，否则开关一次性后永久禁用。
      if (mounted) setState(() => _busy.remove(code));
    }
  }

  void _revert(String code) {
    final orig = widget.staff.overrides[code];
    setState(() {
      if (orig == null) {
        _overrides.remove(code);
      } else {
        _overrides[code] = orig;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.staff;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (s.departmentManager) ...[
                const EmployeeLeadershipBadge(departmentManager: true),
                const SizedBox(width: UtenSpacing.s8),
              ],
              Flexible(
                child: Text(
                  '${s.fullName ?? '—'}'
                  '${s.positionName == null ? '' : ' · ${s.positionName}'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (s.code != null && s.code!.isNotEmpty) ...[
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  s.code!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          if (!s.hasAccount)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s4),
              child: Text(
                '未开通登录账号，暂无法授权',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else if (widget.codes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s4),
              child: Text(
                '无可转授的权限点',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else ...[
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s4,
              children: [for (final item in widget.codes) _permSwitch(item)],
            ),
          ],
        ],
      ),
    );
  }

  Widget _permSwitch(DepartmentPermissionItem item) {
    final theme = Theme.of(context);
    final value = _effective(item);
    final busy = _busy.contains(item.code);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          value: value,
          onChanged: busy ? null : (v) => _toggle(item, v),
        ),
        const SizedBox(width: UtenSpacing.s4),
        Text(item.name, style: theme.textTheme.bodySmall),
        if (!item.baseline) ...[
          const SizedBox(width: UtenSpacing.s4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '额外',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10,
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

DepartmentNode? _findNode(List<DepartmentNode> nodes, String id) {
  for (final n in nodes) {
    if (n.id == id) return n;
    final hit = _findNode(n.children, id);
    if (hit != null) return hit;
  }
  return null;
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(message)),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
