import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/finance_asset_category_models.dart';
import '../models/finance_asset_models.dart';
import '../repositories/finance_asset_category_repository.dart';
import '../repositories/finance_asset_workbench_repository.dart';
import 'finance_asset_detail.dart';
import 'finance_asset_form.dart';
import 'finance_asset_ui.dart';

class FinanceAssetLedgerPanel extends ConsumerStatefulWidget {
  const FinanceAssetLedgerPanel({
    super.key,
    required this.ledger,
    required this.capabilities,
    required this.policyReady,
    required this.refreshToken,
  });

  final FinanceAssetLedger ledger;
  final FinanceAssetCapabilities capabilities;
  final bool policyReady;
  final int refreshToken;

  @override
  ConsumerState<FinanceAssetLedgerPanel> createState() =>
      _FinanceAssetLedgerPanelState();
}

class _FinanceAssetLedgerPanelState
    extends ConsumerState<FinanceAssetLedgerPanel> {
  final _requestGuard = LatestRequestGuard();
  final _categoryGuard = LatestRequestGuard();
  FinanceAssetQuery _query = const FinanceAssetQuery();
  PagedResult<FinanceAssetSummary>? _result;
  bool _loading = true;
  String? _error;
  List<FinanceAssetCategory> _categories = const [];
  bool _categoriesLoading = true;
  String? _categoriesError;
  DeptSelection? _department;

  @override
  void initState() {
    super.initState();
    _load();
    _loadCategories();
  }

  @override
  void didUpdateWidget(covariant FinanceAssetLedgerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      _load();
      _loadCategories();
    }
  }

  Future<void> _load() async {
    final generation = _requestGuard.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var result = await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .list(widget.ledger, query: _query);
      if (result.items.isEmpty &&
          _query.page > 1 &&
          result.totalPages < _query.page) {
        _query = _query.copyWith(page: result.totalPages.clamp(1, _query.page));
        result = await ref
            .read(financeAssetWorkbenchRepositoryProvider)
            .list(widget.ledger, query: _query);
      }
      if (!mounted || !_requestGuard.isCurrent(generation)) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_requestGuard.isCurrent(generation)) return;
      setState(() {
        _loading = false;
        _error = '加载${widget.ledger.label}失败，请重试';
      });
    }
  }

  Future<void> _loadCategories() async {
    final generation = _categoryGuard.begin();
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    try {
      final categories = await ref
          .read(financeAssetCategoryRepositoryProvider)
          .list(widget.ledger);
      if (!mounted || !_categoryGuard.isCurrent(generation)) return;
      setState(() {
        _categories = categories;
        _categoriesLoading = false;
      });
    } catch (_) {
      if (!mounted || !_categoryGuard.isCurrent(generation)) return;
      setState(() {
        _categoriesLoading = false;
        _categoriesError = '分类筛选加载失败';
      });
    }
  }

  void _changeQuery(FinanceAssetQuery query) {
    setState(() => _query = query);
    _load();
  }

  Future<void> _create() async {
    final saved = await showFinanceAssetForm(context, ledger: widget.ledger);
    if (!mounted || !saved) return;
    _query = _query.copyWith(page: 1);
    await _load();
  }

  Future<void> _edit(FinanceAssetSummary item) async {
    try {
      final detail = await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .detail(widget.ledger, item.id);
      if (!mounted) return;
      final saved = await showFinanceAssetForm(
        context,
        ledger: widget.ledger,
        existing: detail.summary,
      );
      if (mounted && saved) await _load();
    } catch (error) {
      if (mounted) {
        context.appApiError(error, fallback: '加载完整草稿失败，请刷新后重试');
      }
    }
  }

  Future<void> _delete(FinanceAssetSummary item) async {
    final expectedVersion = item.version;
    if (expectedVersion == null) {
      if (mounted) context.appWarning('缺少记录版本，请刷新后重试');
      return;
    }
    final confirmed = await UtenDialog.show(
      context,
      title: '删除草稿？',
      content: Text('将删除 ${item.code} ${item.name}。仅草稿可删除，历史事件不会被伪造覆盖。'),
      confirmLabel: '删除草稿',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .deleteDraft(
            widget.ledger,
            item.id,
            expectedVersion: expectedVersion,
          );
      if (!mounted) return;
      context.appSuccess('草稿已删除');
      await _load();
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '删除失败，请刷新后重试');
    }
  }

  Future<void> _openDetail(FinanceAssetSummary item) async {
    final changed = await showFinanceAssetDetail(
      context,
      ledger: widget.ledger,
      id: item.id,
      capabilities: widget.capabilities,
      onEdit:
          widget.capabilities.canEdit &&
              item.status.toUpperCase() == 'DRAFT' &&
              actionAllowed(item.allowedActions, 'EDIT')
          ? () => _edit(item)
          : null,
      onDelete:
          widget.capabilities.canEdit &&
              item.version != null &&
              item.status.toUpperCase() == 'DRAFT' &&
              actionAllowed(item.allowedActions, 'DELETE')
          ? () => _delete(item)
          : null,
    );
    if (mounted && changed) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < UtenBreakpoints.mediumStart) {
          return Column(
            children: [
              _compactFilters(),
              Expanded(child: _compactList()),
            ],
          );
        }
        return UtenListTwoPane(
          filterPaneTitle: '${widget.ledger.label}筛选',
          filterPane: _filterFields(),
          filterPaneFooter: widget.capabilities.canEdit
              ? UtenButton(
                  icon: Icons.add_rounded,
                  onPressed: _create,
                  child: Text('新建${widget.ledger.label}'),
                )
              : null,
          tablePane: _table(),
        );
      },
    );
  }

  Widget _compactFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        UtenSpacing.s8,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _search()),
              if (widget.capabilities.canEdit) ...[
                const SizedBox(width: UtenSpacing.s8),
                Semantics(
                  button: true,
                  label: '新建${widget.ledger.label}',
                  child: IconButton.filled(
                    key: Key('finance-asset-create-${widget.ledger.apiValue}'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: '新建${widget.ledger.label}',
                    onPressed: _create,
                    icon: const Icon(Icons.add_rounded),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(child: _statusFilter()),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(child: _categoryFilter()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterFields() {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _search(),
          const SizedBox(height: UtenSpacing.s12),
          _statusFilter(),
          const SizedBox(height: UtenSpacing.s12),
          _categoryFilter(),
          const SizedBox(height: UtenSpacing.s12),
          UtenDepartmentPicker(
            key: ValueKey('asset-filter-department-${_department?.id}'),
            mode: UtenDepartmentPickerMode.single,
            label: '归属部门',
            hint: '全部部门',
            initialSelection: _department == null ? const [] : [_department!],
            onChanged: (selection) {
              final department = selection.firstOrNull;
              _department = department;
              _changeQuery(
                _query.copyWith(
                  page: 1,
                  departmentId: department?.id,
                  clearDepartmentId: department == null,
                ),
              );
            },
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenButton(
            type: UtenButtonType.ghost,
            icon: Icons.filter_alt_off_outlined,
            onPressed: _resetFilters,
            child: const Text('重置筛选'),
          ),
        ],
      ),
    );
  }

  Widget _search() {
    return UtenSearchBar(
      key: ValueKey('asset-search-${widget.ledger.apiValue}'),
      initialValue: _query.q,
      hint: '搜索编号 / 名称',
      onChanged: (value) => _changeQuery(
        _query.copyWith(page: 1, q: value, clearQ: value.trim().isEmpty),
      ),
    );
  }

  Widget _statusFilter() {
    final statuses = <String, String>{
      'DRAFT': '草稿',
      'PENDING_APPROVAL': '待审批',
      'APPROVED': '已审批',
      'ACTIVE': '使用中',
      'COMPLETED': '已完成',
      if (widget.ledger == FinanceAssetLedger.fixedAsset)
        'DISPOSAL_PENDING': '待处置',
      'DISPOSED': '已处置',
      if (widget.ledger == FinanceAssetLedger.deferredExpense)
        'TERMINATION_PENDING': '待终止',
      'TERMINATED': '已终止',
    };
    return UtenDropdownField(
      key: ValueKey('asset-status-${widget.ledger.apiValue}-${_query.status}'),
      label: '状态',
      value: _query.status,
      hintText: '全部状态',
      items: [
        for (final entry in statuses.entries)
          UtenDropdownItem(value: entry.key, label: entry.value),
      ],
      onChanged: (value) => _changeQuery(
        _query.copyWith(page: 1, status: value, clearStatus: value == null),
      ),
    );
  }

  Widget _categoryFilter() {
    if (_categoriesLoading) return const LinearProgressIndicator();
    if (_categoriesError != null) {
      return Row(
        children: [
          Expanded(child: Text(_categoriesError!)),
          IconButton(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: '重试分类',
            onPressed: _loadCategories,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      );
    }
    return UtenDropdownField(
      key: ValueKey(
        'asset-category-filter-${widget.ledger.apiValue}-${_query.categoryId}',
      ),
      label: '分类',
      value: _query.categoryId,
      hintText: '全部分类',
      searchable: true,
      items: [
        for (final item in _categories)
          UtenDropdownItem(
            value: item.id,
            label: '${item.code} · ${item.name}',
          ),
      ],
      onChanged: (value) => _changeQuery(
        _query.copyWith(
          page: 1,
          categoryId: value,
          clearCategoryId: value == null,
        ),
      ),
    );
  }

  void _resetFilters() {
    setState(() {
      _query = const FinanceAssetQuery();
      _department = null;
    });
    _load();
  }

  Widget _table() {
    final result = _result;
    return MasterDataTableView<FinanceAssetSummary>(
      key: ValueKey('finance-asset-table-${widget.ledger.apiValue}'),
      columns: [
        MasterColumnDef(
          key: 'code',
          label: '编号',
          width: 128,
          value: (item) => item.code,
        ),
        MasterColumnDef(
          key: 'name',
          label: '名称',
          width: 180,
          value: (item) => item.name,
        ),
        MasterColumnDef(
          key: 'categoryName',
          label: '分类',
          width: 140,
          value: (item) => item.categoryName ?? '—',
        ),
        MasterColumnDef(
          key: 'departmentName',
          label: '归属部门',
          width: 140,
          value: (item) => item.departmentName ?? '—',
        ),
        MasterColumnDef(
          key: 'grossAmount',
          label: widget.ledger.amountLabel,
          width: 140,
          type: 'money',
          value: (item) => formatFinanceDecimal(
            widget.ledger == FinanceAssetLedger.fixedAsset
                ? item.originalValue
                : item.totalAmount,
          ),
        ),
        MasterColumnDef(
          key: 'balance',
          label: widget.ledger == FinanceAssetLedger.fixedAsset
              ? '账面净值'
              : '待摊余额',
          width: 140,
          type: 'money',
          value: (item) => formatFinanceDecimal(item.displayedBalance),
        ),
        MasterColumnDef(
          key: 'startPeriod',
          label: '开始期间',
          width: 110,
          value: (item) => item.startPeriod ?? '—',
        ),
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 100,
          value: (item) => financeAssetStatusLabel(item.status),
        ),
      ],
      items: result?.items ?? const [],
      facets: const <String, List<MasterFacetBucket>>{},
      nullCounts: const <String, int>{},
      filters: const <String, String?>{},
      onFilterChanged: (_, _) {},
      onRowTap: _openDetail,
      isLoading: _loading,
      error: _error,
      onRetry: _load,
      emptyMessage: '暂无${widget.ledger.label}，请先创建草稿并完成审批',
      currentPage: result?.page ?? _query.page,
      totalPages: result?.totalPages ?? 1,
      onPageChange: (page) => _changeQuery(_query.copyWith(page: page)),
      toolbarActions: widget.capabilities.canEdit
          ? [
              UtenButton(
                key: Key(
                  'finance-asset-create-table-${widget.ledger.apiValue}',
                ),
                icon: Icons.add_rounded,
                onPressed: _create,
                child: Text('新建${widget.ledger.label}'),
              ),
            ]
          : null,
    );
  }

  Widget _compactList() {
    if (_loading && _result == null) {
      return const UtenSkeletonList();
    }
    if (_error != null && _result == null) {
      return _scrollableCompactState(
        UtenEmpty.error(
          key: Key('finance-asset-retry-${widget.ledger.apiValue}'),
          message: _error,
          actionLabel: '重试',
          onAction: _load,
        ),
      );
    }
    final result = _result;
    final items = result?.items ?? const <FinanceAssetSummary>[];
    if (items.isEmpty) {
      return _scrollableCompactState(
        UtenEmpty(
          message: '暂无${widget.ledger.label}',
          description: widget.policyReady
              ? '可创建草稿，提交审批后再启用并生成计提计划。'
              : '仍可保存不完整草稿；提交、启用和过账前须补齐政策。',
          actionLabel: widget.capabilities.canEdit
              ? '新建${widget.ledger.label}'
              : null,
          onAction: widget.capabilities.canEdit ? _create : null,
        ),
      );
    }
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12,
              UtenSpacing.s4,
              UtenSpacing.s12,
              UtenSpacing.s12,
            ),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: UtenSpacing.s8),
            itemBuilder: (context, index) => _assetCard(items[index]),
          ),
        ),
        _compactPager(result!),
      ],
    );
  }

  Widget _scrollableCompactState(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }

  Widget _assetCard(FinanceAssetSummary item) {
    final theme = Theme.of(context);
    final canEditDraft =
        widget.capabilities.canEdit &&
        item.status.toUpperCase() == 'DRAFT' &&
        actionAllowed(item.allowedActions, 'EDIT');
    final canDeleteDraft =
        widget.capabilities.canEdit &&
        item.version != null &&
        item.status.toUpperCase() == 'DRAFT' &&
        actionAllowed(item.allowedActions, 'DELETE');
    return Semantics(
      button: true,
      label:
          '${item.code} ${item.name}，${financeAssetStatusLabel(item.status)}，余额 ${formatFinanceDecimal(item.displayedBalance)}',
      child: Material(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: UtenRadius.xlAll,
        child: InkWell(
          borderRadius: UtenRadius.xlAll,
          onTap: () => _openDetail(item),
          child: Container(
            constraints: const BoxConstraints(minHeight: 112),
            padding: const EdgeInsets.all(UtenSpacing.s16),
            decoration: BoxDecoration(
              borderRadius: UtenRadius.xlAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.code,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    financeAssetStatusBadge(item.status),
                    if (canEditDraft || canDeleteDraft)
                      PopupMenuButton<String>(
                        tooltip: '草稿操作',
                        onSelected: (action) {
                          if (action == 'edit') _edit(item);
                          if (action == 'delete') _delete(item);
                        },
                        itemBuilder: (_) => [
                          if (canEditDraft)
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('编辑草稿'),
                            ),
                          if (canDeleteDraft)
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除草稿'),
                            ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [item.categoryName, item.departmentName]
                                .whereType<String>()
                                .where((value) => value.isNotEmpty)
                                .join(' · ')
                                .isEmpty
                            ? '未标注分类/部门'
                            : [item.categoryName, item.departmentName]
                                  .whereType<String>()
                                  .where((value) => value.isNotEmpty)
                                  .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          widget.ledger == FinanceAssetLedger.fixedAsset
                              ? '账面净值'
                              : '待摊余额',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          '¥ ${formatFinanceDecimal(item.displayedBalance)}',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _compactPager(PagedResult<FinanceAssetSummary> result) {
    if (result.totalPages <= 1) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: '上一页',
              onPressed: result.page > 1
                  ? () => _changeQuery(_query.copyWith(page: result.page - 1))
                  : null,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Flexible(child: Text('第 ${result.page} / ${result.totalPages} 页')),
            IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: '下一页',
              onPressed: result.page < result.totalPages
                  ? () => _changeQuery(_query.copyWith(page: result.page + 1))
                  : null,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
