// 销售单据列表页（按 docType 参数化）。
//
// 复用基础资料布局：UtenAppBar(标题/返回/刷新) + UtenContentContainer > 标题行
// (Icon+label+(N)+搜索+新建) + 状态筛选(ChoiceChip Wrap) + MasterDataTableView。
// 过滤由本页自带的状态 ChoiceChip + 关键词搜索承担（facets 传空，表头降级为纯标签）。
// 名称解析（客户/仓库）通过 SalesMasterNameService。编辑按 edit 权限显隐「新建」。
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
import '../../../core/router/page_resume_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
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

class SalesDocListPage extends ConsumerStatefulWidget {
  const SalesDocListPage({super.key, required this.docType});
  final SalesDocType docType;

  @override
  ConsumerState<SalesDocListPage> createState() => _SalesDocListPageState();
}

class _SalesDocListPageState extends ConsumerState<SalesDocListPage> {
  SalesDocConfig get _cfg => SalesDocConfig.by(widget.docType);
  PagedResult<SalesDocListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String _keyword = '';
  int? _statusFilter; // null=全部
  // 订货工作台（V90 业务链）：统计卡 + 激活卡钻取（null=不钻取）
  SalesOrderStats? _stats;
  String? _activeCard; // pending/production/shippable/monthDone
  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认 billDate DESC）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;
  // 可发货置顶（工作台小项）：true 时后端按"有预留单排前 + 交货日升序"排序，忽略列排序
  bool _shippableFirst = false;

  /// 本页路径（创建时捕获；被 push 页遮住后现取 matchedLocation 会拿到别人的路径）。
  /// 「返回即刷新」onPageResume 用，见 build。
  String? _myLocation;

  bool get _isOrder => widget.docType == SalesDocType.order;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  /// 批量发货权限（SOP §一9）：开出货单需 sales_shipment:edit。
  bool get _canShip =>
      _isOrder &&
      ref.read(currentPermissionsProvider).contains(Perm.salesShipmentEdit);

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

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final repo = ref.read(salesRepositoryProvider(widget.docType));
      final r = await repo.list(
        page: page,
        filter: SalesDocFilter(
          keyword: _keyword.trim().isEmpty ? null : _keyword,
          status: _statusFilter,
          chain: _cardChain(),
          closed: _activeCard == 'monthDone' ? true : null,
        ),
        sort: _shippableFirst ? 'shippable' : _sortKey,
        order: _shippableFirst || _sortKey == null
            ? null
            : (_sortAsc ? 'asc' : 'desc'),
      );
      SalesOrderStats? stats;
      if (_isOrder) {
        try {
          stats = await repo.stats(); // 统计卡失败不阻塞列表
        } catch (_) {}
      }
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = r;
        _stats = stats ?? _stats;
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
        _error = '加载列表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  /// 统计卡 → 链路状态组映射（与后端 stats 口径一致）。
  List<int>? _cardChain() {
    switch (_activeCard) {
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

  void _onCard(String card) {
    setState(() => _activeCard = _activeCard == card ? null : card);
    _load(1);
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
      if (_cfg.hasWarehouse)
        MasterColumnDef(
          key: 'warehouse',
          label: '仓库',
          width: 160,
          value: (it) => names.warehouse(it.warehouseId),
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
        label: '合计',
        width: 140,
        type: 'money',
        sortable: true,
        // 价格脱敏（SOP §三8）：无 sales_order:price:view 时后端置 null + priceMasked，渲染 ***
        value: (it) =>
            it.priceMasked ? '***' : it.totalLocal?.toStringAsFixed(2),
      ),
      MasterColumnDef(
        key: 'status',
        label: '状态',
        width: 130,
        value: (it) {
          final status = it.rejected ? '已驳回' : salesStatusLabel(it.status);
          return it.writable ? status : '$status · 只读';
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

  /// 订货工作台统计卡（SOP §四）：待生产/生产中/待发货/本月完成；点卡钻取，再点取消。
  Widget _statCards(ThemeData theme) {
    final s = _stats;
    Widget card(String key, String label, int count, Color color) {
      final active = _activeCard == key;
      return Expanded(
        child: Material(
          color: active
              ? color.withValues(alpha: 0.14)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _onCard(key),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$count',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(
        bottom: UtenSpacing.s8,
        left: UtenSpacing.s4,
        right: UtenSpacing.s4,
      ),
      child: Row(
        children: [
          card('pending', '待生产', s?.pendingProduction ?? 0, Colors.orange),
          const SizedBox(width: UtenSpacing.s8),
          card(
            'production',
            '生产中',
            s?.inProduction ?? 0,
            theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          card('shippable', '待发货', s?.shippable ?? 0, Colors.green),
          const SizedBox(width: UtenSpacing.s8),
          card(
            'monthDone',
            '本月完成',
            s?.monthDone ?? 0,
            theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    final total = _page?.total ?? 0;
    // 操作后刷新：详情/编辑页保存/审核等成功会 bump 本 docType 的 tick，
    // 本页（即便被详情页遮在栈下）收到即重拉，返回不再看到老数据。
    ref.listen(listRefreshTickProvider(_cfg.refreshKey), (_, _) {
      _load(_pageNum);
    });
    // 返回即刷新：从详情/编辑页（或任何页面）回到本列表时重拉当前页，
    // 即便对方未 bump tick（纯查看返回）也保证看到最新数据。
    _myLocation ??= GoRouterState.of(context).matchedLocation;
    ref.onPageResume(_myLocation!, () => _load(_pageNum));
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
                      if (_isOrder && _canEdit) ...[
                        UtenButton(
                          type: UtenButtonType.secondary,
                          icon: Icons.transform_outlined,
                          onPressed: _importFromQuote,
                          child: const Text('从报价引入'),
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                      ],
                      if (_canEdit)
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
                // 订货工作台统计卡（仅订货单；待生产/生产中/待发货/本月完成，点卡钻取）
                if (_isOrder) _statCards(theme),
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
                              hint: '搜索单据号 / 客户',
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
                              _statusChip('草稿', kSalesStatusDraft),
                              _statusChip('已审', kSalesStatusApproved),
                              _statusChip('红冲', kSalesStatusReversed),
                            ],
                          ),
                          // 可发货置顶（工作台小项，仅订货单）：有预留单排前 + 交货日升序
                          if (_isOrder) ...[
                            const SizedBox(height: UtenSpacing.s8),
                            ChoiceChip(
                              label: const Text('可发货置顶'),
                              avatar: Icon(
                                Icons.vertical_align_top_rounded,
                                size: 16,
                                color: _shippableFirst
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              selected: _shippableFirst,
                              onSelected: (v) {
                                setState(() => _shippableFirst = v);
                                _load(1);
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                    tablePane: MasterDataTableView<SalesDocListItem>(
                      columns: _columns(names),
                      items: _page?.items ?? const [],
                      facets: _statusFacets(),
                      nullCounts: const {},
                      filters: _statusFilter == null
                          ? const <String, String?>{}
                          : <String, String?>{'status': '$_statusFilter'},
                      onFilterChanged: (key, value) {
                        if (key != 'status') return;
                        setState(
                          () => _statusFilter = value == null
                              ? null
                              : int.tryParse(value),
                        );
                        _load(1);
                      },
                      sortColumn: _sortKey,
                      sortAscending: _sortAsc,
                      onSortChange: _onSortChange,
                      onRowTap: (it) => context.push(
                        SalesRoutePath.docDetail(_cfg.type.pathSegment, it.id),
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

  /// 表头「状态」列筛选桶（状态是固定枚举，前端硬编码；count=0 表示不强调计数）。
  Map<String, List<MasterFacetBucket>> _statusFacets() => const {
    'status': [
      MasterFacetBucket(value: '0', count: 0, label: '草稿'),
      MasterFacetBucket(value: '1', count: 0, label: '已审'),
      MasterFacetBucket(value: '-1', count: 0, label: '红冲'),
    ],
  };

  Widget _statusChip(String label, int? value) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _onStatus(value),
    );
  }
}
