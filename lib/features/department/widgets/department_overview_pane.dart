import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_person_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/employee_leadership_badge.dart';
import '../../employee/widgets/employee_status_badge.dart';
import '../models/department_node.dart';
import '../models/workforce_overview.dart';
import '../repositories/department_repository.dart';
import 'organization_workforce_overview_card.dart';
import 'position_manager_sheet.dart';

class DepartmentOverviewPane extends ConsumerStatefulWidget {
  const DepartmentOverviewPane({
    super.key,
    required this.node,
    required this.canEdit,
    required this.canViewEmployees,
    required this.canCreateEmployee,
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
  });

  final DepartmentNode node;
  final bool canEdit;
  final bool canViewEmployees;
  final bool canCreateEmployee;
  final VoidCallback onAddChild;
  final void Function(DepartmentInfo detail) onEdit;
  final VoidCallback onDelete;

  @override
  ConsumerState<DepartmentOverviewPane> createState() =>
      _DepartmentOverviewPaneState();
}

class _DepartmentOverviewPaneState
    extends ConsumerState<DepartmentOverviewPane> {
  static const _currentStatuses = {'active', 'probation', 'onLeave'};
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
      _keyword = '';
      _info = null;
      _overview = null;
      _overviewError = null;
      _employees = const [];
      _employeeTotal = 0;
      _employeesError = null;
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
            statuses: _currentStatuses,
            search: _keyword.trim().isEmpty ? null : _keyword.trim(),
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
            statuses: _currentStatuses,
            search: _keyword.trim().isEmpty ? null : _keyword.trim(),
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
    final selectable = kSelectableDepartmentLevels.contains(info.level);
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hPad, UtenSpacing.s16, hPad, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: MasterDetailCard(
                  title: info.name,
                  icon: Icons.account_tree_outlined,
                  subtitle: l10n.departmentLevelAndCode(info.level, info.code),
                  stats: [
                    MasterDetailStat(
                      '直属在册',
                      _overview == null
                          ? null
                          : '${_overview!.directCurrentEmployees}',
                    ),
                    MasterDetailStat(
                      l10n.departmentStatChildren,
                      '${info.childCount}',
                    ),
                    MasterDetailStat(
                      l10n.departmentStatManager,
                      info.managerName,
                    ),
                    MasterDetailStat(
                      l10n.departmentStatParent,
                      info.parentName,
                    ),
                  ],
                  path: info.path.isEmpty ? null : info.path,
                  canEdit: widget.canEdit,
                  addChildLabel: '新增子部门',
                  onAddChild: widget.onAddChild,
                  onEdit: () => widget.onEdit(info),
                  onDelete: widget.onDelete,
                  extraActions: [
                    if (selectable)
                      MasterDetailCardAction(
                        icon: Icons.badge_outlined,
                        label: '岗位管理',
                        onPressed: () =>
                            showPositionManagerSheet(context, widget.node),
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
            ]),
          ),
        ),
        if (widget.canViewEmployees)
          ..._employeeSlivers(l10n, hPad)
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(hPad, 0, hPad, UtenSpacing.s16),
            sliver: const SliverToBoxAdapter(
              child: SizedBox(
                height: 220,
                child: UtenEmpty(
                  icon: Icons.lock_outline_rounded,
                  message: '无员工档案查看权限',
                ),
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
      key: ValueKey('department-employee-search-${widget.node.id}'),
      hint: '搜索员工（姓名/工号）',
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

  List<Widget> _employeeSlivers(AppLocalizations l10n, double hPad) {
    EdgeInsets sectionPadding({double bottom = UtenSpacing.s16}) =>
        EdgeInsets.fromLTRB(hPad, 0, hPad, bottom);

    if (_employeesLoading && _employees.isEmpty) {
      return [
        SliverPadding(
          padding: sectionPadding(),
          sliver: const SliverToBoxAdapter(
            child: SizedBox(
              height: 220,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
      ];
    }
    if (_employeesError != null) {
      return [
        SliverPadding(
          padding: sectionPadding(),
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 220,
              child: UtenEmpty.error(
                message: _employeesError,
                actionLabel: l10n.commonRetry,
                onAction: _reloadEmployees,
              ),
            ),
          ),
        ),
      ];
    }
    if (_employees.isEmpty) {
      return [
        SliverPadding(
          padding: sectionPadding(),
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 220,
              child: UtenEmpty(
                icon: Icons.people_outline_rounded,
                message: _keyword.isEmpty
                    ? l10n.departmentEmployeesEmpty
                    : '没有找到匹配的在册员工',
              ),
            ),
          ),
        ),
      ];
    }
    final hasMore = _employeePage < _employeeTotalPages;
    return [
      SliverPadding(
        padding: sectionPadding(bottom: hasMore ? 0 : UtenSpacing.s16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final employee = _employees[index];
            final leadershipLabel = employeeLeadershipLabel(
              departmentManager: employee.departmentManager,
              positionLevel: employee.positionLevel,
              leaderRank: employee.leaderRank,
            );
            return UtenPersonCard(
              margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
              title: employee.fullName,
              titleLeading: leadershipLabel == null
                  ? null
                  : EmployeeLeadershipBadge(
                      departmentManager: employee.departmentManager,
                      positionLevel: employee.positionLevel,
                      leaderRank: employee.leaderRank,
                    ),
              subtitle:
                  '${employee.code} · ${employee.departmentName ?? ''} · '
                  '${employee.positionName ?? ''}',
              avatarText: employee.fullName,
              trailing: EmployeeStatusBadge(status: employee.status),
              onTap: () => _openEmployeeFlow('/employee/${employee.id}'),
            );
          }, childCount: _employees.length),
        ),
      ),
      if (hasMore)
        SliverPadding(
          padding: sectionPadding(),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: _employeesLoadingMore
                  ? const Padding(
                      padding: EdgeInsets.all(UtenSpacing.s12),
                      child: CircularProgressIndicator(),
                    )
                  : FilledButton.tonal(
                      onPressed: _loadMoreEmployees,
                      child: Text(
                        '加载更多（已显示 ${_employees.length}/$_employeeTotal）',
                      ),
                    ),
            ),
          ),
        ),
    ];
  }
}
