// AdminPermissionsPage - 账号支持与权限管理。
//
// account:support 可执行账号锁定/启停/重置密码。
// authorization:manage + superAdmin 才显示个人/部门授权与数据范围。
// 顶部说明条 + 超管可见的分段切换「按员工 | 按部门」。
// 按员工：主从布局（expanded 左列表右详情；compact 列表 → 详情带返回）。
// 按部门：单选部门 + 从完整权限目录勾选权限点（见 widgets/admin_department_perm_view.dart）。
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 路由守卫与工作台显隐共用 permission_by_path.dart。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';
import '../widgets/admin_department_perm_view.dart';
import '../widgets/admin_user_detail_panel.dart';

class AdminPermissionsPage extends ConsumerStatefulWidget {
  const AdminPermissionsPage({super.key});

  @override
  ConsumerState<AdminPermissionsPage> createState() =>
      _AdminPermissionsPageState();
}

class _AdminPermissionsPageState extends ConsumerState<AdminPermissionsPage> {
  /// 0=按员工，1=按部门
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canManageAuthorization =
        ref.watch(isSuperAdminProvider) &&
        permissions.contains(Perm.authorizationManage);
    final segment = canManageAuthorization ? _segment : 0;

    Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部说明条
        UtenCard(
          margin: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s8,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s16,
            vertical: UtenSpacing.s12,
          ),
          child: Row(
            children: [
              Icon(
                Icons.admin_panel_settings_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Text(
                  canManageAuthorization
                      ? '账号与权限管理 · 账号操作、个人权限、数据范围和部门权限均以后端实时授权为准。'
                      : '账号支持 · 可锁定、启停账号或重置一次性临时密码；不展示任何授权配置。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 分段切换
        if (canManageAuthorization)
          Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: UtenSegmentedFilter<int>(
              segments: const [
                UtenSegment(value: 0, label: '按员工'),
                UtenSegment(value: 1, label: '按部门'),
              ],
              selected: segment,
              onChanged: (v) => setState(() => _segment = v),
            ),
          ),
        Expanded(
          child: IndexedStack(
            index: segment,
            children: [
              _EmployeePermTab(canManageAuthorization: canManageAuthorization),
              if (canManageAuthorization) const AdminDepartmentPermView(),
            ],
          ),
        ),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    // 统一顶栏：左上角全局返回键（UtenBackButton），AppBar 自带顶部安全区
    return Scaffold(
      appBar: UtenAppBar(
        title: canManageAuthorization ? '账号与权限管理' : '账号支持',
        showBackButton: true,
      ),
      body: body,
    );
  }
}

/// 按员工：账号列表（搜索/状态筛选/加载更多）+ 详情面板（主从布局）。
class _EmployeePermTab extends ConsumerStatefulWidget {
  const _EmployeePermTab({required this.canManageAuthorization});

  final bool canManageAuthorization;

  @override
  ConsumerState<_EmployeePermTab> createState() => _EmployeePermTabState();
}

class _EmployeePermTabState extends ConsumerState<_EmployeePermTab> {
  static const _statusKeys = ['active', 'locked', 'disabled'];

  String _search = '';
  String? _statusFilter; // null = 全部
  final List<AdminUserSummary> _items = [];
  int _page = 1;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  AdminUserSummary? _selected;
  bool _showDetail = false; // compact 下是否进入详情视图

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _page = 1;
    try {
      final r = await ref
          .read(adminRepositoryProvider)
          .listUsers(search: _search.isEmpty ? null : _search);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _totalPages = r.totalPages;
        _loading = false;
        // 列表刷新后同步选中项（状态/角色可能已变更）
        final sel = _selected;
        if (sel != null) {
          AdminUserSummary? found;
          for (final e in r.items) {
            if (e.id == sel.id) {
              found = e;
              break;
            }
          }
          _selected = found;
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败，请稍后重试';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _totalPages) return;
    setState(() => _loadingMore = true);
    try {
      final r = await ref
          .read(adminRepositoryProvider)
          .listUsers(page: _page + 1, search: _search.isEmpty ? null : _search);
      if (!mounted) return;
      setState(() {
        _items.addAll(r.items);
        _page = _page + 1;
        _totalPages = r.totalPages;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _onUserTap(AdminUserSummary u) {
    setState(() {
      _selected = u;
      _showDetail = true;
    });
  }

  /// 详情面板完成账号操作后回调：刷新列表并同步选中项。
  void _onAccountChanged() => _reload();

  @override
  Widget build(BuildContext context) {
    final isExpanded = context.breakpoint.atLeastMedium;
    if (isExpanded) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 340, child: _listColumn()),
          const VerticalDivider(width: 1),
          Expanded(child: _detailArea(showBack: false)),
        ],
      );
    }
    // compact：列表 ↔ 详情 切换
    return _showDetail && _selected != null
        ? _detailArea(showBack: true)
        : _listColumn();
  }

  Widget _detailArea({required bool showBack}) {
    final theme = Theme.of(context);
    final u = _selected;
    if (u == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_search_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '从左侧选择一名员工查看权限详情',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return AdminUserDetailPanel(
      key: ValueKey(u.id),
      user: u,
      canManageAuthorization: widget.canManageAuthorization,
      showBack: showBack,
      onBack: () => setState(() => _showDetail = false),
      onAccountChanged: _onAccountChanged,
    );
  }

  Widget _listColumn() {
    return Column(
      children: [
        // 搜索框（按登录账号搜）：UtenSearchBar 自带 300ms 防抖 + 清除按钮
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s4,
            bottom: UtenSpacing.s8,
          ),
          child: UtenSearchBar(
            hint: '搜索登录账号',
            onChanged: (v) {
              final t = v.trim();
              if (t != _search) {
                _search = t;
                _reload();
              }
            },
          ),
        ),
        // 状态筛选（单选：全部/正常/锁定/停用）
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
                child: ChoiceChip(
                  label: const Text('全部'),
                  selected: _statusFilter == null,
                  onSelected: (_) {
                    setState(() => _statusFilter = null);
                  },
                ),
              ),
              for (final key in _statusKeys)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s4,
                  ),
                  child: ChoiceChip(
                    label: Text(accountStatusLabel(key)),
                    selected: _statusFilter == key,
                    onSelected: (_) {
                      setState(
                        () => _statusFilter = _statusFilter == key ? null : key,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Expanded(child: _listBody()),
      ],
    );
  }

  Widget _listBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _reload,
      );
    }
    // 状态筛选在前端本地过滤（后端列表接口不支持 status 参数）
    final visible = _statusFilter == null
        ? _items
        : _items.where((e) => e.status == _statusFilter).toList();
    if (visible.isEmpty) {
      return const UtenEmpty(
        icon: Icons.people_outline_rounded,
        message: '暂无匹配的员工账号',
      );
    }
    return ListView.builder(
      itemCount: visible.length + 1,
      itemBuilder: (context, i) {
        if (i == visible.length) {
          if (_statusFilter == null && _page < _totalPages) {
            return Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Center(
                child: _loadingMore
                    ? const CircularProgressIndicator()
                    : FilledButton.tonal(
                        onPressed: _loadMore,
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }
          return const SizedBox(height: UtenSpacing.s24);
        }
        final u = visible[i];
        return UtenCard(
          margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s12,
          ),
          onTap: () => _onUserTap(u),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                child: Text(
                  (u.employeeName ?? u.loginAccount)
                      .substring(0, 1)
                      .toUpperCase(),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      u.employeeName ?? u.loginAccount,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '${u.loginAccount}'
                      '${u.departmentName != null ? ' · ${u.departmentName}' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              AccountStatusBadge(status: u.status),
            ],
          ),
        );
      },
    );
  }
}

/// 账号状态 → 中文标签。
String accountStatusLabel(String status) => switch (status) {
  'active' => '正常',
  'locked' => '锁定',
  'disabled' => '停用',
  _ => status,
};

/// 账号状态徽章（active=绿 / locked=黄 / disabled=灰）。
class AccountStatusBadge extends StatelessWidget {
  const AccountStatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final type = switch (status) {
      'active' => UtenStatusBadgeType.success,
      'locked' => UtenStatusBadgeType.warning,
      'disabled' => UtenStatusBadgeType.neutral,
      _ => UtenStatusBadgeType.neutral,
    };
    return UtenStatusBadge(
      label: accountStatusLabel(status),
      type: type,
      size: UtenStatusBadgeSize.small,
    );
  }
}
