import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/models/work_years.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/employee_leadership_badge.dart';
import '../../employee/widgets/employee_status_badge.dart';
import '../models/department_node.dart';
import '../models/workforce_overview.dart';
import '../repositories/department_repository.dart';
import 'department_org_chart_dialog.dart';
import 'department_roster_print.dart';
import 'organization_workforce_overview_card.dart';
import 'position_manager_sheet.dart';

/// 部门管理右侧“在册员工”的统一状态口径。
///
/// 左侧全局员工定位必须复用同一集合，避免定位到右侧不会展示的离职/停用人员。
const currentDepartmentEmployeeStatuses = <String>{
  'active',
  'probation',
  'onLeave',
};

class DepartmentOverviewPane extends ConsumerStatefulWidget {
  const DepartmentOverviewPane({
    super.key,
    required this.node,
    required this.canEdit,
    required this.canAddChild,
    required this.canDelete,
    required this.canViewEmployees,
    required this.canCreateEmployee,
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
    this.employeeFilter,
  });

  final DepartmentNode node;
  final bool canEdit;
  final bool canAddChild;
  final bool canDelete;
  final bool canViewEmployees;
  final bool canCreateEmployee;

  /// 顶部树搜索命中员工时传入的过滤词：面板把它采纳为员工列表的搜索词，
  /// 使右侧只显示本次搜索结果；为 null 时不过滤（显示该部门全部）。
  final String? employeeFilter;
  final VoidCallback onAddChild;
  final void Function(DepartmentInfo detail) onEdit;
  final VoidCallback onDelete;

  @override
  ConsumerState<DepartmentOverviewPane> createState() =>
      _DepartmentOverviewPaneState();
}

class _DepartmentOverviewPaneState
    extends ConsumerState<DepartmentOverviewPane> {
  static const _pageSize = 50;

  DepartmentInfo? _info;
  WorkforceOverview? _overview;
  List<EmployeeSummary> _employees = const [];
  int _employeePage = 1;
  int _employeeTotalPages = 0;
  int _employeeTotal = 0;

  bool _loading = true;
  bool _overviewLoading = false;
  bool _employeesLoading = false;
  bool _employeesLoadingMore = false;
  String? _error;
  String? _overviewError;
  String? _employeesError;
  String _keyword = '';

  /// 表头筛选（部门/岗位/状态）：桶从已加载 items 前端聚合、前端裁剪显示行
  ///（与员工档案列表页同款；搜索与排序仍走服务端）。
  Map<String, String?> _filters = {};

  /// 服务端排序（工号/入职日期/工龄，白名单同员工档案页）；null = 服务端默认。
  String? _sortColumn;
  bool _sortAsc = true;

  // 搜索框重建种子：外部过滤词（树搜索）变化时自增，驱动 UtenSearchBar 用新 initialValue 重建。
  int _kwSeed = 0;

  int _scopeVersion = 0;
  int _employeeRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DepartmentOverviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id != widget.node.id) {
      _load();
      return;
    }
    // 同一部门但树对象被整体重拉（编辑部门/增删子部门/手动刷新后 _tree 换新）：
    // 详情卡（名称/编号/负责人）可能已变，必须重载，否则停在编辑前的旧数据。
    if (!identical(oldWidget.node, widget.node)) {
      _load();
      return;
    }
    // 同一部门下外部过滤词变化（树搜索命中/解除）：采纳为本地关键词并重查员工列表。
    if (oldWidget.employeeFilter != widget.employeeFilter) {
      setState(() {
        _kwSeed++;
        _keyword = widget.employeeFilter ?? '';
      });
      _reloadEmployees();
      return;
    }
    if (!oldWidget.canViewEmployees && widget.canViewEmployees) {
      final scope = _scopeVersion;
      unawaited(_loadOverview(scope));
      unawaited(_reloadEmployees(scope: scope));
    } else if (oldWidget.canViewEmployees && !widget.canViewEmployees) {
      _employeeRequest++;
      setState(() {
        _overview = null;
        _overviewError = null;
        _employees = const [];
        _employeeTotal = 0;
      });
    }
  }

  Future<void> _load() async {
    final scope = ++_scopeVersion;
    _employeeRequest++;
    setState(() {
      _loading = true;
      _error = null;
      // 外部过滤词（树搜索命中）随部门切换一并带入：搜索定位时右侧只显示搜索结果。
      _keyword = widget.employeeFilter ?? '';
      _kwSeed++;
      _info = null;
      _overview = null;
      _overviewError = null;
      _employees = const [];
      _employeeTotal = 0;
      _employeesError = null;
      // 换部门后表头筛选口径随之变化，一并复位（搜索/排序口径保留由各自交互管理）。
      _filters = {};
    });
    try {
      final info = await ref
          .read(departmentRepositoryProvider)
          .detail(widget.node.id);
      if (!mounted || scope != _scopeVersion) return;
      setState(() {
        _info = info;
        _loading = false;
      });
      if (widget.canViewEmployees) {
        unawaited(_loadOverview(scope));
        unawaited(_reloadEmployees(scope: scope));
      }
    } on ApiException catch (e) {
      if (!mounted || scope != _scopeVersion) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || scope != _scopeVersion) return;
      setState(() {
        _error = AppLocalizations.of(context).departmentLoadFailed;
        _loading = false;
      });
    }
  }

  Future<void> _loadOverview([int? requestedScope]) async {
    final scope = requestedScope ?? _scopeVersion;
    setState(() {
      _overviewLoading = true;
      _overviewError = null;
    });
    try {
      final overview = await ref
          .read(departmentRepositoryProvider)
          .workforceOverview(widget.node.id);
      if (!mounted || scope != _scopeVersion) return;
      setState(() {
        _overview = overview;
        _overviewLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || scope != _scopeVersion) return;
      setState(() {
        _overviewError = e.message;
        _overviewLoading = false;
      });
    } catch (_) {
      if (!mounted || scope != _scopeVersion) return;
      setState(() {
        _overviewError = '人员统计加载失败，请稍后重试';
        _overviewLoading = false;
      });
    }
  }

  Future<void> _reloadEmployees({int? scope}) async {
    if (!widget.canViewEmployees) return;
    final targetScope = scope ?? _scopeVersion;
    final request = ++_employeeRequest;
    setState(() {
      _employeesLoading = true;
      _employeesError = null;
      _employeesLoadingMore = false;
      _employees = const [];
      _employeePage = 1;
      _employeeTotal = 0;
      _employeeTotalPages = 0;
    });
    try {
      final result = await ref
          .read(employeeRepositoryProvider)
          .list(
            size: _pageSize,
            departmentId: widget.node.id,
            includeSubtree: true,
            statuses: currentDepartmentEmployeeStatuses,
            search: _keyword.trim().isEmpty ? null : _keyword.trim(),
            sort: _sortColumn,
            order: _sortColumn == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted ||
          targetScope != _scopeVersion ||
          request != _employeeRequest) {
        return;
      }
      setState(() {
        _employees = result.items;
        _employeePage = result.page;
        _employeeTotal = result.total;
        _employeeTotalPages = result.totalPages;
        _employeesLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted ||
          targetScope != _scopeVersion ||
          request != _employeeRequest) {
        return;
      }
      setState(() {
        _employeesError = e.message;
        _employeesLoading = false;
      });
    } catch (_) {
      if (!mounted ||
          targetScope != _scopeVersion ||
          request != _employeeRequest) {
        return;
      }
      setState(() {
        _employeesError = '员工列表加载失败，请稍后重试';
        _employeesLoading = false;
      });
    }
  }

  Future<void> _loadMoreEmployees() async {
    if (_employeesLoadingMore || _employeePage >= _employeeTotalPages) return;
    final scope = _scopeVersion;
    final request = ++_employeeRequest;
    setState(() => _employeesLoadingMore = true);
    try {
      final result = await ref
          .read(employeeRepositoryProvider)
          .list(
            page: _employeePage + 1,
            size: _pageSize,
            departmentId: widget.node.id,
            includeSubtree: true,
            statuses: currentDepartmentEmployeeStatuses,
            search: _keyword.trim().isEmpty ? null : _keyword.trim(),
            sort: _sortColumn,
            order: _sortColumn == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || scope != _scopeVersion || request != _employeeRequest) {
        return;
      }
      setState(() {
        _employees = [..._employees, ...result.items];
        _employeePage = result.page;
        _employeeTotal = result.total;
        _employeeTotalPages = result.totalPages;
        _employeesLoadingMore = false;
      });
    } catch (error) {
      if (!mounted || scope != _scopeVersion || request != _employeeRequest) {
        return;
      }
      setState(() => _employeesLoadingMore = false);
      if (error is ApiException) {
        context.appError(error.message);
      } else {
        context.appError('加载更多员工失败，请稍后重试');
      }
    }
  }

  void _onSearchChanged(String keyword) {
    final next = keyword.trim();
    if (next == _keyword) return;
    setState(() => _keyword = next);
    _reloadEmployees();
  }

  void _refreshPeopleData() {
    if (!widget.canViewEmployees) return;
    final scope = _scopeVersion;
    unawaited(_loadOverview(scope));
    unawaited(_reloadEmployees(scope: scope));
  }

  Future<void> _openEmployeeFlow(String location) async {
    await context.push(location);
    if (!mounted) return;
    _refreshPeopleData();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: l10n.commonRetry,
        onAction: _load,
      );
    }
    final info = _info;
    if (info == null) return const SizedBox.shrink();
    final selectable = kOperationalDepartmentLevels.contains(info.level);
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;

    // 2026-09-17：在册员工由 UtenPersonCard 卡片列表改为员工档案同款
    // MasterDataTableView 表格（列/表头筛选/排序/滚动自动翻页全对齐），
    // 上方详情卡+人员总览保持固定，表格独立滚动。
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, UtenSpacing.s16, hPad, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: MasterDetailCard(
                  title: info.name,
                  icon: Icons.account_tree_outlined,
                  subtitle: l10n.departmentLevelAndCode(info.level, info.code),
                  // 详情卡精简（与分类卡统一）：不再展示统计行与路径行——部门树已是
                  // 主视觉，在册人数等在下方员工列表/人员总览卡查看，卡片只留标题+操作。
                  stats: const [],
                  canEdit: widget.canEdit,
                  canAddChild: widget.canAddChild,
                  canDelete: widget.canDelete,
                  addChildLabel: '新增子部门',
                  onAddChild: widget.onAddChild,
                  onEdit: () => widget.onEdit(info),
                  onDelete: widget.onDelete,
                  extraActions: [
                    // 打印花名册就是查看员工名册(permissions-06)：与员工列表同一门槛，
                    // 旧的「打印导出」码只在前端生效，已随 V677 删除。
                    if (widget.canViewEmployees)
                      MasterDetailCardAction(
                        icon: Icons.print_outlined,
                        label: '打印花名册',
                        onPressed: () => showDepartmentRosterPrint(
                          context: context,
                          ref: ref,
                          node: widget.node,
                        ),
                      ),
                    if (widget.canViewEmployees)
                      MasterDetailCardAction(
                        icon: Icons.account_tree_outlined,
                        label: '部门架构图',
                        onPressed: () => showDepartmentOrgChart(
                          context: context,
                          node: widget.node,
                        ),
                      ),
                    if (selectable)
                      MasterDetailCardAction(
                        icon: Icons.badge_outlined,
                        label: '岗位管理',
                        // 岗位改名/增删会影响下方员工列表的 positionName 展示，
                        // 抽屉关闭后静默重拉人员数据，避免停留在旧岗位名。
                        onPressed: () async {
                          await showPositionManagerSheet(context, widget.node);
                          if (!mounted) return;
                          _refreshPeopleData();
                        },
                      ),
                  ],
                ),
              ),
              if (widget.canViewEmployees)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                  child: OrganizationWorkforceOverviewCard(
                    organizationName: info.name,
                    organizationLevel: info.level,
                    loading: _overviewLoading,
                    overview: _overview,
                    error: _overviewError,
                    onRetry: _loadOverview,
                  ),
                ),
              if (widget.canViewEmployees) ...[
                _employeeToolbar(info, selectable),
                const SizedBox(height: UtenSpacing.s8),
              ],
            ],
          ),
        ),
        Expanded(
          child: widget.canViewEmployees
              ? Padding(
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, UtenSpacing.s12),
                  child: _employeeTable(l10n),
                )
              : const Center(
                  child: UtenEmpty(
                    icon: Icons.lock_outline_rounded,
                    message: '无员工档案查看权限',
                  ),
                ),
        ),
      ],
    );
  }

  Widget _employeeToolbar(DepartmentInfo info, bool selectable) {
    final theme = Theme.of(context);
    final title = Row(
      children: [
        Icon(
          Icons.people_outline_rounded,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            '在册员工 $_employeeTotal 人',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (_employeesLoading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
    final search = UtenSearchBar(
      // key 含 node.id + _kwSeed：切部门 / 树搜索写入过滤词时重建搜索框同步显示。
      key: ValueKey('department-employee-search-${widget.node.id}-$_kwSeed'),
      hint: '搜索员工(姓名/工号)',
      initialValue: _keyword,
      onChanged: _onSearchChanged,
    );
    final addButton = selectable && widget.canCreateEmployee
        ? UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.add_rounded,
            onPressed: () => _openEmployeeFlow(
              '/employee/onboarding?departmentId=${info.id}',
            ),
            child: const Text('添加员工'),
          )
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: UtenSpacing.s8),
              search,
              if (addButton != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Align(alignment: Alignment.centerRight, child: addButton),
              ],
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 180, child: title),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(child: search),
            if (addButton != null) ...[
              const SizedBox(width: UtenSpacing.s8),
              addButton,
            ],
          ],
        );
      },
    );
  }

  // ---- 在册员工表格（员工档案同款 MasterDataTableView） -----------------------

  /// 双击行 / 右键「查看员工档案」：进详情，返回后刷新人员数据。
  Future<void> _openEmployeeDetail(EmployeeSummary e) async {
    await _openEmployeeFlow('/employee/${e.id}');
  }

  Widget _employeeTable(AppLocalizations l10n) {
    return MasterDataTableView<EmployeeSummary>(
      key: const Key('department-employee-table'),
      columns: _employeeColumns(l10n),
      items: _visibleEmployees(l10n),
      facets: _employeeFacets(l10n),
      nullCounts: const {},
      filters: _filters,
      onFilterChanged: _onFilterChanged,
      onRowTap: _openEmployeeDetail,
      rowMenuBuilder: (e) => [
        UtenMenuItem(
          label: '查看员工档案',
          icon: Icons.open_in_new_rounded,
          onTap: () => _openEmployeeDetail(e),
        ),
      ],
      sortColumn: _sortColumn,
      sortAscending: _sortAsc,
      onSortChange: _onSortChange,
      // 加载/错误/空态交给表格自身占位。
      isLoading: _employeesLoading,
      error: _employeesError,
      onRetry: _reloadEmployees,
      emptyMessage: _keyword.isEmpty
          ? l10n.departmentEmployeesEmpty
          : '没有找到匹配的在册员工',
      // 滚动临近底部自动追加下一页（替代原「加载更多」按钮）；还有没有更多
      // 由 _loadMoreEmployees 按 _employeePage/_employeeTotalPages 守卫。
      loadingMore: _employeesLoadingMore,
      onLoadMore: _loadMoreEmployees,
    );
  }

  List<MasterColumnDef<EmployeeSummary>> _employeeColumns(
    AppLocalizations l10n,
  ) => [
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

  String _statusLabel(AppLocalizations l10n, String key) => switch (key) {
    'active' => l10n.employeeStatusActive,
    'probation' => l10n.employeeStatusProbation,
    'onLeave' => l10n.employeeStatusOnLeave,
    'resigned' => l10n.employeeStatusResigned,
    _ => key,
  };

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

  /// 表头排序菜单：(null, _) 取消排序回到服务端默认顺序（白名单同员工档案页）。
  void _onSortChange(String? column, bool ascending) {
    if (column == null) {
      if (_sortColumn == null) return;
      setState(() => _sortColumn = null);
      _reloadEmployees();
      return;
    }
    if (column == _sortColumn && ascending == _sortAsc) return;
    setState(() {
      _sortColumn = column;
      _sortAsc = ascending;
    });
    _reloadEmployees();
  }

  /// 表头筛选裁剪已加载行（空值行在选了任何值时被滤掉）。
  List<EmployeeSummary> _visibleEmployees(AppLocalizations l10n) {
    if (_filters.values.every((v) => v == null || v.isEmpty)) return _employees;
    final dept = _filters['departmentName'];
    final status = _filters['status'];
    final position = _filters['positionName'];
    return _employees.where((e) {
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
  Map<String, List<MasterFacetBucket>> _employeeFacets(AppLocalizations l10n) {
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
      'departmentName': bucketsOf(
        _employees.map((e) => e.departmentName ?? ''),
      ),
      'status': bucketsOf([
        for (final e in _employees)
          if (e.status != null) _statusLabel(l10n, e.status!),
      ]),
      'positionName': bucketsOf(_employees.map((e) => e.positionName ?? '')),
    };
  }
}
