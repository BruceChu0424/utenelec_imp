// 员工档案列表页（真实后端 + 组件库）
//
// 2026-09-10 交互改版：删顶部状态 FilterChip——状态筛选交给表头 autofilter（前端
// 聚合裁剪），列表不再按状态预筛服务端（离职员工默认可见、可从表头筛掉）；搜索框
// 移入表格工具条「全屏」按钮右侧（toolbarLeadingActions 限宽 260，全屏内同款可用，
// 控制器页面持有两处共享）；「加载更多」按钮下线，改滚动临近底部自动加载下一页
//（onLoadMore + loadingMore 末尾转圈行）；工号/入职日期/工龄三列可排序（表头菜单，
// 服务端 sort/order 白名单；工龄映射 hire_date 且方向翻转）。表头筛选（部门/状态/
// 岗位）仍从已加载 items 前端聚合、前端裁剪显示行。行双击或右键菜单进员工详情。
// 不开多选。
//
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）；
// 窄屏表格横向滚动即可。
// 文档：docs/03-页面/员工列表页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/employee_api_models.dart';
import '../models/work_years.dart';
import '../repositories/employee_repository.dart';
import '../widgets/employee_leadership_badge.dart';
import '../widgets/employee_status_badge.dart';

class EmployeeListPage extends ConsumerStatefulWidget {
  const EmployeeListPage({super.key});

  @override
  ConsumerState<EmployeeListPage> createState() => _EmployeeListPageState();
}

class _EmployeeListPageState extends ConsumerState<EmployeeListPage> {
  String _search = '';

  /// 搜索框控制器：正常态与全屏路由两处 UtenSearchBar 共享（同时只挂一棵树），
  /// 进出全屏不丢已输入的关键字。
  late final TextEditingController _searchCtrl;
  final List<EmployeeSummary> _items = [];
  int _page = 1;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _request = 0;

  /// 表头筛选（部门/状态/岗位）：bucket 从已加载 items 前端聚合，前端裁剪显示行
  ///（搜索与排序仍走服务端；表头筛选属展示层能力）。
  Map<String, String?> _filters = {};

  /// 服务端排序：列 key（code / hireDate / workYears，白名单见后端
  /// EmployeeListQuery#orderBy）；null = 默认「负责人优先 + 工号」。
  String? _sortColumn;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final request = ++_request;
    final search = _search;
    setState(() {
      _loading = true;
      _error = null;
      _loadingMore = false;
      _page = 1;
    });
    try {
      final r = await ref
          .read(employeeRepositoryProvider)
          .list(
            search: search.isEmpty ? null : search,
            sort: _sortColumn,
            order: _sortColumn == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || request != _request) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _page = r.page;
        _totalPages = r.totalPages;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || request != _request) return;
      _failReload(e.message);
    } catch (_) {
      if (!mounted || request != _request) return;
      _failReload(AppLocalizations.of(context).employeeOnboardLoadFailed);
    }
  }

  /// 刷新失败：已无数据 → 错误态占位；仍持旧数据 → 就地提示、保留旧表可继续操作。
  void _failReload(String message) {
    if (_items.isEmpty) {
      setState(() {
        _error = message;
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
      context.appError(message);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _totalPages) return;
    final request = ++_request;
    final search = _search;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final r = await ref
          .read(employeeRepositoryProvider)
          .list(
            page: nextPage,
            search: search.isEmpty ? null : search,
            sort: _sortColumn,
            order: _sortColumn == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || request != _request) return;
      setState(() {
        _items.addAll(r.items);
        _page = r.page;
        _totalPages = r.totalPages;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() => _loadingMore = false);
      if (error is ApiException) {
        context.appError(error.message);
      } else {
        context.appError('加载更多员工失败，请稍后重试');
      }
    }
  }

  /// 表头排序菜单：(null, _) 取消排序回到服务端默认顺序。
  void _onSortChange(String? column, bool ascending) {
    if (column == null) {
      if (_sortColumn == null) return;
      setState(() => _sortColumn = null);
      _reload();
      return;
    }
    if (column == _sortColumn && ascending == _sortAsc) return;
    setState(() {
      _sortColumn = column;
      _sortAsc = ascending;
    });
    _reload();
  }

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key); // 选「所有」= 不筛
      } else {
        next[key] = value;
      }
      _filters = next;
    });
  }

  /// 表头筛选裁剪已加载行（空值行在选了任何值时被滤掉）。
  List<EmployeeSummary> get _visibleItems {
    if (_filters.values.every((v) => v == null || v.isEmpty)) return _items;
    final l10n = AppLocalizations.of(context);
    final dept = _filters['departmentName'];
    final status = _filters['status'];
    final position = _filters['positionName'];
    return _items.where((e) {
      final deptOk =
          dept == null || dept.isEmpty || (e.departmentName ?? '') == dept;
      final statusOk =
          status == null ||
          status.isEmpty ||
          (e.status != null && _statusLabel(l10n, e.status!) == status);
      final positionOk =
          position == null ||
          position.isEmpty ||
          (e.positionName ?? '') == position;
      return deptOk && statusOk && positionOk;
    }).toList();
  }

  /// 部门/状态/岗位三列的筛选桶：已加载 items 聚合（空值不进桶）。
  Map<String, List<MasterFacetBucket>> _facetsOf(AppLocalizations l10n) {
    List<MasterFacetBucket> bucketsOf(Iterable<String> texts) {
      final counts = <String, int>{};
      for (final text in texts) {
        if (text.isEmpty) continue;
        counts[text] = (counts[text] ?? 0) + 1;
      }
      final entries = counts.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return [
        for (final entry in entries)
          MasterFacetBucket(value: entry.key, count: entry.value),
      ];
    }

    return {
      'departmentName': bucketsOf(_items.map((e) => e.departmentName ?? '')),
      'status': bucketsOf([
        for (final e in _items)
          if (e.status != null) _statusLabel(l10n, e.status!),
      ]),
      'positionName': bucketsOf(_items.map((e) => e.positionName ?? '')),
    };
  }

  /// 双击行 / 右键「查看员工档案」：进详情，返回后刷新列表。
  Future<void> _openDetail(EmployeeSummary e) async {
    await context.push('/employee/${e.id}');
    if (!mounted) return;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canCreate =
        permissions.contains(Perm.employeeCreate) &&
        permissions.contains(Perm.employeePiiEdit);

    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    Widget body = _body();
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(title: l10n.employeeTitle, showBackButton: true),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.person_add_rounded),
              label: Text(l10n.employeeFabOnboard),
              onPressed: () async {
                await context.push('/employee/onboarding');
                _reload();
              },
            )
          : null,
      body: body,
    );
  }

  String _statusLabel(AppLocalizations l10n, String key) => switch (key) {
    'active' => l10n.employeeStatusActive,
    'probation' => l10n.employeeStatusProbation,
    'onLeave' => l10n.employeeStatusOnLeave,
    'resigned' => l10n.employeeStatusResigned,
    _ => key,
  };

  Widget _body() {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s12),
      child: MasterDataTableView<EmployeeSummary>(
        key: const Key('employee-list-table'),
        columns: _columns(l10n),
        items: _visibleItems,
        facets: _facetsOf(l10n),
        nullCounts: const {},
        filters: _filters,
        onFilterChanged: _onFilterChanged,
        // 双击行进入员工详情；右键/长按菜单同入口。
        onRowTap: _openDetail,
        rowMenuBuilder: (e) => [
          UtenMenuItem(
            label: '查看员工档案',
            icon: Icons.open_in_new_rounded,
            onTap: () => _openDetail(e),
          ),
        ],
        sortColumn: _sortColumn,
        sortAscending: _sortAsc,
        onSortChange: _onSortChange,
        // 加载/错误/空态交给表格自身：刷新时若仍持旧数据则表格原地保留
        //（工具条里的搜索框不卸载、焦点不丢），仅无数据时才显示占位。
        isLoading: _loading,
        error: _error,
        onRetry: _reload,
        emptyMessage: l10n.employeeEmpty,
        // 滚动临近底部自动追加下一页（末尾转圈行）；是否还有更多由 _loadMore 守卫。
        loadingMore: _loadingMore,
        onLoadMore: _loadMore,
        // 搜索框：紧跟「全屏」按钮右侧（toolbarLeadingActions 左簇），限宽 260；
        // UtenSearchBar 自带 300ms 防抖 + 清除按钮，全屏路由里同款渲染。
        toolbarLeadingActions: [
          SizedBox(
            width: 260,
            child: UtenSearchBar(
              controller: _searchCtrl,
              hint: l10n.employeeSearchHint,
              onChanged: (v) {
                final t = v.trim();
                if (t != _search) {
                  _search = t;
                  _reload();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  List<MasterColumnDef<EmployeeSummary>> _columns(AppLocalizations l10n) => [
    MasterColumnDef(
      key: 'code',
      label: '工号',
      width: 90,
      sortable: true,
      value: (e) => e.code,
    ),
    MasterColumnDef(
      key: 'fullName',
      label: '姓名',
      width: 150,
      value: (e) => e.fullName,
      cellBuilder: (context, e) => Row(
        children: [
          EmployeeLeadershipBadge(
            departmentManager: e.departmentManager,
            positionLevel: e.positionLevel,
            leaderRank: e.leaderRank,
          ),
          const SizedBox(width: UtenSpacing.s4),
          Flexible(child: Text(e.fullName)),
        ],
      ),
    ),
    MasterColumnDef(
      key: 'departmentName',
      label: '部门',
      width: 150,
      value: (e) => e.departmentName,
    ),
    MasterColumnDef(
      key: 'positionName',
      label: '岗位',
      width: 140,
      value: (e) => e.positionName,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (e) => e.status == null ? null : _statusLabel(l10n, e.status!),
      cellBuilder: (context, e) => EmployeeStatusBadge(status: e.status),
    ),
    MasterColumnDef(
      key: 'hireDate',
      label: '入职日期',
      width: 110,
      type: 'date',
      sortable: true,
      value: (e) => e.hireDate,
    ),
    MasterColumnDef(
      key: 'workYears',
      label: '工龄',
      width: 110,
      sortable: true,
      info: '按入职日期 + 当前日期动态计算（整年 + 整月），不落库。',
      value: (e) => workYearsText(l10n, e.hireDate),
    ),
    // ADR-021：搜索命中车牌时显示（谁的车有问题 → 按车牌秒查人）。
    MasterColumnDef(
      key: 'matchedPlates',
      label: '车牌命中',
      width: 130,
      info: '仅搜索词命中车牌时显示对应车牌；平时为空。',
      value: (e) => e.matchedPlates,
    ),
  ];
}
