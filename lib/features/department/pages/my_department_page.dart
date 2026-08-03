// MyDepartmentPage - 我的部门（全页面，镜像「部门管理」页布局）
// 文档：docs/03-页面/我的页.md（§我的部门）
//
// 布局复用部门管理页（/department）：
//   expanded：全高分栏 左树(300) | 分隔线 | 右详情
//   compact/medium：组织树进 endDrawer，详情单列（UtenContentContainer 收敛宽度）
// 组件复用：UtenDepartmentTreeView + MasterDetailCard + UtenPersonCard（与部门管理页同款）。
//
// 数据仍走 /api/my-department/**（任意员工可见，无 department:view/employee:view）：
//   部门管理页的 DepartmentOverviewPane 调的是 department:view/employee:view 接口，
//   普通员工 403；故此处复用「布局与组件」但保留 my-department 安全花名册数据源。
// 花名册：负责人/管理人排最前；安全 8 字段；部门负责人额外见权限转授面板（仅本人管理的部门）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_person_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../../employee/widgets/employee_leadership_badge.dart';
import '../models/department_node.dart';
import '../models/my_department.dart';
import '../providers/my_department_providers.dart';
import '../repositories/my_department_repository.dart';
import '../widgets/uten_department_tree_view.dart';

class MyDepartmentPage extends ConsumerStatefulWidget {
  const MyDepartmentPage({super.key});

  @override
  ConsumerState<MyDepartmentPage> createState() => _MyDepartmentPageState();
}

class _MyDepartmentPageState extends ConsumerState<MyDepartmentPage> {
  String? _selectedId;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final useSplit = context.breakpoint.isExpanded;
    final treeAsync = ref.watch(myDepartmentTreeProvider);
    final tree = treeAsync.valueOrNull ?? const <DepartmentNode>[];
    final selectedId = tree.isNotEmpty ? (_selectedId ?? tree.first.id) : null;

    final Widget body = treeAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => UtenEmpty.error(
        message: e is ApiException ? e.message : '部门信息加载失败',
        actionLabel: '重试',
        onAction: () => ref.invalidate(myDepartmentTreeProvider),
      ),
      data: (_) {
        final node = selectedId == null
            ? tree.first
            : (_findNode(tree, selectedId) ?? tree.first);
        // 路径：根 › … › 当前（仅多于一层时展示，避免与标题重复）。
        final chain = _nameChain(tree, node.id);
        final path = chain.length > 1 ? chain.join(' › ') : null;
        final detail = _MyDepartmentDetail(node: node, path: path);

        if (useSplit) {
          return Row(
            children: [
              SizedBox(
                width: 300,
                child: _buildTree(
                  tree,
                  node.id,
                  onSelect: (id) => setState(() => _selectedId = id),
                ),
              ),
              Container(width: 1, color: theme.colorScheme.outlineVariant),
              Expanded(child: detail),
            ],
          );
        }
        // compact/medium：树进抽屉，详情单列收敛宽度。
        return UtenContentContainer(child: detail);
      },
    );

    return Scaffold(
      key: _scaffoldKey,
      appBar: UtenAppBar(
        title: '我的部门',
        // go 进入（主 Tab 前缀子路由），栈被替换；返回显式回「我的」页
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.profile),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => ref.invalidate(myDepartmentTreeProvider),
          ),
          if (!useSplit && selectedId != null)
            IconButton(
              icon: const Icon(Icons.account_tree_rounded),
              tooltip: '部门列表',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
        ],
      ),
      endDrawer: (!useSplit && selectedId != null)
          ? Drawer(
              child: SafeArea(
                child: _buildTree(
                  tree,
                  selectedId,
                  onSelect: (id) {
                    setState(() => _selectedId = id);
                    Navigator.of(context).pop();
                  },
                ),
              ),
            )
          : null,
      body: SafeArea(child: body),
    );
  }

  /// 组织树（复用 UtenDepartmentTreeView，内置搜索）。onSelect：分栏只切选中；抽屉额外关抽屉。
  Widget _buildTree(
    List<DepartmentNode> tree,
    String selectedId, {
    required ValueChanged<String> onSelect,
  }) {
    return UtenDepartmentTreeView(
      nodes: tree,
      selectedIds: {selectedId},
      onNodeTap: (n) => onSelect(n.id),
      nodeEnabledPredicate: (_) => true,
      expandOnRowTap: true,
      initiallyExpandDepth: 2,
    );
  }
}

/// 右侧详情：MasterDetailCard（部门概况，只读）+ 安全花名册（负责人排最前）
/// + 部门负责人权限转授面板（仅当当前部门正是本人管理的部门时显示）。
class _MyDepartmentDetail extends ConsumerWidget {
  const _MyDepartmentDetail({required this.node, this.path});

  final DepartmentNode node;
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(myDepartmentRosterProvider(node.id));
    // 仅本人管理的部门才展示权限转授面板（非负责人 403 → 隐藏）。
    final isManaged = ref.watch(managedStaffPermissionsProvider).maybeWhen(
      data: (m) => m.departmentId == node.id,
      orElse: () => false,
    );
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    final directCount = async.maybeWhen(
      data: (r) => r.staff.length,
      orElse: () => null,
    );

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            hPad,
            UtenSpacing.s16,
            hPad,
            UtenSpacing.s12,
          ),
          sliver: SliverToBoxAdapter(
            child: MasterDetailCard(
              title: node.name,
              icon: Icons.account_tree_outlined,
              subtitle: '${node.level} · ${node.code}',
              stats: [
                MasterDetailStat('直属在册', directCount?.toString()),
                MasterDetailStat('子部门', '${node.children.length}'),
                MasterDetailStat('负责人', node.managerName),
                MasterDetailStat('编制', node.headcount?.toString()),
              ],
              path: path,
              canEdit: false, // 我的部门只读：编辑/删除/新增子部门按钮不渲染
              onAddChild: () {},
              onEdit: () {},
              onDelete: () {},
            ),
          ),
        ),
        ..._rosterSlivers(async, theme, hPad, ref),
        if (isManaged)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              hPad,
              UtenSpacing.s4,
              hPad,
              UtenSpacing.s16,
            ),
            sliver: const SliverToBoxAdapter(child: _ManagerPermissionPanel()),
          ),
      ],
    );
  }

  List<Widget> _rosterSlivers(
    AsyncValue<MyDepartmentRoster> async,
    ThemeData theme,
    double hPad,
    WidgetRef ref,
  ) {
    EdgeInsets pad({double bottom = UtenSpacing.s16}) =>
        EdgeInsets.fromLTRB(hPad, 0, hPad, bottom);
    return async.when(
      loading: () => [
        SliverPadding(
          padding: pad(),
          sliver: const SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
      ],
      error: (e, _) => [
        SliverPadding(
          padding: pad(),
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: UtenEmpty.error(
                message: e is ApiException ? e.message : '花名册加载失败',
                actionLabel: '重试',
                onAction: () =>
                    ref.invalidate(myDepartmentRosterProvider(node.id)),
              ),
            ),
          ),
        ),
      ],
      data: (roster) {
        // 负责人/管理人排最前（稳定：保留服务端顺序，仅前置 departmentManager）。
        final managers = roster.staff.where((s) => s.departmentManager).toList();
        final others = roster.staff.where((s) => !s.departmentManager).toList();
        final ordered = [...managers, ...others];
        if (ordered.isEmpty) {
          return [
            SliverPadding(
              padding: pad(),
              sliver: const SliverToBoxAdapter(
                child: SizedBox(
                  height: 160,
                  child: UtenEmpty(
                    icon: Icons.people_outline_rounded,
                    message: '该部门暂无在册员工',
                  ),
                ),
              ),
            ),
          ];
        }
        return [
          SliverPadding(
            padding: pad(bottom: UtenSpacing.s8),
            sliver: SliverToBoxAdapter(child: _rosterHeader(theme, ordered.length)),
          ),
          SliverPadding(
            padding: pad(),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _staffRow(theme, ordered[i]),
                childCount: ordered.length,
              ),
            ),
          ),
        ];
      },
    );
  }

  Widget _rosterHeader(ThemeData theme, int count) {
    return Row(
      children: [
        Icon(
          Icons.people_outline_rounded,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Text(
          '在册员工 $count 人',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _staffRow(ThemeData theme, MyDepartmentStaffRow r) {
    final parts = <String>[
      if (r.code != null && r.code!.isNotEmpty) r.code!,
      if (r.positionName != null && r.positionName!.isNotEmpty)
        r.positionName!,
      if (r.officePhone != null && r.officePhone!.isNotEmpty)
        '电话 ${r.officePhone}',
      if (r.email != null && r.email!.isNotEmpty) r.email!,
    ];
    return UtenPersonCard(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
      title: r.fullName ?? '—',
      subtitle: parts.isEmpty ? null : parts.join(' · '),
      titleLeading: r.departmentManager
          ? const EmployeeLeadershipBadge(departmentManager: true)
          : null,
      avatarText: r.fullName,
      trailing: r.isSelf ? _selfBadge(theme) : null,
    );
  }

  Widget _selfBadge(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 2,
      ),
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

/// 根 → … → 目标 的名称链（用于详情卡「路径」）。
List<String> _nameChain(List<DepartmentNode> nodes, String id) {
  for (final n in nodes) {
    if (n.id == id) return [n.name];
    final sub = _nameChain(n.children, id);
    if (sub.isNotEmpty) return [n.name, ...sub];
  }
  return const [];
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
