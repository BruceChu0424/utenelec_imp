// 委外单据列表页（按 docType 参数化）。
//
// 复用采购列表布局：UtenAppBar(标题/返回/刷新) + UtenContentContainer > 标题行
// (Icon+label+(N)+搜索+新建) + 状态筛选(ChoiceChip Wrap) + MasterDataTableView。
// 过滤由本页自带的状态 ChoiceChip + 关键词搜索承担（facets 传空，表头降级为纯标签）。
// 名称解析（委外商=supplier/仓库）通过复用采购的 MasterNameService。
// 编辑按 edit 权限显隐「新建」；计划下达的申请只读查看，订货必须从任务中心选择申请明细后生成。
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
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;

class SubcontractDocListPage extends ConsumerStatefulWidget {
  const SubcontractDocListPage({super.key, required this.docType});
  final SubcontractDocType docType;

  @override
  ConsumerState<SubcontractDocListPage> createState() =>
      _SubcontractDocListPageState();
}

class _SubcontractDocListPageState
    extends ConsumerState<SubcontractDocListPage> {
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(widget.docType);
  final _list = PagedListController<SubcontractDocListItem>();

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;
  int? _statusFilter; // null=全部
  bool? _closedFilter; // 结案筛选（仅委外订货单）：false=未完成 / true=已结案

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(mn.masterNameServiceProvider).ensureLoaded();
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
    return _cfg.allowDirectCreate &&
        permission != null &&
        ref.read(currentPermissionsProvider).contains(permission);
  }

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<SubcontractDocListItem>> _fetch() => ref
      .read(subcontractRepositoryProvider(widget.docType))
      .list(
        page: _list.pageNum,
        filter: SubcontractDocFilter(
          keyword: _list.normalizedKeyword,
          status: _statusFilter,
          closed: _closedFilter,
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

  String _statusLabel(SubcontractDocListItem item) {
    if (widget.docType == SubcontractDocType.application && item.status == 1) {
      return '计划已下达';
    }
    if (widget.docType == SubcontractDocType.order) {
      final approval = item.financeApproval;
      if (approval?.isPending == true) {
        return '等待财务审核组审核';
      }
      if (approval?.isRejected == true) return '财务已退回';
      if (item.status == kSubcontractStatusApproved ||
          approval?.isApproved == true) {
        return '财务已审核 / 委外中';
      }
      return '待提交财务';
    }
    return subcontractStatusLabel(item.status);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  List<MasterColumnDef<SubcontractDocListItem>> _columns(
    mn.MasterNameService names, {
    required bool canViewCommercialAmounts,
  }) {
    return <MasterColumnDef<SubcontractDocListItem>>[
      MasterColumnDef(
        key: 'billNo',
        label: '单据号',
        width: 140,
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
      if (_cfg.hasSupplier)
        MasterColumnDef(
          key: 'supplier',
          label: '委外商',
          width: 200,
          value: (it) => names.supplier(it.supplierId),
        ),
      if (_cfg.hasWarehouse)
        MasterColumnDef(
          key: 'warehouse',
          label: '仓库',
          width: 160,
          value: (it) => names.warehouse(it.warehouseId),
        ),
      if (_cfg.hasAmount && canViewCommercialAmounts)
        MasterColumnDef(
          key: 'total',
          label: '合计',
          width: 140,
          type: 'money',
          sortable: true,
          value: (it) => it.totalLocal?.toStringAsFixed(2),
        ),
      if (_cfg.hasTotalWeight)
        MasterColumnDef(
          key: 'totalWeight',
          label: '总重',
          width: 120,
          type: 'number',
          sortable: true,
          value: (it) => it.totalWeight?.toStringAsFixed(2),
        ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 100,
        value: _statusLabel,
      ),
      // 委外订货单：结案状态（未完成=部分入库，其他未入库的作为未完成委外单存在）
      if (widget.docType == SubcontractDocType.order)
        MasterColumnDef(
          key: 'closed',
          label: '结案',
          width: 100,
          value: (it) => it.closed ? '已结案' : '未完成',
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(mn.masterNameServiceProvider);
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
          onPressed: () => backTo(context, defaultPath: SubcontractRoute.hub),
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
                final canViewCommercialAmounts =
                    ref
                        .watch(currentPermissionsProvider)
                        .contains(Perm.subcontractReceiptPriceView) &&
                    !(_list.page?.items.any((item) => item.priceMasked) ??
                        false);
                // 「顶部折叠 + 表格吸顶内滚」：禁用横幅与标题行随上滑收起，
                // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
                return UtenCollapsingHeaderScrollView(
                  collapsingHeader: Column(
                    children: [
                      if (!_cfg.enabled) _disabledBanner(theme),
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
                            if (_canCreate)
                              UtenButton(
                                type: UtenButtonType.tonal,
                                icon: Icons.add_rounded,
                                onPressed: () => context.push(
                                  SubcontractRoute.newList(_cfg.pathSegment),
                                ),
                                child: const Text('新建'),
                              ),
                          ],
                        ),
                      ),
                    ],
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
                              _statusChip(
                                widget.docType == SubcontractDocType.application
                                    ? '尚未下达'
                                    : '草稿',
                                kSubcontractStatusDraft,
                              ),
                              _statusChip(
                                widget.docType == SubcontractDocType.application
                                    ? '计划已下达'
                                    : '已审',
                                kSubcontractStatusApproved,
                              ),
                              _statusChip('红冲', kSubcontractStatusReversed),
                            ],
                          ),
                          // 委外订货单：结案筛选（未完成=部分入库的委外单）
                          if (widget.docType == SubcontractDocType.order) ...[
                            const SizedBox(height: UtenSpacing.s8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final (label, value) in [
                                  ('全部', null),
                                  ('未完成', false),
                                  ('已结案', true),
                                ])
                                  ChoiceChip(
                                    label: Text(
                                      label,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w400,
                                          ),
                                    ),
                                    selected: _closedFilter == value,
                                    onSelected: (_) {
                                      setState(() => _closedFilter = value);
                                      _reload(1);
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    tablePane: MasterDataTableView<SubcontractDocListItem>(
                      // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
                      primary: true,
                      columns: _columns(
                        names,
                        canViewCommercialAmounts: canViewCommercialAmounts,
                      ),
                      items: _list.page?.items ?? const [],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      sortColumn: _list.sortKey,
                      sortAscending: _list.sortAsc,
                      onSortChange: _onSortChange,
                      onRowTap: (it) => context.push(
                        SubcontractRoute.detail(_cfg.pathSegment, it.id),
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

  Widget _disabledBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(
        bottom: UtenSpacing.s8,
        left: UtenSpacing.s4,
        right: UtenSpacing.s4,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '该单据类型老库无数据(仅建结构)，可新建但不参与链路。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
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
