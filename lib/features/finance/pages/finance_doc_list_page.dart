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
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_table_facets.dart';

class FinanceDocListPage extends ConsumerStatefulWidget {
  const FinanceDocListPage({super.key, required this.docType});
  final FinanceDocType docType;

  @override
  ConsumerState<FinanceDocListPage> createState() => _FinanceDocListPageState();
}

class _FinanceDocListPageState extends ConsumerState<FinanceDocListPage> {
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.docType);
  final _list = PagedListController<FinanceDocListItem>();

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;
  int? _statusFilter; // null=全部
  String? _partyIdFilter;
  String? _accountIdFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded();
      _reload(1);
    });
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  bool get _canCreate {
    final permission = _cfg.createPerm;
    return permission != null &&
        ref.read(currentPermissionsProvider).contains(permission);
  }

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<FinanceDocListItem>> _fetch() => ref
      .read(financeRepositoryProvider(widget.docType))
      .list(
        page: _list.pageNum,
        filter: FinanceDocFilter(
          keyword: _list.normalizedKeyword,
          partyId: _cfg.hasParty ? _partyIdFilter : null,
          accountId: _cfg.type == FinanceDocType.bankTransfer
              ? null
              : _accountIdFilter,
          outAccountId: _cfg.type == FinanceDocType.bankTransfer
              ? _accountIdFilter
              : null,
          status: _statusFilter,
        ),
        sort: _list.sortKey,
        order: _list.sortOrder,
      );

  Future<void> _reload([int? page, bool silent = false]) =>
      _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);

  void _onStatus(int? s) {
    setState(() => _statusFilter = s);
    _reload(1);
  }

  void _onColumnFilterChanged(String key, String? value) {
    setState(() {
      if (key == 'status') {
        _statusFilter = value == null ? null : int.tryParse(value);
      } else if (key == 'accountId') {
        _accountIdFilter = value;
      } else if (key == 'clientId' || key == 'supplierId') {
        _partyIdFilter = value;
      }
    });
    _reload(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
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
      if (_cfg.type == FinanceDocType.receipt)
        MasterColumnDef(
          key: 'receiptKind',
          label: '收款业务',
          width: 130,
          value: (it) => financeReceiptKindLabel(it.receiptKind),
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
    // 操作后刷新：详情/编辑页保存/审核等成功会 bump 本 docType 的 tick，
    // 本页（即便被详情页遮在栈下）收到即重拉，返回不再看到老数据。
    ref.listen(listRefreshTickProvider(_cfg.refreshKey), (_, _) {
      _reload();
    });
    // 返回即刷新：从详情/编辑页（或任何页面）回到本列表时重拉当前页，
    // 即便对方未 bump tick（纯查看返回）也保证看到最新数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _reload(null, true));
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
            onPressed: () => _reload(),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: ListenableBuilder(
              listenable: _list,
              builder: (context, _) {
                final total = _list.total;
                // 「顶部折叠 + 表格吸顶内滚」：标题行随上滑收起腾出空间，
                // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
                return UtenCollapsingHeaderScrollView(
                  // 页面头：Icon + 标题 + 计数 + 新建按钮（搜索条挪到下方筛选区/侧栏）
                  collapsingHeader: Padding(
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
                        if (_canCreate)
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
                  body: UtenListTwoPane(
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
                              initialValue: _list.keyword,
                              onChanged: (v) {
                                _list.keyword = v;
                                _reload(1);
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
                      // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
                      primary: true,
                      columns: _columns(names),
                      items: _list.page?.items ?? const [],
                      facets: {
                        if (_cfg.hasParty)
                          _cfg.isClient
                              ? 'clientId'
                              : 'supplierId': financeDictionaryFacets(
                            _cfg.isClient
                                ? names.clientEntries
                                : names.supplierEntries,
                          ),
                        'accountId': financeDictionaryFacets(
                          names.accountEntries,
                        ),
                        'status': financeDocumentStatusFacets,
                      },
                      nullCounts: const {},
                      filters: {
                        if (_cfg.hasParty)
                          _cfg.isClient ? 'clientId' : 'supplierId':
                              _partyIdFilter,
                        'accountId': _accountIdFilter,
                        'status': _statusFilter?.toString(),
                      },
                      onFilterChanged: _onColumnFilterChanged,
                      sortColumn: _list.sortKey,
                      sortAscending: _list.sortAsc,
                      onSortChange: _onSortChange,
                      onRowTap: (it) => context.push(
                        '/finance/${_cfg.type.pathSegment}/${it.id}',
                      ),
                      isLoading: _list.isLoadingFirst,
                      loadingMore: _list.isLoadingMore,
                      error: _list.error,
                      onRetry: () => _reload(),
                      emptyMessage: '暂无${_cfg.shortLabel}单',
                      currentPage: _list.currentPage,
                      totalPages: _list.totalPages,
                      onPageChange: (p) => _reload(p),
                    ),
                  ),
                );
              },
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
