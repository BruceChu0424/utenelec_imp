// 员工档案列表页（真实后端 + 组件库）
// 卡片化展示（UtenPersonCard），状态走 EmployeeStatusBadge，空/错走 UtenEmpty。
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 文档：docs/03-页面/员工列表页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_person_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/ui/app_notification.dart';
import '../models/employee_api_models.dart';
import '../models/work_years.dart';
import '../repositories/employee_repository.dart';
import '../widgets/employee_status_badge.dart';
import '../widgets/employee_leadership_badge.dart';

class EmployeeListPage extends ConsumerStatefulWidget {
  const EmployeeListPage({super.key});

  @override
  ConsumerState<EmployeeListPage> createState() => _EmployeeListPageState();
}

class _EmployeeListPageState extends ConsumerState<EmployeeListPage> {
  static const _statusKeys = ['active', 'probation', 'onLeave', 'resigned'];

  String _search = '';
  final Set<String> _statuses = {};
  final List<EmployeeSummary> _items = [];
  int _page = 1;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final request = ++_request;
    final search = _search;
    final statuses = Set<String>.of(_statuses);
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
            statuses: statuses.isEmpty ? null : statuses,
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
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = AppLocalizations.of(context).employeeOnboardLoadFailed;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _totalPages) return;
    final request = ++_request;
    final search = _search;
    final statuses = Set<String>.of(_statuses);
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final r = await ref
          .read(employeeRepositoryProvider)
          .list(
            page: nextPage,
            search: search.isEmpty ? null : search,
            statuses: statuses.isEmpty ? null : statuses,
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

  void _toggleStatus(String s) {
    setState(() {
      if (_statuses.contains(s)) {
        _statuses.remove(s);
      } else {
        _statuses.add(s);
      }
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canCreate =
        permissions.contains(Perm.employeeCreate) &&
        permissions.contains(Perm.employeePiiEdit);

    Widget body = Column(
      children: [
        // 搜索框：UtenSearchBar 自带 300ms 防抖 + 清除按钮
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s8,
          ),
          child: UtenSearchBar(
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
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
            children: _statusKeys.map((key) {
              final selected = _statuses.contains(key);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
                child: FilterChip(
                  label: Text(_statusLabel(l10n, key)),
                  selected: selected,
                  onSelected: (_) => _toggleStatus(key),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Expanded(child: _body()),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: l10n.commonRetry,
        onAction: _reload,
      );
    }
    if (_items.isEmpty) {
      return UtenEmpty(
        icon: Icons.people_outline_rounded,
        message: l10n.employeeEmpty,
        description: l10n.employeeEmptyHint,
      );
    }
    return ListView.builder(
      itemCount: _items.length + 1,
      itemBuilder: (context, i) {
        if (i == _items.length) {
          if (_page < _totalPages) {
            return Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Center(
                child: _loadingMore
                    ? const CircularProgressIndicator()
                    : FilledButton.tonal(
                        onPressed: _loadMore,
                        child: Text(l10n.employeeLoadMore),
                      ),
              ),
            );
          }
          // 底部留白：避免最后一项被悬浮导航 / FAB 遮挡
          return const SizedBox(height: 80);
        }
        final e = _items[i];
        final leadershipLabel = employeeLeadershipLabel(
          departmentManager: e.departmentManager,
          positionLevel: e.positionLevel,
          leaderRank: e.leaderRank,
        );
        // 工龄动态计算：每次渲染按当前日期得出，随日期自然变化
        final workYears = workYearsText(l10n, e.hireDate);
        return UtenPersonCard(
          margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
          title: e.fullName,
          titleLeading: leadershipLabel == null
              ? null
              : EmployeeLeadershipBadge(
                  departmentManager: e.departmentManager,
                  positionLevel: e.positionLevel,
                  leaderRank: e.leaderRank,
                ),
          subtitle:
              '${e.code} · ${e.departmentName ?? ''} · ${e.positionName ?? ''} · ${l10n.employeeFieldWorkYears} $workYears'
              // ADR-021：搜索命中车牌时附带显示（谁的车有问题 → 按车牌秒查人）
              '${e.matchedPlates == null ? '' : ' · 🚗 ${e.matchedPlates}'}',
          avatarText: e.fullName,
          trailing: EmployeeStatusBadge(status: e.status),
          onTap: () async {
            await context.push('/employee/${e.id}');
            if (!mounted) return;
            _reload();
          },
        );
      },
    );
  }
}
