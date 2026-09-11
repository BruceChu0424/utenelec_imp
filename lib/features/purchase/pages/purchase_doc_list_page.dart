// 采购单据列表页（按 docType 参数化）。
//
// 2026-09-03 起统一「分类分段」范式（原 DocKpiBar 状态卡条退役）：
// UtenFilterToolbar 状态分段（草稿/已审/红冲，无「全部」段）+ 末尾「历史记录」段——
// - 默认不选：进页面不预选、不发请求，内容区显示引导占位（UtenFilterPlaceholder）；
// - 计数只挂待处理段（申请页=计划已下达待分解；订货/收货/退货页=草稿），
//   取后端 list(size:1) 全量口径，形态是中性括号 `(N)` 而非红徽章——
//   草稿没人在等，申请的待处理量已由采购任务中心「待分解」徽章承担；
// - 历史记录段：内容区顶部渲染 UtenHistoryTimeFilter（时间段/全部），
//   未选时间不发请求显示引导占位；选中后按 dateFrom/dateTo 加载（不限状态）。
// 其余（折叠头+表格吸顶内滚、列表刷新 tick、返回即刷新、PagedListController
// 竞态状态机）保持原实现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/doc_status_badge.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/draft_counts_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';

/// 状态分段值：真实单据状态（status 非空）或历史记录哨兵。
class _PurchaseDocSeg {
  const _PurchaseDocSeg.stage(int this.status) : history = false;
  const _PurchaseDocSeg.history() : status = null, history = true;

  final int? status;
  final bool history;
  @override
  bool operator ==(Object other) =>
      other is _PurchaseDocSeg &&
      other.status == status &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

class PurchaseDocListPage extends ConsumerStatefulWidget {
  const PurchaseDocListPage({
    super.key,
    required this.docType,
    this.initialStatus,
  });
  final PurchaseDocType docType;

  /// 深链预选（路由 `?status=draft`）：新建页「草稿(N)」按钮进来时直接落在草稿段。
  final String? initialStatus;

  @override
  ConsumerState<PurchaseDocListPage> createState() =>
      _PurchaseDocListPageState();
}

class _PurchaseDocListPageState extends ConsumerState<PurchaseDocListPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  final _list = PagedListController<PurchaseDocListItem>();

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;

  /// 当前选中分段；null = 未选择引导态（不发请求）。
  _PurchaseDocSeg? _seg;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  /// 待处理段计数（中性括号 `(N)`）；null = 加载中（不渲染，不把未知伪装成 0）。
  int? _actionableCount;

  /// 待处理段对应的状态：申请页=计划已下达（待分解）；其余=草稿（待提交/待审）。
  int get _actionableStatus => widget.docType == PurchaseDocType.request
      ? kPurchaseStatusApproved
      : kPurchaseStatusDraft;

  bool get _shouldLoad {
    final seg = _seg;
    if (seg == null) return false;
    if (seg.history && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    // 深链 ?status=draft：直接落在「草稿」段（新建页「草稿(N)」按钮的落点）。
    if (isDraftStatusQuery(widget.initialStatus)) {
      _seg = const _PurchaseDocSeg.stage(kPurchaseStatusDraft);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _loadBadge();
      if (isDraftStatusQuery(widget.initialStatus)) _reload(1);
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
  Future<PagedResult<PurchaseDocListItem>> _fetch() {
    final seg = _seg!;
    final range = seg.history ? _historyTime.range : null;
    return ref
        .read(purchaseRepositoryProvider(widget.docType))
        .list(
          page: _list.pageNum,
          filter: PurchaseDocFilter(
            keyword: _list.normalizedKeyword,
            status: seg.history ? null : seg.status,
            dateFrom: range == null
                ? null
                : ChinaDateTime.formatDate(range.start),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
          ),
          sort: _list.sortKey,
          order: _list.sortOrder,
        );
  }

  Future<void> _reload([int? page, bool silent = false]) {
    if (!_shouldLoad) return Future.value();
    return _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);
  }

  void _selectSeg(_PurchaseDocSeg seg) {
    if (seg == _seg) return;
    setState(() {
      _seg = seg;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _reload(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _reload(1);
  }

  /// 待处理段计数（list size=1 取 total；失败保持 null 不渲染括号数字）。
  Future<void> _loadBadge() async {
    try {
      final r = await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .list(size: 1, filter: PurchaseDocFilter(status: _actionableStatus));
      if (!mounted) return;
      setState(() => _actionableCount = r.total);
    } catch (_) {
      // 计数失败静默：徽章不显示，不影响列表。
    }
  }

  String _statusLabel(PurchaseDocListItem item) {
    if (widget.docType == PurchaseDocType.request && item.status == 1) {
      return '计划已下达';
    }
    if (widget.docType == PurchaseDocType.order) {
      return switch (item.financeApproval?.status) {
        'PENDING' => '等待财务审核',
        'REJECTED' => '财务退回',
        'APPROVED' => '财务已通过',
        'DRAFT' => '待提交财务',
        _ => purchaseStatusLabel(item.status),
      };
    }
    return purchaseStatusLabel(item.status);
  }

  /// 状态徽章语义（与 [_statusLabel] 同一分支）：订货单财务态 等待财务审核=警告黄 /
  /// 财务退回=危险红 / 财务已通过=成功绿 / 待提交财务=中性；其余按单据 0/1/-1。
  UtenStatusBadgeType _statusBadgeType(PurchaseDocListItem item) {
    if (widget.docType == PurchaseDocType.order) {
      return switch (item.financeApproval?.status) {
        'PENDING' => UtenStatusBadgeType.warning,
        'REJECTED' => UtenStatusBadgeType.danger,
        'APPROVED' => UtenStatusBadgeType.success,
        'DRAFT' => UtenStatusBadgeType.neutral,
        _ => docStatusBadgeType(item.status),
      };
    }
    return docStatusBadgeType(item.status);
  }

  List<MasterColumnDef<PurchaseDocListItem>> _columns(
    MasterNameService names, {
    required bool canViewCommercialAmounts,
  }) {
    return <MasterColumnDef<PurchaseDocListItem>>[
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
          label: '供应商',
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
      if (widget.docType != PurchaseDocType.request && canViewCommercialAmounts)
        MasterColumnDef(
          key: 'total',
          label: '合计',
          width: 140,
          type: 'money',
          sortable: true,
          value: (it) => it.totalLocal?.toStringAsFixed(2),
        ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: widget.docType == PurchaseDocType.order ? 140 : 100,
        value: _statusLabel,
        // 状态徽章；value 仍是纯文本供列宽/排序/筛选。
        cellBuilder: (_, it) => UtenStatusBadge(
          label: _statusLabel(it),
          type: _statusBadgeType(it),
          size: UtenStatusBadgeSize.small,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    // 操作后刷新：详情/编辑页保存/审核等成功会 bump 本 docType 的 tick，
    // 本页（即便被详情页遮在栈下）收到即重拉，返回不再看到老数据。
    ref.listen(listRefreshTickProvider(_cfg.refreshKey), (_, _) {
      _reload();
      _loadBadge();
    });
    // 返回即刷新：从详情/编辑页（或任何页面）回到本列表时重拉当前页，
    // 即便对方未 bump tick（纯查看返回）也保证看到最新数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _reload(null, true));
    final isRequest = widget.docType == PurchaseDocType.request;
    final approvedLabel = isRequest ? '计划已下达' : '已审';
    final seg = _seg;
    return Scaffold(
      appBar: UtenAppBar(
        title: _cfg.label,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.purchase),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: () {
              _reload();
              _loadBadge();
            },
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
                    _cfg.canViewCommercial(
                      ref.watch(currentPermissionsProvider),
                    ) &&
                    !(_list.page?.items.any((item) => item.priceMasked) ??
                        false);
                // 「顶部折叠 + 表格吸顶内滚」：分类工具条随上滑收起腾出空间，
                // 标题行钉在表格上方常驻，表格占满剩余空间内部滚动。
                return UtenCollapsingHeaderScrollView(
                  collapsingHeader: UtenFilterToolbar<_PurchaseDocSeg>(
                    segmentsKey: Key(
                      'purchase-doc-segments-${_cfg.type.pathSegment}',
                    ),
                    // 计数形态：两段都是中性括号 `(N)`（组件默认）——草稿是
                    // 「我自己没写完的东西」，没人在等它；申请页「计划已下达」的
                    // 待处理量已由采购任务中心「待分解」徽章承担
                    //（docs/00-项目准则/14-徽章与计数口径.md §三），本页不重复告警。
                    segments: [
                      UtenFilterSegment(
                        value: const _PurchaseDocSeg.stage(
                          kPurchaseStatusDraft,
                        ),
                        label: '草稿',
                        count: _actionableStatus == kPurchaseStatusDraft
                            ? _actionableCount
                            : null,
                      ),
                      UtenFilterSegment(
                        value: const _PurchaseDocSeg.stage(
                          kPurchaseStatusApproved,
                        ),
                        label: approvedLabel,
                        count: _actionableStatus == kPurchaseStatusApproved
                            ? _actionableCount
                            : null,
                      ),
                      const UtenFilterSegment(
                        value: _PurchaseDocSeg.stage(kPurchaseStatusReversed),
                        label: '红冲',
                      ),
                      const UtenFilterSegment(
                        value: _PurchaseDocSeg.history(),
                        label: '历史记录',
                      ),
                    ],
                    selected: seg == null ? const {} : {seg},
                    onSelectionChanged: _selectSeg,
                    searchHint: '搜索单据号', // TODO(l10n): 补 arb
                    initialSearchValue: _list.keyword,
                    onSearchChanged: (v) {
                      _list.keyword = v;
                      _reload(1);
                    },
                  ),
                  body: Column(
                    children: [
                      // 页面头：Icon + 标题 + 计数 + 新建按钮。
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
                                  RoutePath.purchaseDocNew(
                                    _cfg.type.pathSegment,
                                  ),
                                ),
                                child: const Text('新建'), // TODO(l10n): 补 arb
                              ),
                          ],
                        ),
                      ),
                      if (seg?.history == true) ...[
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s8,
                            left: UtenSpacing.s4,
                            right: UtenSpacing.s4,
                          ),
                          child: UtenHistoryTimeFilter(
                            key: Key(
                              'purchase-doc-history-time-${_cfg.type.pathSegment}',
                            ),
                            value: _historyTime,
                            onChanged: _onHistoryTime,
                          ),
                        ),
                      ],
                      Expanded(
                        child: seg == null
                            ? const UtenFilterPlaceholder()
                            : seg.history && _historyTime.isNone
                            ? const UtenHistoryTimePlaceholder()
                            : MasterDataTableView<PurchaseDocListItem>(
                                // primary:true → 表体参与「分类条折叠 → 表格内滚」联动。
                                primary: true,
                                columns: _columns(
                                  names,
                                  canViewCommercialAmounts:
                                      canViewCommercialAmounts,
                                ),
                                items: _list.page?.items ?? const [],
                                facets: const {},
                                nullCounts: const {},
                                filters: const {},
                                onFilterChanged: (_, _) {},
                                sortColumn: _list.sortKey,
                                sortAscending: _list.sortAsc,
                                onSortChange: (column, ascending) {
                                  _list.onSortChange(column, ascending);
                                  _reload(1);
                                },
                                onRowTap: (it) => context.push(
                                  RoutePath.purchaseDocDetail(
                                    _cfg.type.pathSegment,
                                    it.id,
                                  ),
                                ),
                                isLoading: _list.isLoadingFirst,
                                loadingMore: _list.isLoadingMore,
                                error: _list.error,
                                onRetry: () => _reload(),
                                emptyMessage: seg.history
                                    ? '该时间段内暂无${_cfg.shortLabel}单'
                                    : '暂无${_cfg.shortLabel}单', // TODO(l10n): 补 arb
                                currentPage: _list.currentPage,
                                totalPages: _list.totalPages,
                                onPageChange: (p) => _reload(p),
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
