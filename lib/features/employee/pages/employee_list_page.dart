// 员工档案列表页（真实后端 + 组件库）
// 卡片化展示（UtenPersonCard），状态走 EmployeeStatusBadge，空/错走 UtenEmpty。
// 文档：docs/03-页面/员工列表页.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_person_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';
import '../widgets/employee_status_badge.dart';

class EmployeeListPage extends ConsumerStatefulWidget {
  const EmployeeListPage({super.key});

  @override
  ConsumerState<EmployeeListPage> createState() => _EmployeeListPageState();
}

class _EmployeeListPageState extends ConsumerState<EmployeeListPage> {
  static const _statusKeys = ['active', 'probation', 'onLeave', 'resigned'];

  final _searchCtl = TextEditingController();
  String _search = '';
  Timer? _debounce;
  final Set<String> _statuses = {};
  final List<EmployeeSummary> _items = [];
  int _page = 1;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.removeListener(_onSearchChanged);
    _searchCtl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final v = _searchCtl.text.trim();
    if (v != _search) {
      _search = v;
      // 防抖：停止输入 300ms 后再请求，避免乱序与抖动
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), _reload);
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _page = 1;
    try {
      final r = await ref
          .read(employeeRepositoryProvider)
          .list(
            search: _search.isEmpty ? null : _search,
            statuses: _statuses.isEmpty ? null : _statuses,
          );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(r.items);
        _totalPages = r.totalPages;
        _loading = false;
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
        _error = AppLocalizations.of(context).employeeOnboardLoadFailed;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _totalPages) return;
    setState(() => _loadingMore = true);
    try {
      final r = await ref
          .read(employeeRepositoryProvider)
          .list(
            page: _page + 1,
            search: _search.isEmpty ? null : _search,
            statuses: _statuses.isEmpty ? null : _statuses,
          );
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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.employeeTitle)),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add_rounded),
        label: Text(l10n.employeeFabOnboard),
        onPressed: () async {
          await context.push('/employee/onboarding');
          _reload();
        },
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                hintText: l10n.employeeSearchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: _searchCtl.clear,
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: _statusKeys.map((key) {
                final selected = _statuses.contains(key);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: Text(_statusLabel(l10n, key)),
                    selected: selected,
                    onSelected: (_) => _toggleStatus(key),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _body()),
        ],
      ),
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
              padding: const EdgeInsets.all(16),
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
          return const SizedBox(height: 80);
        }
        final e = _items[i];
        return UtenPersonCard(
          title: e.fullName,
          subtitle:
              '${e.code} · ${e.departmentName ?? ''} · ${e.positionName ?? ''}',
          avatarText: e.fullName,
          trailing: EmployeeStatusBadge(status: e.status),
          onTap: () => context.push('/employee/${e.id}'),
        );
      },
    );
  }
}
