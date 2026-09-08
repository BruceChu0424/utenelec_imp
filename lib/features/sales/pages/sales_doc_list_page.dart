// 销售单据列表页（按 docType 参数化）。
//
// 2026-09-03 起统一「分类分段」范式（ADR-066）：
// - 订货单：大类行 = 待生产/生产中/待发货/本月完成（原 4 张统计卡转分段卡，
//   计数转徽章，来自后端 stats 全量口径）+ 搜索；小类行 = 草稿/已审/红冲
//   （无「全部」段，默认不选=全部效果）+ 末尾「历史记录」（时间门控：时间段/
//   全部，未选时间不发请求；选定后按 dateFrom/dateTo 不限阶段状态加载）。
//   可发货置顶小开关保留。
// - 出货/退货/报价：单行范式——草稿/已审/红冲 + 末尾历史记录 + 搜索，
//   默认不选不发请求。
// 大类未选（订货单）/状态未选（其他单据）时内容区显示引导占位，不发请求。
// 名称解析（客户/仓库）通过 SalesMasterNameService；编辑按 edit 权限显隐「新建」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/paged_list_controller.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_batch_ship_panel.dart';

/// 小类分段值：真实单据状态（status 非空）或历史记录哨兵。
class _SalesDocSeg {
  const _SalesDocSeg.stage(int this.status) : history = false;
  const _SalesDocSeg.history() : status = null, history = true;

  final int? status;
  final bool history;

  @override
  bool operator ==(Object other) =>
      other is _SalesDocSeg &&
      other.status == status &&
      other.history == history;

  @override
  int get hashCode => Object.hash(status, history);
}

class SalesDocListPage extends ConsumerStatefulWidget {
  const SalesDocListPage({super.key, required this.docType});
  final SalesDocType docType;

  @override
  ConsumerState<SalesDocListPage> createState() => _SalesDocListPageState();
}

class _SalesDocListPageState extends ConsumerState<SalesDocListPage> {
  SalesDocConfig get _cfg => SalesDocConfig.by(widget.docType);
  final _list = PagedListController<SalesDocListItem>();

  /// 大类分段（仅订货单）：pending/production/shippable/monthDone；
  /// null = 未选择引导态（不发请求）。
  String? _stage;

  /// 小类分段：草稿/已审/红冲或历史记录；null = 未选择。
  /// 订货单未选=全部效果（可与大类组合）；其他单据未选=引导占位。
  _SalesDocSeg? _statusSeg;

  /// 历史记录段的时间门控值；none = 尚未选择（历史段下同样不发请求）。
  UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();

  /// 可发货置顶（订货单工作台小项）：true 时后端按"有预留单排前 + 交货日升序"
  /// 排序，忽略列排序。
  bool _shippableFirst = false;

  /// 订货工作台统计卡口径计数（大类段徽章）；null = 尚未返回。
  SalesOrderStats? _stats;

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;

  bool get _isOrder => widget.docType == SalesDocType.order;

  bool get _isHistory => _statusSeg?.history == true;

  bool get _shouldLoad {
    if (_isOrder) {
      if (_stage == null) return false;
    } else {
      if (_statusSeg == null) return false;
    }
    if (_isHistory && _historyTime.isNone) return false;
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).ensureLoaded();
      if (_isOrder) _loadStats();
    });
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  bool _hasPermission(String? code) =>
      code != null && ref.read(currentPermissionsProvider).contains(code);

  bool get _canCreate =>
      widget.docType != SalesDocType.otherShipment &&
      _hasPermission(_cfg.createPerm);

  /// 批量发货会生成出货草稿，只检查明确的新增出货权限。
  bool get _canShip => _isOrder && _hasPermission(Perm.salesShipmentCreate);

  /// 报价转换同时读取来源报价并创建目标订货草稿。
  bool get _canConvertQuote =>
      _isOrder &&
      _hasPermission(Perm.salesQuoteConvert) &&
      _hasPermission(Perm.salesOrderCreate);

  /// 大类段徽章计数（后端 stats 全量口径；失败保持旧值不显示变化）。
  Future<void> _loadStats() async {
    try {
      final stats = await ref
          .read(salesRepositoryProvider(widget.docType))
          .stats();
      if (!mounted) return;
      setState(() => _stats = stats);
    } catch (_) {
      // 统计失败静默：徽章不显示，不影响列表。
    }
  }

  /// 批量发货：右滑面板勾选可发行 + 改本次数量 → 同客户合并出货草稿 → 跳出货列表。
  Future<void> _batchShip() async {
    final n = await showSalesBatchShipPanel(context, ref);
    if (n == null || !mounted) return;
    context.appSuccess('已生成 $n 张出货单草稿');
    context.push(SalesRoutePath.list(SalesDocType.shipment.pathSegment));
  }

  /// 从报价引入（SOP §三1）：弹窗列已审报价 → 选择转入 → 生成订货草稿并打开编辑页。
  Future<void> _importFromQuote() async {
    final names = ref.read(salesMasterNameServiceProvider);
    await names.ensureLoaded();
    if (!mounted) return;
    final quote = await showDialog<SalesDocListItem>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择已审核报价单'),
        content: SizedBox(
          width: 420,
          height: 380,
          child: FutureBuilder<PagedResult<SalesDocListItem>>(
            future: ref
                .read(salesRepositoryProvider(SalesDocType.quote))
                .list(size: 50, filter: const SalesDocFilter(status: 1)),
            builder: (_, snap) {
              if (snap.hasError) {
                return const Center(child: Text('报价加载失败'));
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final quotes = snap.data!.items;
              if (quotes.isEmpty) {
                return const Center(child: Text('暂无已审核报价单'));
              }
              return ListView.separated(
                itemCount: quotes.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final q = quotes[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      q.billNo ?? '—',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${names.client(q.clientId)} · ${q.billDate ?? ''} · ¥${q.totalLocal?.toStringAsFixed(2) ?? '—'}',
                    ),
                    onTap: () => Navigator.pop(ctx, q),
                  );
                },
              );
            },
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (quote == null || !mounted) return;
    final order = await context.guardAction(
      () => ref
          .read(salesRepositoryProvider(SalesDocType.quote))
          .convertToOrder(quote.id),
      errorFallback: '转入失败，请稍后重试',
    );
    if (order == null || !mounted) return;
    context.appSuccess('已生成订货草稿');
    // 生成的订货草稿属另一单据类型：bump 订货列表 key，无论后续编辑是否保存，
    // 订货列表（可能已挂在栈下）返回时都能看到这张新草稿。
    bumpListRefresh(ref, SalesDocConfig.by(SalesDocType.order).refreshKey);
    context.push(
      SalesRoutePath.docEdit(SalesDocType.order.pathSegment, order.id),
    );
  }

  /// 用当前筛选组装本页拉取（fetch 执行时读取控制器快照，pageNum 已更新）。
  Future<PagedResult<SalesDocListItem>> _fetch() {
    final range = _isHistory ? _historyTime.range : null;
    return ref
        .read(salesRepositoryProvider(widget.docType))
        .list(
          page: _list.pageNum,
          filter: SalesDocFilter(
            keyword: _list.normalizedKeyword,
            status: _isHistory ? null : _statusSeg?.status,
            chain: _isOrder && !_isHistory ? _cardChain() : null,
            closed: _isOrder && _stage == 'monthDone' && !_isHistory
                ? true
                : null,
            // 「本月完成」口径 = is_closed 且结案在本月；钻取须带月初起，否则列表
            // 含非本月结案单，段计数与列表数对不上。
            dateFrom: range != null
                ? ChinaDateTime.formatDate(range.start)
                : (_isOrder && _stage == 'monthDone'
                      ? ChinaDateTime.formatDate(
                          ChinaDateTime.today().copyWith(day: 1),
                        )
                      : null),
            dateTo: range == null ? null : ChinaDateTime.formatDate(range.end),
          ),
          sort: _shippableFirst && !_isHistory ? 'shippable' : _list.sortKey,
          order: _shippableFirst && !_isHistory || _list.sortKey == null
              ? null
              : _list.sortOrder,
        );
  }

  Future<void> _reload([int? page, bool silent = false]) {
    if (!_shouldLoad) return Future.value();
    return _list.load(page ?? _list.pageNum, silent: silent, fetch: _fetch);
  }

  /// 大类段 → 链路状态组映射（与后端 stats 口径一致）。
  List<int>? _cardChain() {
    switch (_stage) {
      case 'pending':
        return const [2, 3, 4]; // 待排产/待物料/已排产
      case 'production':
        return const [5, 6]; // 生产中/部分完工
      case 'shippable':
        return const [1, 7, 8]; // 部分预留/可发货/部分发货
      default:
        return null;
    }
  }

  void _selectStage(String stage) {
    if (_stage == stage) return;
    setState(() {
      _stage = stage;
      _statusSeg = null;
      _historyTime = const UtenHistoryTimeValue.none();
    });
    // 订货单大类选中即加载（小类默认不选=全部效果）。
    _reload(1);
  }

  void _selectStatusSeg(_SalesDocSeg seg) {
    if (seg == _statusSeg) return;
    setState(() {
      _statusSeg = seg;
      if (!seg.history) _historyTime = const UtenHistoryTimeValue.none();
    });
    if (!seg.history || !_historyTime.isNone) _reload(1);
  }

  void _onHistoryTime(UtenHistoryTimeValue value) {
    if (value == _historyTime) return;
    setState(() => _historyTime = value);
    _reload(1);
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    _list.onSortChange(column, ascending);
    _reload(1);
  }

  List<MasterColumnDef<SalesDocListItem>> _columns(
    SalesMasterNameService names,
  ) {
    return <MasterColumnDef<SalesDocListItem>>[
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
      MasterColumnDef(
        key: 'client',
        label: '客户',
        width: 200,
        value: (it) => names.client(it.clientId),
      ),
      if (_cfg.hasCurrency)
        MasterColumnDef(
          key: 'currency',
          label: '币种',
          width: 100,
          value: (it) => names.currency(it.currencyId),
        ),
      if (_cfg.hasWarehouse)
        MasterColumnDef(
          key: 'warehouse',
          label: '仓库',
          width: 160,
          value: (it) => names.warehouse(it.warehouseId),
        ),
      if (_cfg.type == SalesDocType.shipment)
        MasterColumnDef(
          key: 'financeAudit',
          label: '财务审核',
          width: 120,
          value: (it) => salesShipmentFinanceAuditLabel(it.financeAudit),
        ),
      if (_cfg.type == SalesDocType.shipment)
        MasterColumnDef(
          key: 'warehouseWorkStatus',
          label: '仓库作业',
          width: 150,
          value: (it) => salesWarehouseWorkStatusLabel(it.warehouseWorkStatus),
        ),
      if (_cfg.hasOutType)
        MasterColumnDef(
          key: 'outType',
          label: '出库类型',
          width: 110,
          value: (it) => it.outType,
        ),
      MasterColumnDef(
        key: 'total',
        label: _isOrder ? '订单金额' : '合计',
        width: 140,
        type: 'money',
        // 不同币种的原币金额不可直接横向比较；订单金额列不做跨币种排序。
        sortable: !_isOrder,
        // 订单列表显示所选币种的原币合计，不把人民币换算暴露给销售端。
        // 其它销售单据仍沿用各自既有的本币列表口径。
        value: (it) => it.priceMasked
            ? '***'
            : (_isOrder ? it.totalOriginal : it.totalLocal)?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 130,
        value: (it) {
          final status = it.rejected ? '已驳回' : salesStatusLabel(it.status);
          // V294：已审待财务确认的订单标注提示（确认后计划部才可见）。
          // ADR-052：财务驳回优先显示；销售须受控修订并重新审核，系统再提交财务。
          final gated =
              _isOrder &&
              it.status == kSalesStatusApproved &&
              !it.financeConfirmed &&
              !it.closed &&
              !it.stopped;
          final financeRejected = gated && it.financeRejected;
          final withGate = financeRejected
              ? '$status · 财务已驳回'
              : gated
              ? '$status · 待财务确认'
              : status;
          return it.writable ? withGate : '$withGate · 只读';
        },
      ),
      if (_isOrder)
        MasterColumnDef(
          key: 'deliver',
          label: '交货',
          width: 130,
          value: (it) => it.deliverDate == null
              ? null
              : '${it.delayWarning ? '⚠ ' : ''}${it.deliverDate!.substring(0, 10)}',
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    // 操作后刷新：详情/编辑页保存/审核等成功会 bump 本 docType 的 tick，
    // 本页（即便被详情页遮在栈下）收到即重拉，返回不再看到老数据。
    ref.listen(listRefreshTickProvider(_cfg.refreshKey), (_, _) {
      _reload();
      if (_isOrder) _loadStats();
    });
    // 返回即刷新：从详情/编辑页（或任何页面）回到本列表时重拉当前页，
    // 即便对方未 bump tick（纯查看返回）也保证看到最新数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () {
      _reload(null, true);
      if (_isOrder) _loadStats();
    });
    final seg = _statusSeg;
    // 小类行（仅订货单渲染；搜索在大类行）。其他单据在下方自建带搜索的同行。
    final statusRow = UtenFilterToolbar<_SalesDocSeg>(
      segmentsKey: Key('sales-doc-status-${_cfg.type.pathSegment}'),
      segments: [
        for (final status in [
          kSalesStatusDraft,
          kSalesStatusApproved,
          kSalesStatusReversed,
        ])
          UtenFilterSegment(
            value: _SalesDocSeg.stage(status),
            label: salesStatusLabel(status),
          ),
        const UtenFilterSegment(value: _SalesDocSeg.history(), label: '历史记录'),
      ],
      selected: seg == null ? const {} : {seg},
      onSelectionChanged: _selectStatusSeg,
    );
    return Scaffold(
      appBar: UtenAppBar(
        title: _cfg.label,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: SalesRoutePath.hub),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () {
              _reload();
              if (_isOrder) _loadStats();
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
                // 「顶部折叠 + 表格吸顶内滚」：分类工具条随上滑收起腾出空间，
                // 标题行钉在表格上方常驻，表格占满剩余空间内部滚动。
                return UtenCollapsingHeaderScrollView(
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_isOrder) ...[
                          // 大类行（仅订货单）：待生产/生产中/待发货/本月完成 + 搜索。
                          // 原统计卡钻取口径不变（chain/closed/本月月初）。
                          UtenFilterToolbar<String>(
                            segmentsKey: const Key('sales-doc-order-stages'),
                            segments: [
                              UtenFilterSegment(
                                value: 'pending',
                                label: '待生产',
                                count: _stats?.pendingProduction,
                              ),
                              UtenFilterSegment(
                                value: 'production',
                                label: '生产中',
                                count: _stats?.inProduction,
                              ),
                              UtenFilterSegment(
                                value: 'shippable',
                                label: '待发货',
                                count: _stats?.shippable,
                              ),
                              UtenFilterSegment(
                                value: 'monthDone',
                                label: '本月完成',
                                count: _stats?.monthDone,
                              ),
                            ],
                            selected: _stage == null ? const {} : {_stage!},
                            onSelectionChanged: _selectStage,
                            searchHint: '搜索单据号 / 客户',
                            initialSearchValue: _list.keyword,
                            onSearchChanged: (v) {
                              _list.keyword = v;
                              _reload(1);
                            },
                          ),
                          // 小类行：选中大类后出现（无「全部」段）。
                          if (_stage != null) ...[
                            const SizedBox(height: UtenSpacing.s8),
                            statusRow,
                          ],
                        ] else
                          // 其他单据：单行范式（状态 + 末尾历史记录 + 搜索）。
                          UtenFilterToolbar<_SalesDocSeg>(
                            segmentsKey: Key(
                              'sales-doc-status-${_cfg.type.pathSegment}',
                            ),
                            segments: [
                              for (final status in [
                                kSalesStatusDraft,
                                kSalesStatusApproved,
                                kSalesStatusReversed,
                              ])
                                UtenFilterSegment(
                                  value: _SalesDocSeg.stage(status),
                                  label: salesStatusLabel(status),
                                ),
                              const UtenFilterSegment(
                                value: _SalesDocSeg.history(),
                                label: '历史记录',
                              ),
                            ],
                            selected: seg == null ? const {} : {seg},
                            onSelectionChanged: _selectStatusSeg,
                            searchHint: '搜索单据号 / 客户',
                            initialSearchValue: _list.keyword,
                            onSearchChanged: (v) {
                              _list.keyword = v;
                              _reload(1);
                            },
                          ),
                        // 历史记录段时间行。
                        if (_isHistory) ...[
                          const SizedBox(height: UtenSpacing.s8),
                          UtenHistoryTimeFilter(
                            key: Key(
                              'sales-doc-history-time-${_cfg.type.pathSegment}',
                            ),
                            value: _historyTime,
                            onChanged: _onHistoryTime,
                          ),
                        ],
                        // 可发货置顶（订货单工作台小项）：有预留单排前 + 交货日升序。
                        if (_isOrder &&
                            !_isHistory &&
                            _stage != null &&
                            seg != null &&
                            !seg.history) ...[
                          const SizedBox(height: UtenSpacing.s8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: ChoiceChip(
                              label: const Text('可发货置顶'),
                              avatar: Icon(
                                Icons.vertical_align_top_rounded,
                                size: 16,
                                color: _shippableFirst
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                              selected: _shippableFirst,
                              onSelected: (v) {
                                setState(() => _shippableFirst = v);
                                _reload(1);
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  body: Column(
                    children: [
                      // 页面头：Icon + 标题 + 计数 + 动作按钮。
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
                            // 批量发货（SOP §一9，仅订货单）：面板勾选可发行 → 同客户合并出货草稿
                            if (_canShip) ...[
                              UtenButton(
                                type: UtenButtonType.secondary,
                                icon: Icons.local_shipping_outlined,
                                onPressed: _batchShip,
                                child: const Text('批量发货'),
                              ),
                              const SizedBox(width: UtenSpacing.s8),
                            ],
                            // 报价引入（SOP §三1，仅订货单）：弹窗选已审报价 → 一键转订货草稿
                            if (_canConvertQuote) ...[
                              UtenButton(
                                type: UtenButtonType.secondary,
                                icon: Icons.transform_outlined,
                                onPressed: _importFromQuote,
                                child: const Text('从报价引入'),
                              ),
                              const SizedBox(width: UtenSpacing.s8),
                            ],
                            if (_canCreate)
                              UtenButton(
                                type: UtenButtonType.tonal,
                                icon: Icons.add_rounded,
                                onPressed: () => context.push(
                                  SalesRoutePath.docNew(_cfg.type.pathSegment),
                                ),
                                child: const Text('新建'),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: !_shouldLoad
                            ? (_isHistory
                                  ? const UtenHistoryTimePlaceholder()
                                  : UtenFilterPlaceholder(
                                      message: _isOrder
                                          ? '在上方选择分类后开始浏览'
                                          : '在上方选择状态或历史记录后开始浏览',
                                      description: _isOrder
                                          ? '大类默认不选中，选择后加载对应阶段订单'
                                          : '状态默认不选中，选择后加载对应单据',
                                    ))
                            : MasterDataTableView<SalesDocListItem>(
                                // primary:true → 表体参与「分类条折叠 → 表格内滚」联动。
                                primary: true,
                                columns: _columns(names),
                                items: _list.page?.items ?? const [],
                                facets: _statusFacets(),
                                nullCounts: const {},
                                filters: _statusFilterMap,
                                onFilterChanged: (key, value) {
                                  // 表头筛选桶与分类行联动：清桶（null）不改分段
                                  //（分段单选无法回退，清桶视为保持当前选择）。
                                  if (key != 'status' || value == null) return;
                                  final status = int.tryParse(value);
                                  if (status != null) {
                                    _selectStatusSeg(
                                      _SalesDocSeg.stage(status),
                                    );
                                  }
                                },
                                sortColumn: _list.sortKey,
                                sortAscending: _list.sortAsc,
                                onSortChange: _onSortChange,
                                onRowTap: (it) => context.push(
                                  SalesRoutePath.docDetail(
                                    _cfg.type.pathSegment,
                                    it.id,
                                  ),
                                ),
                                isLoading: _list.isLoadingFirst,
                                loadingMore: _list.isLoadingMore,
                                error: _list.error,
                                onRetry: () => _reload(),
                                emptyMessage: _isHistory
                                    ? '该时间段内暂无${_cfg.shortLabel}单'
                                    : '暂无${_cfg.shortLabel}单',
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

  /// 当前表头「状态」列筛选值（历史段/未选时不过滤）。
  Map<String, String?> get _statusFilterMap {
    final seg = _statusSeg;
    if (seg == null || seg.history) return const <String, String?>{};
    return <String, String?>{'status': '${seg.status}'};
  }

  /// 表头「状态」列筛选桶（状态是固定枚举，前端硬编码；count=0 表示不强调计数）。
  Map<String, List<MasterFacetBucket>> _statusFacets() => const {
    'status': [
      MasterFacetBucket(value: '0', count: 0, label: '草稿'),
      MasterFacetBucket(value: '1', count: 0, label: '已审'),
      MasterFacetBucket(value: '-1', count: 0, label: '红冲'),
    ],
  };
}
