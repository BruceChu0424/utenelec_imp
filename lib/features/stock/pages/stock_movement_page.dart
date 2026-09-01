// 出入库流水查询页（库存管理，stock:view）：仓库筛选 + 货品过滤 + 流水列表（类型/方向/货品/仓库名解析）。
//
// 统一主档表格（MasterDataTableView）+ 桌面左筛选/右表格两栏（UtenListTwoPane），
// 与基础资料/单据列表同款；手机垂直堆叠。
// 收支方向以 +/- 前缀体现（与仓库报表同款；表格单元格不支持逐行着色）。
//
// 货品过滤：可由即时库存行点击带入（/stock/movement?goodsId=xxx），左栏显示货品 chip 可清除
// （清除=看全部货品）；仓库下拉与货品过滤可叠加。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_query.dart';
import '../repositories/stock_query_repository.dart';

class StockMovementPage extends ConsumerStatefulWidget {
  const StockMovementPage({super.key, this.goodsId, this.warehouseId});

  /// 预置货品过滤（即时库存/余额/货品详情带入）；null=全部货品。
  final String? goodsId;

  /// 预置仓库过滤（库存余额行点击带入，与货品叠加）；null=全部仓库。
  final String? warehouseId;

  @override
  ConsumerState<StockMovementPage> createState() => _StockMovementPageState();
}

class _StockMovementPageState extends ConsumerState<StockMovementPage> {
  PagedResult<MovementRow>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  String? _warehouseId;
  String? _goodsId;
  // 列排序态：_sortKey=当前排序列 key（null=不排序，走后端默认 transactionDate DESC）；_sortAsc=升序。
  String? _sortKey;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _goodsId = widget.goodsId;
    _warehouseId = widget.warehouseId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded().then((_) async {
        // 预置货品时先解析名称（chip 显示用），再拉列表
        if (_goodsId != null) {
          await ref.read(masterNameServiceProvider).loadGoodsNames({_goodsId!});
        }
        if (mounted) _load(1);
      });
    });
  }

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(stockQueryRepositoryProvider)
          .movements(
            page: page,
            warehouseId: _warehouseId,
            goodsId: _goodsId,
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      final goodsIds = r.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _page = r);
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() => _error = '加载失败'); // TODO(l10n): 补 arb
    } finally {
      if (mounted && _loadRequests.isCurrent(generation)) {
        setState(() => _loading = false);
      }
    }
  }

  List<MasterColumnDef<MovementRow>> get _columns {
    final names = ref.read(masterNameServiceProvider);
    return <MasterColumnDef<MovementRow>>[
      MasterColumnDef(
        key: 'date',
        label: '日期', // TODO(l10n): 补 arb
        width: 120,
        type: 'date',
        sortable: true,
        value: (m) => m.transactionDate == null
            ? null
            : (m.transactionDate!.length >= 10
                  ? m.transactionDate!.substring(0, 10)
                  : m.transactionDate),
      ),
      MasterColumnDef(
        key: 'type',
        label: '类型', // TODO(l10n): 补 arb
        width: 120,
        value: (m) => movementTypeLabel(m.movementType),
      ),
      MasterColumnDef(
        key: 'goods',
        label: '货品', // TODO(l10n): 补 arb
        width: 220,
        value: (m) => names.goods(m.goodsId),
      ),
      MasterColumnDef(
        key: 'warehouse',
        label: '仓库', // TODO(l10n): 补 arb
        width: 160,
        value: (m) => names.warehouse(m.warehouseId),
      ),
      MasterColumnDef(
        key: 'unit',
        label: '单位',
        width: 90,
        value: (m) => names.unit(m.unitId),
      ),
      MasterColumnDef(
        key: 'qty',
        label: '数量', // TODO(l10n): 补 arb
        width: 120,
        type: 'number',
        sortable: true,
        value: (m) {
          if (m.qty == null) return null;
          final sign = m.direction == 1 ? '+' : '-';
          return '$sign${m.qty!.toStringAsFixed(2)}';
        },
      ),
      MasterColumnDef(
        key: 'weight',
        label: '实际重量',
        width: 120,
        type: 'number',
        sortable: true,
        value: (m) {
          if (m.weight == null) return null;
          final sign = m.direction == 1 ? '+' : '-';
          return '$sign${m.weight!.toStringAsFixed(4)}';
        },
      ),
    ];
  }

  /// 表头排序回调：column=null 取消排序回后端默认；否则按该列升/降序重查（回第 1 页）。
  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _load(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '出入库流水', // TODO(l10n): 补 arb
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.purchase),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            // 「顶部折叠 + 表格吸顶内滚」：标题行随上滑收起腾出空间，
            // 筛选/表格区占满剩余空间、表体内部滚动（与单据列表页统一）。
            child: UtenCollapsingHeaderScrollView(
              // 页面头：Icon + 标题 + 计数
              collapsingHeader: Padding(
                padding: const EdgeInsets.only(
                  bottom: UtenSpacing.s8,
                  left: UtenSpacing.s4,
                  right: UtenSpacing.s4,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.swap_vert_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '流水 ($total)',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              // 桌面：左筛选侧栏（仓库）+ 右表格；手机：垂直堆叠
              body: UtenListTwoPane(
                filterPane: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 货品过滤（即时库存带入）：chip 可清除，清除=全部货品
                      if (_goodsId != null) ...[
                        Text(
                          '货品',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        InputChip(
                          label: Text(
                            names.goods(_goodsId),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onDeleted: () {
                            setState(() => _goodsId = null);
                            _load(1);
                          },
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      SizedBox(
                        width: double.infinity,
                        child: DropdownButtonFormField<String?>(
                          initialValue: _warehouseId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: '仓库',
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              child: Text('全部仓库'),
                            ),
                            for (final e in names.warehouseEntries.entries)
                              DropdownMenuItem<String?>(
                                value: e.key,
                                child: Text(e.value),
                              ),
                          ],
                          onChanged: (v) {
                            setState(() => _warehouseId = v);
                            _load(1);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                tablePane: MasterDataTableView<MovementRow>(
                  // primary:true → 表体参与「标题行折叠 → 表格内滚」联动。
                  primary: true,
                  columns: _columns,
                  items: _page?.items ?? const [],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  sortColumn: _sortKey,
                  sortAscending: _sortAsc,
                  onSortChange: _onSortChange,
                  onRowTap: (movement) => _openSourceDoc(context, movement),
                  isLoading: _loading && _page == null,
                  loadingMore: _loading && _page != null,
                  error: _error,
                  onRetry: () => _load(_pageNum),
                  emptyMessage: '暂无流水', // TODO(l10n): 补 arb
                  currentPage: _page?.page ?? 1,
                  totalPages: _page?.totalPages ?? 1,
                  onPageChange: (p) => _load(p),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 流水行 → 来源单据详情（全类型跳转；无来源/未知类型不动作）。
///
/// 映射口径：sourceDocType（服务端 SRC_* 常量）优先；STOCK_DOC 统一来源按
/// movement_type（字典：1..20）推导仓库单据 code。
void _openSourceDoc(BuildContext context, MovementRow movement) {
  final sourceId = movement.sourceDocId;
  if (sourceId == null || sourceId.isEmpty) return;
  final t = movement.movementType;
  switch (movement.sourceDocType) {
    case 'PURCHASE_RECEIPT':
      context.push(RoutePath.purchaseDocDetail('receipts', sourceId));
    case 'PURCHASE_RETURN':
      context.push(RoutePath.purchaseDocDetail('returns', sourceId));
    case 'SALES_SHIPMENT':
      context.push(RoutePath.salesDocDetail('shipments', sourceId));
    case 'SALES_RETURN':
      context.push(RoutePath.salesDocDetail('returns', sourceId));
    case 'SALES_OTHER_SHIPMENT':
      context.push(RoutePath.salesDocDetail('other-shipments', sourceId));
    case 'SUBCONTRACT_RECEIPT':
      context.push(RoutePath.subcontractDocDetail('receipts', sourceId));
    case 'SUBCONTRACT_RETURN':
      context.push(RoutePath.subcontractDocDetail('returns', sourceId));
    case 'SUBCONTRACT_MATERIAL_ISSUE':
      context.push(RoutePath.subcontractDocDetail('material-issues', sourceId));
    case 'SUBCONTRACT_MATERIAL_RETURN':
      context.push(
        RoutePath.subcontractDocDetail('material-returns', sourceId),
      );
    case 'SUBCONTRACT_WASTE':
      context.push(RoutePath.subcontractDocDetail('wastes', sourceId));
    case 'STOCK_DOC':
      final code = switch (t) {
        5 => 'DRAW',
        6 => 'WDRAW',
        7 || 8 => 'TRANSFER',
        9 || 10 => 'CHECK',
        11 => 'OTHER_IN',
        12 => 'OTHER_OUT',
        13 => 'FINISHED_IN',
        14 => 'FINISHED_OUT',
        _ => null,
      };
      if (code != null) context.push(RoutePath.stockDocDetail(code, sourceId));
    default:
      // 未知来源类型：不动作（不猜路由）。
      break;
  }
}
