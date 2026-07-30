// 钱流单据列表页（按 docType 参数化，5 单据通用）。
//
// 复刻采购单据列表：UtenAppBar(标题/返回/刷新) + UtenContentContainer > 标题行
// (Icon+label+(N)+搜索+新建) + 状态筛选(ChoiceChip Wrap) + MasterDataTableView。
// 名称解析（客户/供应商/账户）通过 FinanceNameService。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';

class FinanceDocListPage extends ConsumerStatefulWidget {
  const FinanceDocListPage({super.key, required this.docType});
  final FinanceDocType docType;

  @override
  ConsumerState<FinanceDocListPage> createState() => _FinanceDocListPageState();
}

class _FinanceDocListPageState extends ConsumerState<FinanceDocListPage> {
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.docType);
  PagedResult<FinanceDocListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String _keyword = '';
  int? _statusFilter; // null=全部
  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认 billDate DESC）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(financeRepositoryProvider(widget.docType))
          .list(
            page: page,
            filter: FinanceDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              status: _statusFilter,
            ),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载列表失败';
        _loading = false;
      });
    }
  }

  void _onStatus(int? s) {
    setState(() => _statusFilter = s);
    _load(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _load(1);
  }

  List<MasterColumnDef<FinanceDocListItem>> _columns(FinanceNameService names) {
    return <MasterColumnDef<FinanceDocListItem>>[
      MasterColumnDef(
        key: 'billNo',
        label: '单据号',
        width: 150,
        value: (it) => it.billNo,
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '日期',
        width: 120,
        type: 'date',
        sortable: true,
        value: (it) => (it.billDate ?? '').substring(0, 10),
      ),
      if (_cfg.hasParty)
        MasterColumnDef(
          key: _cfg.isClient ? 'clientId' : 'supplierId',
          label: _cfg.partyLabel,
          width: 200,
          value: (it) => _cfg.isClient
              ? names.client(it.partyId)
              : names.supplier(it.partyId),
        ),
      MasterColumnDef(
        key: 'accountId',
        label: _cfg.accountLabel,
        width: 180,
        value: (it) => names.account(it.accountId ?? it.outAccountId),
      ),
      MasterColumnDef(
        key: 'amountLocal',
        label: '合计',
        width: 140,
        type: 'money',
        sortable: true,
        value: (it) => it.amountLocal?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 100,
        value: (it) => financeStatusLabel(it.status),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: _cfg.label,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _load(_pageNum),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 页面头：Icon + 标题 + 计数 + 新建按钮（搜索条挪到下方筛选区/侧栏）
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _cfg.icon,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '${_cfg.shortLabel} ($total)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (_canEdit)
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: () => context.push(
                            '/finance/${_cfg.type.pathSegment}/new',
                          ),
                          child: const Text('新建'),
                        ),
                    ],
                  ),
                ),
                // 桌面：左筛选侧栏（搜索 + 状态 Chip）+ 右表格；手机：垂直堆叠
                Expanded(
                  child: UtenListTwoPane(
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: UtenSearchBar(
                              hint: '搜索单据号',
                              initialValue: _keyword,
                              onChanged: (v) {
                                setState(() => _keyword = v);
                                _load(1);
                              },
                            ),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _statusChip('全部', null),
                              _statusChip('草稿', kFinanceStatusDraft),
                              _statusChip('已审', kFinanceStatusApproved),
                              _statusChip('红冲', kFinanceStatusReversed),
                            ],
                          ),
                        ],
                      ),
                    ),
                    tablePane: MasterDataTableView<FinanceDocListItem>(
                      columns: _columns(names),
                      items: _page?.items ?? const [],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      sortColumn: _sortKey,
                      sortAscending: _sortAsc,
                      onSortChange: _onSortChange,
                      onRowTap: (it) => context.push(
                        '/finance/${_cfg.type.pathSegment}/${it.id}',
                      ),
                      isLoading: _loading && _page == null,
                      loadingMore: _loading && _page != null,
                      error: _error,
                      onRetry: () => _load(_pageNum),
                      emptyMessage: '暂无${_cfg.shortLabel}单',
                      currentPage: _page?.page ?? 1,
                      totalPages: _page?.totalPages ?? 1,
                      onPageChange: (p) => _load(p),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip(String label, int? value) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _onStatus(value),
    );
  }
}
